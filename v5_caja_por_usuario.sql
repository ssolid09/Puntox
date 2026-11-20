-- PuntoX Smart POS · v5: una caja por usuario + totales de todas las cajas de la sucursal.
-- Ejecuta SOLO este archivo si ya ejecutaste schema.sql, v2, v3 y v4. Es seguro ejecutarlo más de una vez.

-- Antes: una caja abierta por sucursal. Ahora: una caja abierta por usuario en cada sucursal.
drop index if exists cajas_una_abierta;
create unique index if not exists cajas_una_abierta_usuario on cajas (sucursal_id, lower(usuario)) where cierre is null;

-- Apertura: cada usuario abre SU caja (si ya tiene una abierta, devuelve esa).
-- p_usuario solo lo usa la sincronización de aperturas hechas sin conexión.
drop function if exists p_caja_abrir(text, text, bigint, numeric);
create or replace function p_caja_abrir(p_u text, p_c text, p_s bigint, p_fondo numeric, p_usuario text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios; k cajas; own text;
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  if r.rol not in ('Master','Administrador','Cajero') then raise exception 'No autorizado'; end if;
  own := coalesce(nullif(p_usuario, ''), r.usuario);
  if lower(own) <> lower(r.usuario)
     and not exists (select 1 from usuarios where lower(usuario) = lower(own) and sucursal_id = p_s) then
    raise exception 'Usuario inválido';
  end if;
  select * into k from cajas where sucursal_id = p_s and cierre is null and lower(usuario) = lower(own);
  if found then return row_to_json(k); end if;
  insert into cajas (sucursal_id, usuario, fondo) values (p_s, own, greatest(coalesce(p_fondo, 0), 0)) returning * into k;
  return row_to_json(k);
end $$;

-- Venta: se registra en la caja abierta del usuario que vende
create or replace function p_venta_reg(p_u text, p_c text, p_s bigint, p_x jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios; cid bigint; num int; vid bigint; it jsonb;
        forz boolean := coalesce((p_x->>'forzar')::boolean, false);
        own text;
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  if r.rol not in ('Master','Administrador','Cajero') then raise exception 'No autorizado'; end if;
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
  insert into contadores (sucursal_id, ultimo) values (p_s, 1)
    on conflict (sucursal_id) do update set ultimo = contadores.ultimo + 1
    returning ultimo into num;
  insert into ventas (sucursal_id, numero, caja_id, usuario, fecha, total, metodo, cliente, recibido, items)
  values (p_s, num, cid, own,
          coalesce(to_timestamp(nullif(p_x->>'t', '')::numeric / 1000.0), now()),
          (p_x->>'tot')::numeric, p_x->>'m', nullif(p_x->>'cli', ''),
          coalesce(nullif(p_x->>'rec', '')::numeric, (p_x->>'tot')::numeric), p_x->'items')
  returning id into vid;
  return json_build_object('id', vid, 'numero', num);
end $$;

-- Cierre: solo el dueño de la caja (o un Administrador/Master) puede cerrarla
create or replace function p_caja_cerrar(p_u text, p_c text, p_s bigint, p_id bigint, p_x jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios; k cajas; v_ef numeric; v_tj numeric; v_tr numeric; v_tot numeric; v_n int; v_g numeric; v_ct numeric; v_esp numeric;
        forz boolean := coalesce((p_x->>'forzar')::boolean, false);
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  if r.rol not in ('Master','Administrador','Cajero') then raise exception 'No autorizado'; end if;
  select * into k from cajas where id = p_id and sucursal_id = p_s and cierre is null;
  if not found then raise exception 'La caja ya está cerrada o no existe'; end if;
  if lower(k.usuario) <> lower(r.usuario) and r.rol not in ('Master','Administrador') and not forz then
    raise exception 'Solo el cajero dueño de esta caja puede cerrarla';
  end if;
  select coalesce(sum(total) filter (where metodo = 'Efectivo'), 0), coalesce(sum(total) filter (where metodo = 'Tarjeta'), 0),
         coalesce(sum(total) filter (where metodo = 'Transferencia'), 0), coalesce(sum(total), 0), count(*)
    into v_ef, v_tj, v_tr, v_tot, v_n from ventas where caja_id = p_id;
  select coalesce(sum((g->>'m')::numeric), 0) into v_g from jsonb_array_elements(coalesce(p_x->'g', '[]'::jsonb)) g;
  select coalesce(sum(key::numeric * value::numeric), 0) into v_ct from jsonb_each_text(coalesce(p_x->'cnt', '{}'::jsonb));
  v_esp := k.fondo + v_ef - v_g;
  if not forz and v_ct <> v_esp then
    raise exception 'La caja no cuadra: contado % y esperado %', v_ct, v_esp;
  end if;
  update cajas set cierre = now(), conteo = p_x->'cnt', gastos = p_x->'g',
         total = v_tot, ef = v_ef, tj = v_tj, tr = v_tr, nventas = v_n, esperado = v_esp
   where id = p_id returning * into k;
  return row_to_json(k);
end $$;

-- Mis cajas: la abierta + mis últimos cierres
create or replace function p_cajas_list(p_u text, p_c text, p_s bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios;
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  return (select coalesce(json_agg(row_to_json(t)), '[]'::json) from
          (select * from cajas where sucursal_id = p_s and lower(usuario) = lower(r.usuario)
            order by (cierre is null) desc, id desc limit 11) t);
end $$;

-- Ventas: el Cajero solo ve las suyas; Administrador y Master ven toda la sucursal
create or replace function p_ventas_list(p_u text, p_c text, p_s bigint, p_desde timestamptz) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios;
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  return (select coalesce(json_agg(row_to_json(t)), '[]'::json) from
          (select * from ventas where sucursal_id = p_s and fecha >= p_desde
             and (r.rol <> 'Cajero' or lower(usuario) = lower(r.usuario))
            order by fecha desc limit 5000) t);
end $$;

-- Totales de TODAS las cajas de la sucursal (solo Master y Administrador)
create or replace function p_cajas_resumen(p_u text, p_c text, p_s bigint, p_desde timestamptz) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r usuarios;
begin
  r := private.p_auth(p_u, p_c); perform private.p_ok(r, p_s);
  if r.rol not in ('Master','Administrador') then raise exception 'No autorizado'; end if;
  return (select coalesce(json_agg(row_to_json(t) order by t.apertura desc), '[]'::json) from (
    select k.id, k.usuario, k.apertura, k.cierre, k.fondo,
           count(v.id) as n,
           coalesce(sum(v.total), 0) as total,
           coalesce(sum(v.total) filter (where v.metodo = 'Efectivo'), 0) as ef,
           coalesce(sum(v.total) filter (where v.metodo = 'Tarjeta'), 0) as tj,
           coalesce(sum(v.total) filter (where v.metodo = 'Transferencia'), 0) as tr
      from cajas k left join ventas v on v.caja_id = k.id
     where k.sucursal_id = p_s and (k.cierre is null or k.apertura >= p_desde)
     group by k.id) t);
end $$;

notify pgrst, 'reload schema';
