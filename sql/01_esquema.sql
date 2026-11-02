-- =============================================================================
-- AutoAudit - Sistema de auditoria automatizado
-- 01_esquema.sql : esquema y tablas del sistema
--
-- Curso : Bases de Datos I (22026-090-027-5)
-- DBMS  : PostgreSQL 18 (compatible desde 13)
--
-- Crea el esquema "audit" y las siete tablas que sostienen la configuracion
-- de auditoria y la bitacora centralizada de cambios.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS audit;

COMMENT ON SCHEMA audit IS
  'Sistema AutoAudit: configuracion de auditoria y bitacora centralizada de cambios.';

-- -----------------------------------------------------------------------------
-- Rol administrativo. Solo los miembros de este rol pueden configurar auditoria.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autoaudit_admin') THEN
    CREATE ROLE autoaudit_admin;
  END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- tipo_evento : catalogo de operaciones DML auditables.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.tipo_evento (
    id              smallint     PRIMARY KEY,
    codigo          varchar(10)  NOT NULL UNIQUE,
    descripcion     varchar(100) NOT NULL,
    CONSTRAINT ck_tipo_evento_codigo
        CHECK (codigo IN ('INSERT', 'UPDATE', 'DELETE'))
);

COMMENT ON TABLE  audit.tipo_evento IS 'Catalogo de operaciones DML que el sistema puede auditar.';
COMMENT ON COLUMN audit.tipo_evento.codigo IS 'Operacion DML: INSERT, UPDATE o DELETE.';

-- -----------------------------------------------------------------------------
-- tabla_auditada : tablas del esquema de negocio habilitadas para auditoria.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.tabla_auditada (
    id                  serial       PRIMARY KEY,
    esquema             varchar(63)  NOT NULL,
    tabla               varchar(63)  NOT NULL,
    activa              boolean      NOT NULL DEFAULT true,
    trigger_desplegado  boolean      NOT NULL DEFAULT false,
    fecha_registro      timestamptz  NOT NULL DEFAULT now(),
    usuario_registro    varchar(63)  NOT NULL DEFAULT session_user,
    CONSTRAINT uq_tabla_auditada UNIQUE (esquema, tabla)
);

COMMENT ON TABLE  audit.tabla_auditada IS 'Tablas habilitadas para auditoria. Una fila por tabla origen.';
COMMENT ON COLUMN audit.tabla_auditada.activa IS 'Desactivar suspende la auditoria sin borrar la configuracion ni la bitacora.';
COMMENT ON COLUMN audit.tabla_auditada.trigger_desplegado IS 'Indica si el trigger generado esta instalado en la tabla origen.';

