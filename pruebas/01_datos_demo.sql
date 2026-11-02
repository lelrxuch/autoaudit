-- =============================================================================
-- AutoAudit - pruebas/01_datos_demo.sql
-- Esquema de negocio de ejemplo sobre el cual se demuestra la auditoria.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS rrhh;

DROP TABLE IF EXISTS rrhh.empleado CASCADE;
CREATE TABLE rrhh.empleado (
    id          serial        PRIMARY KEY,
    nombre      varchar(100)  NOT NULL,
    puesto      varchar(80),
    salario     numeric(12,2),
    activo      boolean       NOT NULL DEFAULT true,
    observacion text
);

-- Tabla con llave primaria compuesta, para ejercitar ese caso del generador.
DROP TABLE IF EXISTS rrhh.asignacion CASCADE;
CREATE TABLE rrhh.asignacion (
    empleado_id integer      NOT NULL,
    proyecto    varchar(50)  NOT NULL,
    horas       numeric(6,2),
    PRIMARY KEY (empleado_id, proyecto)
);

-- Tabla sin llave primaria, para comprobar que el generador la rechaza.
DROP TABLE IF EXISTS rrhh.sin_llave CASCADE;
CREATE TABLE rrhh.sin_llave (
    dato varchar(50)
);
