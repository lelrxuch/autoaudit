# AutoAudit

Sistema de auditoría automatizado para PostgreSQL. Registra en una bitácora
centralizada todo cambio sobre las columnas que el administrador decida
vigilar, generando dinámicamente los triggers necesarios.

Proyecto del curso Bases de Datos I, Universidad Mariano Gálvez de Guatemala.

## Instalación

Requiere PostgreSQL 18 sobre Ubuntu 26.04 LTS. Validado también en PostgreSQL
16, pues no usa construcciones posteriores a la versión 13.

```
psql -d basedatos -f sql/00_instalar.sql
```

Esto crea el esquema `audit` con sus siete tablas, el catálogo de eventos, el
generador de triggers y las vistas de consulta al diccionario de datos. El
sistema queda instalado e inactivo hasta que se configure qué auditar.

## Uso mínimo

Habilitar una tabla supone registrarla, registrar sus columnas vigiladas y
registrar una configuración por cada combinación de columna y tipo de evento.
El archivo `pruebas/02_configuracion_demo.sql` muestra el procedimiento
completo sobre una tabla de ejemplo.

Hecha la configuración, se despliegan los triggers:

```sql
SELECT objeto, resultado FROM audit.regenerar_todos();
```

Para revisar el código antes de instalarlo:

```sql
SELECT audit.generar_trigger('rrhh', 'empleado');
```

El estado de la auditoría se consulta en `audit.v_estado_auditoria`.

## Estructura del repositorio

| Ruta | Contenido |
|:--|:--|
| `sql/00_instalar.sql` | Instalación completa en orden de dependencia |
| `sql/01_esquema.sql` | Esquema, siete tablas, índices y privilegios |
| `sql/02_catalogos.sql` | Catálogo de eventos y funciones de contexto y registro |
| `sql/03_generador.sql` | Generación dinámica de triggers y vista de estado |
| `sql/04_diccionario_sistema.sql` | Vistas de consulta al diccionario del motor |
| `pruebas/01_datos_demo.sql` | Esquema de negocio de ejemplo |
| `pruebas/02_configuracion_demo.sql` | Configuración de auditoría de ejemplo |
| `pruebas/03_pruebas_funcionales.sql` | Nueve casos de prueba con aserciones |
| `pruebas/04_pruebas_rendimiento.sql` | Medición con volumen creciente |
| `pruebas/RESULTADOS.md` | Resultados de la última ejecución |
| `docs/AutoAudit_documentacion_tecnica.pdf` | Documento técnico entregable |
| `docs/contrato_integracion.md` | Firmas fijas para el trabajo en paralelo |
| `docs/er.mmd` | Fuente del diagrama entidad-relación |

## Pruebas

```
psql -d basedatos -f pruebas/01_datos_demo.sql
psql -d basedatos -f pruebas/02_configuracion_demo.sql
psql -d basedatos -f pruebas/03_pruebas_funcionales.sql
psql -d basedatos -f pruebas/04_pruebas_rendimiento.sql
```

Las pruebas funcionales abortan al primer fallo, de modo que una ejecución
completa sin errores equivale a que los nueve casos pasaron.

## Decisiones de diseño

La bitácora no tiene llave foránea hacia las tablas de negocio. El enunciado
exige que conserve los datos aunque el registro fuente se elimine, y una llave
foránea hacia el dato auditado lo impediría. La identidad del registro se
conserva en la columna `clave_primaria`, en texto.

La escritura directa en la bitácora está revocada. Las únicas inserciones
posibles provienen de las funciones de trigger, declaradas `SECURITY DEFINER`.

La lista de columnas vigiladas va empotrada en el código del trigger, lo que
mantiene bajo el costo por fila. Un cambio estructural de la configuración
exige regenerar; activar o desactivar una configuración existente no, porque la
bandera se consulta en tiempo de ejecución.

El usuario y la estación de trabajo se resuelven una sola vez por sesión y se
conservan en variables de configuración de sesión. Sin esa memoria intermedia,
una carga masiva acumula cientos de miles de versiones muertas sobre tablas de
una sola fila y el rendimiento se degrada de forma severa.