-- -----------------------------------------------------------------------------
-- columna_auditada : columnas vigiladas dentro de cada tabla habilitada.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.columna_auditada (
    id                  serial       PRIMARY KEY,
    tabla_auditada_id   integer      NOT NULL,
    columna             varchar(63)  NOT NULL,
    activa              boolean      NOT NULL DEFAULT true,
    fecha_registro      timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_columna_auditada UNIQUE (tabla_auditada_id, columna),
    CONSTRAINT fk_columna_tabla FOREIGN KEY (tabla_auditada_id)
        REFERENCES audit.tabla_auditada (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_columna_tabla
    ON audit.columna_auditada (tabla_auditada_id) WHERE activa;

COMMENT ON TABLE audit.columna_auditada IS
  'Columnas vigiladas dentro de una tabla habilitada. Permite seleccion granular.';

-- -----------------------------------------------------------------------------
-- configuracion : que evento se registra ante el cambio de que columna.
-- Es la entidad central del modelo y la referencia de cada fila de bitacora.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.configuracion (
    id                      serial       PRIMARY KEY,
    columna_auditada_id     integer      NOT NULL,
    tipo_evento_id          smallint     NOT NULL,
    activa                  boolean      NOT NULL DEFAULT true,
    fecha_creacion          timestamptz  NOT NULL DEFAULT now(),
    usuario_creacion        varchar(63)  NOT NULL DEFAULT session_user,
    CONSTRAINT uq_configuracion UNIQUE (columna_auditada_id, tipo_evento_id),
    CONSTRAINT fk_config_columna FOREIGN KEY (columna_auditada_id)
        REFERENCES audit.columna_auditada (id) ON DELETE RESTRICT,
    CONSTRAINT fk_config_evento FOREIGN KEY (tipo_evento_id)
        REFERENCES audit.tipo_evento (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_config_columna
    ON audit.configuracion (columna_auditada_id) WHERE activa;

COMMENT ON TABLE audit.configuracion IS
  'Une una columna vigilada con un tipo de evento. Cada fila de bitacora apunta aqui.';
COMMENT ON CONSTRAINT fk_config_columna ON audit.configuracion IS
  'RESTRICT: la configuracion no se elimina mientras exista bitacora que la referencie.';

-- -----------------------------------------------------------------------------
-- usuario_auditado : usuarios de base de datos responsables de los cambios.
-- Las filas se crean solas la primera vez que el usuario produce un cambio.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.usuario_auditado (
    id                  serial       PRIMARY KEY,
    nombre_usuario      varchar(63)  NOT NULL UNIQUE,
    primera_actividad   timestamptz  NOT NULL DEFAULT now(),
    ultima_actividad    timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE audit.usuario_auditado IS
  'Usuarios de base de datos que han producido cambios auditados. Alta automatica.';

-- -----------------------------------------------------------------------------
-- estacion_trabajo : origen de red desde donde se realizo el cambio.
-- La direccion es nullable porque las conexiones por socket local no reportan IP.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.estacion_trabajo (
    id                  serial       PRIMARY KEY,
    direccion_ip        inet,
    nombre_host         varchar(255),
    primera_actividad   timestamptz  NOT NULL DEFAULT now(),
    ultima_actividad    timestamptz  NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_estacion_ip
    ON audit.estacion_trabajo (direccion_ip) WHERE direccion_ip IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_estacion_local
    ON audit.estacion_trabajo ((1)) WHERE direccion_ip IS NULL;

COMMENT ON TABLE audit.estacion_trabajo IS
  'Estaciones de trabajo identificadas por direccion de red. Una sola fila agrupa las conexiones locales.';
COMMENT ON COLUMN audit.estacion_trabajo.direccion_ip IS
  'Nulo para conexiones por socket local, que no reportan direccion de red.';

-- -----------------------------------------------------------------------------
-- bitacora : registro centralizado de cambios.
--
-- No lleva llave foranea hacia las tablas origen de forma deliberada. El
-- enunciado exige que la bitacora conserve los datos aunque el registro fuente
-- se elimine, y una llave foranea hacia el dato auditado lo impediria. La
-- integridad referencial se mantiene hacia la configuracion, el usuario y la
-- estacion, que son entidades del propio sistema de auditoria.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.bitacora (
    id                  bigserial    PRIMARY KEY,
    configuracion_id    integer      NOT NULL,
    usuario_id          integer      NOT NULL,
    estacion_id         integer      NOT NULL,
    fecha_hora          timestamptz  NOT NULL DEFAULT clock_timestamp(),
    clave_primaria      text         NOT NULL,
    valor_anterior      text,
    valor_nuevo         text,
    id_transaccion      bigint       NOT NULL DEFAULT txid_current(),
    CONSTRAINT fk_bitacora_config FOREIGN KEY (configuracion_id)
        REFERENCES audit.configuracion (id) ON DELETE RESTRICT,
    CONSTRAINT fk_bitacora_usuario FOREIGN KEY (usuario_id)
        REFERENCES audit.usuario_auditado (id) ON DELETE RESTRICT,
    CONSTRAINT fk_bitacora_estacion FOREIGN KEY (estacion_id)
        REFERENCES audit.estacion_trabajo (id) ON DELETE RESTRICT
);

COMMENT ON TABLE audit.bitacora IS
  'Registro centralizado de cambios. Conserva los datos aunque el registro fuente se elimine.';
COMMENT ON COLUMN audit.bitacora.clave_primaria IS
  'Valor de la llave primaria del registro afectado, en texto. Permite rastrear la fila sin depender de que siga existiendo.';
COMMENT ON COLUMN audit.bitacora.valor_anterior IS
  'Valor previo de la columna. Nulo en INSERT.';
COMMENT ON COLUMN audit.bitacora.valor_nuevo IS
  'Valor posterior de la columna. Nulo en DELETE.';
COMMENT ON COLUMN audit.bitacora.id_transaccion IS
  'Identificador de transaccion. Agrupa los cambios producidos por una misma sentencia o transaccion.';

-- Indices que sostienen las consultas historicas exigidas por el enunciado.
CREATE INDEX IF NOT EXISTS ix_bitacora_usuario_fecha
    ON audit.bitacora (usuario_id, fecha_hora DESC);
CREATE INDEX IF NOT EXISTS ix_bitacora_config_fecha
    ON audit.bitacora (configuracion_id, fecha_hora DESC);
CREATE INDEX IF NOT EXISTS ix_bitacora_fecha
    ON audit.bitacora (fecha_hora DESC);
CREATE INDEX IF NOT EXISTS ix_bitacora_clave
    ON audit.bitacora (clave_primaria);

-- -----------------------------------------------------------------------------
-- Privilegios.
--
-- La bitacora no admite escritura directa. Las unicas inserciones legitimas
-- provienen de las funciones de trigger, que se declaran SECURITY DEFINER en
-- 03_generador.sql y por lo tanto escriben con los privilegios del propietario
-- del esquema, no con los del usuario que disparo el cambio.
-- -----------------------------------------------------------------------------
REVOKE ALL ON audit.bitacora FROM PUBLIC;
REVOKE ALL ON audit.configuracion FROM PUBLIC;
REVOKE ALL ON audit.columna_auditada FROM PUBLIC;
REVOKE ALL ON audit.tabla_auditada FROM PUBLIC;

GRANT USAGE ON SCHEMA audit TO PUBLIC;
GRANT SELECT ON audit.bitacora TO PUBLIC;
GRANT SELECT ON audit.tipo_evento TO PUBLIC;

GRANT SELECT, INSERT, UPDATE, DELETE
    ON audit.tabla_auditada, audit.columna_auditada, audit.configuracion
    TO autoaudit_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO autoaudit_admin;
