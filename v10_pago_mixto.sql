-- PuntoX Smart POS · v10: pago mixto (efectivo + tarjeta + transferencia en una misma venta).
-- Ejecútalo SOLO si ya ejecutaste schema.sql y v2 a v9. Es seguro ejecutarlo más de una vez.
-- Cada venta guarda cuánto se pagó por cada medio (p_ef, p_tj, p_tr); el cierre de caja y los totales usan esos montos.

alter table ventas add column if not exists pagos jsonb;                       -- [{"m":"Efectivo","a":5000},...] solo en pagos mixtos
alter table ventas add column if not exists p_ef numeric not null default 0;   -- parte pagada en efectivo
alter table ventas add column if not exists p_tj numeric not null default 0;   -- parte pagada con tarjeta
alter table ventas add column if not exists p_tr numeric not null default 0;   -- parte pagada por transferencia

-- Ventas anteriores: todo el total corresponde a su único medio de pago
update ventas set
  p_ef = case when metodo = 'Efectivo' then total else 0 end,
  p_tj = case when metodo = 'Tarjeta' then total else 0 end,
  p_tr = case when metodo = 'Transferencia' then total else 0 end
 where p_ef = 0 and p_tj = 0 and p_tr = 0 and total > 0 and metodo <> 'Mixto';

