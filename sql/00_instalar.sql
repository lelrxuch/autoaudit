-- =============================================================================
-- AutoAudit - 00_instalar.sql
-- Instalacion completa del sistema. Ejecuta los guiones en orden de dependencia.
--
--   psql -d basedatos -f sql/00_instalar.sql
-- =============================================================================

\set ON_ERROR_STOP on

\echo 'AutoAudit: creando esquema y tablas del sistema...'
\ir 01_esquema.sql

\echo 'AutoAudit: cargando catalogos y funciones de contexto...'
\ir 02_catalogos.sql

\echo 'AutoAudit: instalando el generador de triggers...'
\ir 03_generador.sql

\echo 'AutoAudit: instalando vistas del diccionario de datos...'
\ir 04_diccionario_sistema.sql

\echo 'AutoAudit: instalando el modulo de configuracion...'
\ir 05_configuracion.sql

\echo 'AutoAudit: instalando el modulo de consulta y reporte...'
\ir 06_reportes.sql

\echo 'AutoAudit: instalacion terminada.'
\echo 'Configure las tablas a auditar y ejecute: SELECT * FROM audit.regenerar_todos();'
