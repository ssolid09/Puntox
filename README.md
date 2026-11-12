# PuntoX Smart POS

> Tu negocio, en un solo punto.

Sistema POS en un solo archivo (`index.html`): ventas con lector de código de barras, inventario, clientes, reportes, apertura y cierre de caja con cuadre e impresión en impresora térmica de 80 mm, y gestión de usuarios, roles, locales y sucursales.

## Usuario maestro
Usuario `SACC`. La clave se define en `index.html`, constante `MASTER_PASS`. **Cámbiala antes de publicar.**

## Despliegue
1. Sube estos archivos a un repositorio de GitHub.
2. En [vercel.com](https://vercel.com) elige **Add New → Project**, importa el repositorio y pulsa **Deploy** (sin configuración adicional).

## Impresión térmica
Instala la impresora en el sistema, y al cerrar caja elige papel de 80 mm y márgenes en "ninguno".

## Limitaciones
Los datos se guardan en el `localStorage` del navegador y las credenciales están en el código del cliente. Para uso real con varias cajas hace falta un backend con autenticación y base de datos.