-- Registro de venta (v9 + pagos mixtos). El servidor valida que los pagos sumen exactamente el total.
create or replace function p_venta_reg(p_u text, p_c text, p_s bigint, p_x jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios; cid bigint; num int; vid bigint; it jsonb;
        forz boolean := coalesce((p_x->>'forzar')::boolean, false);
        own text; its jsonb; pg jsonb; v_tot numeric; s_ef numeric; s_tj numeric; s_tr numeric; s_all numeric; mtd text;
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  if r.rol not in ('Master','Administrador','Cajero') then raise exception 'No autorizado'; end if;
  v_tot := (p_x->>'tot')::numeric;
  pg := case when jsonb_typeof(p_x->'pg') = 'array' and jsonb_array_length(p_x->'pg') > 1 then p_x->'pg' else null end;
  if pg is not null then
    if exists (select 1 from jsonb_array_elements(pg) e where e->>'m' not in ('Efectivo','Tarjeta','Transferencia') or (e->>'a')::numeric <= 0) then
      raise exception 'Medio de pago o monto inválido';
    end if;
    select coalesce(sum((e->>'a')::numeric) filter (where e->>'m' = 'Efectivo'), 0),
           coalesce(sum((e->>'a')::numeric) filter (where e->>'m' = 'Tarjeta'), 0),
           coalesce(sum((e->>'a')::numeric) filter (where e->>'m' = 'Transferencia'), 0),
           coalesce(sum((e->>'a')::numeric), 0)
      into s_ef, s_tj, s_tr, s_all from jsonb_array_elements(pg) e;
    if s_all <> v_tot then raise exception 'Los pagos no suman el total de la venta'; end if;
    mtd := 'Mixto';
  else
    mtd := p_x->>'m';
    s_ef := case when mtd = 'Efectivo' then v_tot else 0 end;
    s_tj := case when mtd = 'Tarjeta' then v_tot else 0 end;
    s_tr := case when mtd = 'Transferencia' then v_tot else 0 end;
  end if;
  own := coalesce(nullif(p_x->>'u', ''), r.usuario);
  cid := nullif(p_x->>'cj', '')::bigint;
  if cid is not null and not exists (select 1 from cajas where id = cid and sucursal_id = p_s) then cid := null; end if;
  if cid is null then
    select id into cid from cajas where sucursal_id = p_s and cierre is null and lower(usuario) = lower(own);
  end if;
  if cid is null and not forz then raise exception 'No hay caja abierta'; end if;
  for it in select * from jsonb_array_elements(p_x->'items') loop
    if forz then
      update productos set stock = greatest(stock - (it->>'q')::numeric, 0)
       where sucursal_id = p_s and codigo = it->>'c';
    else
      update productos set stock = stock - (it->>'q')::numeric
       where sucursal_id = p_s and codigo = it->>'c' and stock >= (it->>'q')::numeric;
      if not found then raise exception 'Sin stock suficiente'; end if;
    end if;
  end loop;
  select coalesce(jsonb_agg(e || jsonb_build_object('cs',
           coalesce((select pr.costo from productos pr where pr.sucursal_id = p_s and pr.codigo = e->>'c'), 0))), '[]'::jsonb)
    into its from jsonb_array_elements(p_x->'items') e;
  insert into contadores (sucursal_id, ultimo) values (p_s, 1)
    on conflict (sucursal_id) do update set ultimo = contadores.ultimo + 1
    returning ultimo into num;
  insert into ventas (sucursal_id, numero, caja_id, usuario, fecha, total, metodo, cliente, recibido, items, pagos, p_ef, p_tj, p_tr)
  values (p_s, num, cid, own,
          coalesce(to_timestamp(nullif(p_x->>'t', '')::numeric / 1000.0), now()),
          v_tot, mtd, nullif(p_x->>'cli', ''),
          coalesce(nullif(p_x->>'rec', '')::numeric, case when s_ef > 0 then s_ef else v_tot end), its, pg, s_ef, s_tj, s_tr)
  returning id into vid;
  return json_build_object('id', vid, 'numero', num);
end $$;

-- Cierre de caja: efectivo, tarjeta y transferencia según lo realmente pagado por cada medio, menos devoluciones
create or replace function p_caja_cerrar(p_u text, p_c text, p_s bigint, p_id bigint, p_x jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios; k cajas; v_ef numeric; v_tj numeric; v_tr numeric; v_tot numeric; v_n int;
        d_ef numeric; d_tj numeric; d_tr numeric; d_tot numeric; v_g numeric; v_ct numeric; v_esp numeric;
        forz boolean := coalesce((p_x->>'forzar')::boolean, false);
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  if r.rol not in ('Master','Administrador','Cajero') then raise exception 'No autorizado'; end if;
  select * into k from cajas where id = p_id and sucursal_id = p_s and cierre is null;
  if not found then raise exception 'La caja ya está cerrada o no existe'; end if;
  if lower(k.usuario) <> lower(r.usuario) and r.rol not in ('Master','Administrador') and not forz then
    raise exception 'Solo el cajero dueño de esta caja puede cerrarla';
  end if;
  select coalesce(sum(p_ef), 0), coalesce(sum(p_tj), 0), coalesce(sum(p_tr), 0), coalesce(sum(total), 0), count(*)
    into v_ef, v_tj, v_tr, v_tot, v_n from ventas where caja_id = p_id;
  select coalesce(sum(total) filter (where reembolso = 'Efectivo'), 0), coalesce(sum(total) filter (where reembolso = 'Tarjeta'), 0),
         coalesce(sum(total) filter (where reembolso = 'Transferencia'), 0), coalesce(sum(total), 0)
    into d_ef, d_tj, d_tr, d_tot from devoluciones where caja_id = p_id;
  v_ef := v_ef - d_ef; v_tj := v_tj - d_tj; v_tr := v_tr - d_tr; v_tot := v_tot - d_tot;
  select coalesce(sum((g->>'m')::numeric), 0) into v_g from jsonb_array_elements(coalesce(p_x->'g', '[]'::jsonb)) g;
  select coalesce(sum(key::numeric * value::numeric), 0) into v_ct from jsonb_each_text(coalesce(p_x->'cnt', '{}'::jsonb));
  v_esp := k.fondo + v_ef - v_g;
  if not forz and v_ct <> v_esp then
    raise exception 'La caja no cuadra: contado % y esperado %', v_ct, v_esp;
  end if;
  update cajas set cierre = now(), conteo = p_x->'cnt', gastos = p_x->'g',
         total = v_tot, ef = v_ef, tj = v_tj, tr = v_tr, nventas = v_n, esperado = v_esp, devol = d_tot
   where id = p_id returning * into k;
  return row_to_json(k);
end $$;

-- Totales de cajas (netos de devoluciones, con el reparto real por medio de pago)
create or replace function p_cajas_resumen(p_u text, p_c text, p_s bigint, p_desde timestamptz) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios;
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  if r.rol not in ('Master','Administrador') then raise exception 'No autorizado'; end if;
  return (select coalesce(json_agg(row_to_json(t) order by t.apertura desc), '[]'::json) from (
    select k.id, k.usuario, k.apertura, k.cierre, k.fondo,
      (select count(*) from ventas v where v.caja_id = k.id) as n,
      (select coalesce(sum(total), 0) from ventas v where v.caja_id = k.id) - (select coalesce(sum(total), 0) from devoluciones d where d.caja_id = k.id) as total,
      (select coalesce(sum(p_ef), 0) from ventas v where v.caja_id = k.id) - (select coalesce(sum(total) filter (where reembolso = 'Efectivo'), 0) from devoluciones d where d.caja_id = k.id) as ef,
      (select coalesce(sum(p_tj), 0) from ventas v where v.caja_id = k.id) - (select coalesce(sum(total) filter (where reembolso = 'Tarjeta'), 0) from devoluciones d where d.caja_id = k.id) as tj,
      (select coalesce(sum(p_tr), 0) from ventas v where v.caja_id = k.id) - (select coalesce(sum(total) filter (where reembolso = 'Transferencia'), 0) from devoluciones d where d.caja_id = k.id) as tr,
      (select coalesce(sum(total), 0) from devoluciones d where d.caja_id = k.id) as devol
    from cajas k
    where k.sucursal_id = p_s and (k.cierre is null or k.apertura >= p_desde)) t);
end $$;

create or replace function p_cajas_rango(p_u text, p_c text, p_s bigint, p_desde timestamptz, p_hasta timestamptz) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios;
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  if r.rol not in ('Master','Administrador') then raise exception 'No autorizado'; end if;
  return (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
    select k.id, k.sucursal_id, k.usuario, k.apertura, k.cierre, k.fondo, k.conteo, k.gastos, k.esperado,
      (select count(*) from ventas v where v.caja_id = k.id) as nventas,
      (select coalesce(sum(total), 0) from ventas v where v.caja_id = k.id) - (select coalesce(sum(total), 0) from devoluciones d where d.caja_id = k.id) as total,
      (select coalesce(sum(p_ef), 0) from ventas v where v.caja_id = k.id) - (select coalesce(sum(total) filter (where reembolso = 'Efectivo'), 0) from devoluciones d where d.caja_id = k.id) as ef,
      (select coalesce(sum(p_tj), 0) from ventas v where v.caja_id = k.id) - (select coalesce(sum(total) filter (where reembolso = 'Tarjeta'), 0) from devoluciones d where d.caja_id = k.id) as tj,
      (select coalesce(sum(p_tr), 0) from ventas v where v.caja_id = k.id) - (select coalesce(sum(total) filter (where reembolso = 'Transferencia'), 0) from devoluciones d where d.caja_id = k.id) as tr,
      (select coalesce(sum(total), 0) from devoluciones d where d.caja_id = k.id) as devol
    from cajas k
    where k.sucursal_id = p_s and k.apertura >= p_desde and k.apertura < p_hasta
    order by k.apertura limit 5000) t);
end $$;

-- Ventas recientes y búsqueda por número: ahora incluyen "pagos" (al Cajero se le quita el costo)
create or replace function p_ventas_list(p_u text, p_c text, p_s bigint, p_desde timestamptz) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios;
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  return (select coalesce(json_agg(row_to_json(t)), '[]'::json) from
          (select v.id, v.sucursal_id, v.numero, v.caja_id, v.usuario, v.fecha, v.total, v.metodo, v.cliente, v.recibido,
                  case when r.rol = 'Cajero' then (select coalesce(jsonb_agg(e - 'cs'), '[]'::jsonb) from jsonb_array_elements(v.items) e)
                       else v.items end as items,
                  v.estado, v.devueltos, v.pagos
             from ventas v
            where v.sucursal_id = p_s and v.fecha >= p_desde
              and (r.rol <> 'Cajero' or lower(v.usuario) = lower(r.usuario))
            order by v.fecha desc limit 5000) t);
end $$;

create or replace function p_venta_get(p_u text, p_c text, p_s bigint, p_n int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios;
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  return (select row_to_json(t) from
          (select v.id, v.sucursal_id, v.numero, v.caja_id, v.usuario, v.fecha, v.total, v.metodo, v.cliente, v.recibido,
                  case when r.rol = 'Cajero' then (select coalesce(jsonb_agg(e - 'cs'), '[]'::jsonb) from jsonb_array_elements(v.items) e)
                       else v.items end as items,
                  v.estado, v.devueltos, v.pagos
             from ventas v
            where v.sucursal_id = p_s and v.numero = p_n
              and (r.rol <> 'Cajero' or lower(v.usuario) = lower(r.usuario))) t);
end $$;

notify pgrst, 'reload schema';
