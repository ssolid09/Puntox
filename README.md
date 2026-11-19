# PuntoX Smart POS

> Tu negocio, en un solo punto.

POS en un solo archivo (`index.html`): ventas con lector de código de barras, productos por unidad o por peso, inventario con proveedor, clientes, reportes, apertura y cierre de caja con cuadre e impresión térmica de 80 mm, y gestión de usuarios, roles, locales y sucursales.

## Qué se guarda dónde
- **Supabase:** usuarios (claves cifradas con bcrypt), locales, sucursales e **inventario de productos, independiente por sucursal**.
- **Navegador (localStorage):** ventas, clientes y cajas.

Cada usuario solo puede ver y modificar el inventario de su propia sucursal. El usuario maestro `SACC` ve todo.

## Configurar Supabase
1. Crea un proyecto en [supabase.com](https://supabase.com).
2. Instalación nueva: abre `supabase/schema.sql`, cambia `CAMBIA_ESTA_CLAVE` por la clave maestra de `SACC` y ejecútalo en **SQL Editor → Run**.
   Si ya ejecutaste versiones anteriores, ejecuta solo los archivos nuevos en orden: `v2_inventario_y_claves.sql` y luego `v3_modo_sin_conexion.sql`.
3. En **Project Settings → API** copia el *Project URL* y la clave *anon public*.
4. Pégalos en `config.js` (archivo aparte, no toques `index.html`).
5. Sube los cambios a GitHub: Vercel vuelve a desplegar solo.

La clave *anon* es pública por diseño; las tablas están cerradas con RLS y solo se usan funciones validadas en el servidor. **Nunca pongas la clave `service_role` en el código.** Si `SB_URL` queda vacío, la app funciona en modo local.

## Modo sin conexión
- **Manual (por local):** el maestro, en **Configuración → Locales**, usa **Desconectar / Reconectar**. Un local desconectado deja de usar Supabase: sus usuarios entran y operan con los datos guardados en su equipo.
- **Automático:** si Supabase no responde (caída, pausa del proyecto o plan gratuito excedido), el sistema pasa solo a modo sin conexión.
- **Quién puede entrar:** quien haya iniciado sesión al menos una vez con internet en ese equipo (acceso guardado con PBKDF2).
- **Pendientes:** ventas (descuento de stock) y cambios de inventario hechos sin conexión se guardan en el equipo y se envían al reconectar (botón ↻ o automático cada 2 minutos). No borres los datos del navegador mientras haya pendientes.
- **Sin conexión no se puede:** crear usuarios/locales/sucursales, resetear claves ni eliminar productos.

## Contraseñas
Cada usuario cambia la suya en **Mi perfil**. El maestro las resetea en **Configuración → Usuarios → Reset**.

## Instalar como app (PWA)
- **Chrome / Edge (PC y Android):** abre el sitio desplegado en Vercel y pulsa el ícono de instalar de la barra de direcciones, o el enlace **⬇ Instalar app** del pie de página.
- **iPhone / iPad (Safari):** Compartir → **Agregar a pantalla de inicio**.
- Se abre en su propia ventana, con ícono propio, y carga aunque no haya internet (junto al modo sin conexión).
- Archivos PWA: `manifest.webmanifest`, `sw.js` e `icons/`. Súbelos junto con `index.html`.

## Despliegue en Vercel
Importa el repositorio en [vercel.com](https://vercel.com) → **Add New → Project → Deploy**.

## Impresión térmica
Instala la impresora en el sistema; al imprimir elige papel de 80 mm y márgenes en "ninguno". Para abrir el cajón, activa "abrir cajón al imprimir" en el driver.
