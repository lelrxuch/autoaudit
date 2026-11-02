-- =============================================================================
-- AutoAudit - 04_diccionario_sistema.sql
-- Consultas al diccionario de datos del DBMS.
--
-- El enunciado exige entregar las consultas que obtienen la estructura de la
-- base. Aqui se encapsulan en vistas para que el modulo de configuracion y la
-- interfaz las consuman sin repetir el detalle del catalogo de PostgreSQL.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tablas candidatas a auditoria: tablas base de los esquemas de usuario, con
-- indicacion de si tienen llave primaria, requisito para poder auditarlas.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW audit.v_diccionario_tablas AS
SELECT
    n.nspname::varchar(63)  AS esquema,
    c.relname::varchar(63)  AS tabla,
    obj_description(c.oid, 'pg_class') AS comentario,
    EXISTS (
        SELECT 1 FROM pg_constraint pk
         WHERE pk.conrelid = c.oid AND pk.contype = 'p'
    ) AS tiene_llave_primaria,
    c.reltuples::bigint AS filas_estimadas
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'audit')
  AND n.nspname NOT LIKE 'pg_%';

COMMENT ON VIEW audit.v_diccionario_tablas IS
  'Tablas de los esquemas de usuario que pueden habilitarse para auditoria.';

-- -----------------------------------------------------------------------------
-- Columnas de esas tablas, con tipo de dato y nulabilidad.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW audit.v_diccionario_columnas AS
SELECT
    n.nspname::varchar(63)  AS esquema,
    c.relname::varchar(63)  AS tabla,
    a.attname::varchar(63)  AS columna,
    a.attnum                AS posicion,
    format_type(a.atttypid, a.atttypmod) AS tipo_dato,
    NOT a.attnotnull        AS admite_nulos,
    col_description(c.oid, a.attnum) AS comentario,
    EXISTS (
        SELECT 1 FROM pg_constraint pk
         WHERE pk.conrelid = c.oid AND pk.contype = 'p'
           AND a.attnum = ANY (pk.conkey)
    ) AS es_llave_primaria
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid
WHERE c.relkind = 'r'
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_%';

COMMENT ON VIEW audit.v_diccionario_columnas IS
  'Columnas de las tablas de usuario, con tipo de dato y marca de llave primaria.';

GRANT SELECT ON audit.v_diccionario_tablas, audit.v_diccionario_columnas TO PUBLIC;
