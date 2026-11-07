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

Habilitar una tabla es una sola llamada. Valida contra el diccionario de datos,
persiste la configuración y despliega el trigger, todo en una transacción:

```sql
SELECT audit.configurar_auditoria(
           'rrhh', 'empleado',
           ARRAY['nombre', 'puesto', 'salario'],
           ARRAY['INSERT', 'UPDATE', 'DELETE']);
```

Consultar el historial:

```sql
SELECT * FROM audit.consultar_por_usuario('isai');
SELECT * FROM audit.consultar_por_columna('rrhh', 'empleado', 'salario');
SELECT * FROM audit.consultar_por_registro('rrhh', 'empleado', 'id=42');
```

Suspender sin perder la bitácora:

```sql
SELECT audit.desactivar_evento('rrhh', 'empleado', 'salario', 'UPDATE');
SELECT audit.desactivar_tabla('rrhh', 'empleado');
```

El estado se consulta en `audit.v_estado_auditoria`. Para revisar el código de
un trigger antes de instalarlo, `audit.generar_trigger('rrhh', 'empleado')` lo
devuelve como texto sin ejecutarlo.

## Interfaz gráfica

```bash
sudo dnf install -y python3-tkinter     # en Fedora tkinter va en paquete aparte
pip install psycopg2-binary

export AUTOAUDIT_DB=autoaudit
export AUTOAUDIT_USER=$USER
python3 app/autoaudit_app.py
```

Tres pestañas: configuración, bitácora y estado. No construye SQL de
configuración por su cuenta, llama a las funciones del esquema `audit`, de modo
que la validación y el control de privilegios existen en un solo lugar. Los
parámetros de conexión salen del entorno: no hay credenciales en el código.

## Estructura del repositorio

| Ruta | Contenido |
|:--|:--|
| `sql/00_instalar.sql` | Instalación completa en orden de dependencia |
| `sql/01_esquema.sql` | Esquema, siete tablas, índices y privilegios |
| `sql/02_catalogos.sql` | Catálogo de eventos y funciones de contexto y registro |
| `sql/03_generador.sql` | Generación dinámica de triggers y vista de estado |
| `sql/04_diccionario_sistema.sql` | Vistas de consulta al diccionario del motor |
| `sql/05_configuracion.sql` | Módulo de configuración: validación, privilegios, activación y suspensión |
| `sql/06_reportes.sql` | Consultas parametrizadas de historial y vistas de reporte |
| `app/autoaudit_app.py` | Interfaz gráfica de configuración y reportes |
| `pruebas/01_datos_demo.sql` | Esquema de negocio de ejemplo |
| `pruebas/02_configuracion_demo.sql` | Configuración de auditoría de ejemplo |
| `pruebas/03_pruebas_funcionales.sql` | Nueve casos sobre el generador y la bitácora |
| `pruebas/04_pruebas_rendimiento.sql` | Medición con volumen creciente |
| `pruebas/05_pruebas_configuracion.sql` | Trece casos sobre configuración, seguridad y consultas |
| `pruebas/RESULTADOS.md` | Resultados de la última ejecución |
| `docs/AutoAudit_documentacion_tecnica.pdf` | Documento técnico entregable |
| `docs/contrato_integracion.md` | Firmas fijas para el trabajo en paralelo |
| `docs/er.mmd` | Fuente del diagrama entidad-relación |

## Pruebas

```
psql -d basedatos -f pruebas/01_datos_demo.sql
psql -d basedatos -f pruebas/02_configuracion_demo.sql
psql -d basedatos -f pruebas/03_pruebas_funcionales.sql
psql -d basedatos -f pruebas/05_pruebas_configuracion.sql
psql -d basedatos -f pruebas/04_pruebas_rendimiento.sql
```

Son veintidós casos con aserciones, nueve sobre el generador y la bitácora y
trece sobre configuración, seguridad y consultas. Los guiones abortan al primer
fallo, de modo que una ejecución completa sin errores equivale a que todos
pasaron.

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

La validación y el control de privilegios viven en la base y no en la interfaz.
Una configuración hecha desde `psql` pasa por los mismos controles que una
hecha desde la aplicación, y el requisito de que solo usuarios administrativos
puedan configurar auditoría no depende de un cliente que se puede modificar.

`audit.regenerar_todos` no propaga las excepciones: captura el error de cada
tabla y lo devuelve como texto en una columna del resultado. Las funciones de
configuración revisan esa salida antes de confirmar la transacción, porque no
hacerlo deja configuraciones inválidas persistidas que impiden todo despliegue
posterior de esa tabla.
