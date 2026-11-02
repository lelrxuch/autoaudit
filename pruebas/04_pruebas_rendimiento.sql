-- =============================================================================
-- AutoAudit - pruebas/04_pruebas_rendimiento.sql
-- Pruebas de rendimiento con volumen creciente de registros auditados.
--
-- Mide tres cosas: el costo que el trigger agrega a las operaciones DML, como
-- evoluciona ese costo conforme la bitacora crece, y el tiempo de las consultas
-- historicas sobre una bitacora cada vez mas grande.
-- =============================================================================

\set ON_ERROR_STOP on

-- -----------------------------------------------------------------------------
-- Tabla de carga y su configuracion de auditoria.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS rrhh.carga CASCADE;
CREATE TABLE rrhh.carga (
    id       serial        PRIMARY KEY,
    codigo   varchar(30)   NOT NULL,
    monto    numeric(12,2),
    estado   varchar(20)
);

DO $$
DECLARE
    v_tabla integer;
BEGIN
    INSERT INTO audit.tabla_auditada (esquema, tabla)
    VALUES ('rrhh', 'carga')
    ON CONFLICT (esquema, tabla) DO UPDATE SET activa = true
    RETURNING id INTO v_tabla;

    INSERT INTO audit.columna_auditada (tabla_auditada_id, columna)
    SELECT v_tabla, c.columna
      FROM (VALUES ('codigo'), ('monto'), ('estado')) AS c(columna)
    ON CONFLICT (tabla_auditada_id, columna) DO UPDATE SET activa = true;

    INSERT INTO audit.configuracion (columna_auditada_id, tipo_evento_id)
    SELECT col.id, te.id
      FROM audit.columna_auditada col
      CROSS JOIN audit.tipo_evento te
     WHERE col.tabla_auditada_id = v_tabla
    ON CONFLICT (columna_auditada_id, tipo_evento_id) DO UPDATE SET activa = true;
END;
$$;

CREATE TEMP TABLE resultado_rendimiento (
    escenario       text,
    volumen         integer,
    milisegundos    numeric(12,2),
    filas_bitacora  bigint,
    microseg_x_fila numeric(12,3)
);

-- -----------------------------------------------------------------------------
-- Medicion 1. Insercion con volumen creciente, sin auditoria y con auditoria.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_tabla   integer;
    v_vol     integer;
    v_ini     timestamptz;
    v_ms      numeric;
    v_bit     bigint;
    v_vols    integer[] := ARRAY[1000, 5000, 20000, 50000];
BEGIN
    SELECT id INTO v_tabla FROM audit.tabla_auditada
     WHERE esquema = 'rrhh' AND tabla = 'carga';

    -- Linea base: la misma carga sin trigger instalado.
    PERFORM audit.eliminar_trigger(v_tabla);

    FOREACH v_vol IN ARRAY v_vols LOOP
        TRUNCATE rrhh.carga RESTART IDENTITY;
        v_ini := clock_timestamp();

        INSERT INTO rrhh.carga (codigo, monto, estado)
        SELECT 'COD-' || g, (g % 1000) * 1.5, 'inicial'
          FROM generate_series(1, v_vol) g;

        v_ms := extract(epoch FROM clock_timestamp() - v_ini) * 1000;

        INSERT INTO resultado_rendimiento
        VALUES ('INSERT sin auditoria', v_vol, round(v_ms, 2), 0,
                round((v_ms * 1000) / v_vol, 3));
    END LOOP;

    -- Con auditoria de tres columnas en las tres operaciones.
    PERFORM audit.aplicar_trigger(v_tabla);

    FOREACH v_vol IN ARRAY v_vols LOOP
        TRUNCATE rrhh.carga RESTART IDENTITY;
        v_ini := clock_timestamp();

        INSERT INTO rrhh.carga (codigo, monto, estado)
        SELECT 'COD-' || g, (g % 1000) * 1.5, 'inicial'
          FROM generate_series(1, v_vol) g;

        v_ms := extract(epoch FROM clock_timestamp() - v_ini) * 1000;
        SELECT count(*) INTO v_bit FROM audit.bitacora;

        INSERT INTO resultado_rendimiento
        VALUES ('INSERT con auditoria', v_vol, round(v_ms, 2), v_bit,
                round((v_ms * 1000) / v_vol, 3));
    END LOOP;
END;
$$;

-- -----------------------------------------------------------------------------
-- Medicion 2. Actualizacion masiva con la bitacora ya cargada. Se actualiza
-- una sola columna vigilada, de modo que el trigger descarta las otras dos.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_vol integer;
    v_ini timestamptz;
    v_ms  numeric;
    v_bit bigint;
BEGIN
    FOREACH v_vol IN ARRAY ARRAY[1000, 5000, 20000] LOOP
        v_ini := clock_timestamp();

        UPDATE rrhh.carga
           SET monto = monto + 1
         WHERE id <= v_vol;

        v_ms := extract(epoch FROM clock_timestamp() - v_ini) * 1000;
        SELECT count(*) INTO v_bit FROM audit.bitacora;

        INSERT INTO resultado_rendimiento
        VALUES ('UPDATE con auditoria', v_vol, round(v_ms, 2), v_bit,
                round((v_ms * 1000) / v_vol, 3));
    END LOOP;
END;
$$;

-- -----------------------------------------------------------------------------
-- Medicion 3. Eliminacion masiva, que es el caso mas costoso porque registra
-- todas las columnas vigiladas de cada fila.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_ini timestamptz;
    v_ms  numeric;
    v_bit bigint;
    v_vol integer := 10000;
BEGIN
    v_ini := clock_timestamp();
    DELETE FROM rrhh.carga WHERE id <= v_vol;
    v_ms := extract(epoch FROM clock_timestamp() - v_ini) * 1000;
    SELECT count(*) INTO v_bit FROM audit.bitacora;

    INSERT INTO resultado_rendimiento
    VALUES ('DELETE con auditoria', v_vol, round(v_ms, 2), v_bit,
            round((v_ms * 1000) / v_vol, 3));
END;
$$;

-- -----------------------------------------------------------------------------
-- Medicion 4. Consultas historicas sobre la bitacora ya voluminosa.
-- -----------------------------------------------------------------------------
ANALYZE audit.bitacora;

DO $$
DECLARE
    v_ini timestamptz;
    v_ms  numeric;
    v_bit bigint;
    v_n   integer;
    v_usr integer;
    v_cfg integer;
BEGIN
    SELECT count(*) INTO v_bit FROM audit.bitacora;

    SELECT usuario_id INTO v_usr FROM audit.bitacora LIMIT 1;
    v_ini := clock_timestamp();
    SELECT count(*) INTO v_n FROM audit.bitacora WHERE usuario_id = v_usr;
    v_ms := extract(epoch FROM clock_timestamp() - v_ini) * 1000;
    INSERT INTO resultado_rendimiento
    VALUES ('Consulta por usuario', v_n, round(v_ms, 2), v_bit, NULL);

    SELECT configuracion_id INTO v_cfg FROM audit.bitacora LIMIT 1;
    v_ini := clock_timestamp();
    SELECT count(*) INTO v_n FROM audit.bitacora WHERE configuracion_id = v_cfg;
    v_ms := extract(epoch FROM clock_timestamp() - v_ini) * 1000;
    INSERT INTO resultado_rendimiento
    VALUES ('Consulta por columna', v_n, round(v_ms, 2), v_bit, NULL);

    v_ini := clock_timestamp();
    SELECT count(*) INTO v_n FROM audit.bitacora WHERE clave_primaria = 'id=500';
    v_ms := extract(epoch FROM clock_timestamp() - v_ini) * 1000;
    INSERT INTO resultado_rendimiento
    VALUES ('Consulta por registro', v_n, round(v_ms, 2), v_bit, NULL);
END;
$$;

-- -----------------------------------------------------------------------------
-- Resultados.
-- -----------------------------------------------------------------------------
SELECT escenario,
       volumen,
       milisegundos AS ms,
       filas_bitacora,
       microseg_x_fila AS us_por_fila
  FROM resultado_rendimiento
 ORDER BY ctid;

-- Sobrecosto porcentual que el trigger agrega a la insercion.
SELECT c.volumen,
       s.milisegundos AS ms_sin_auditoria,
       c.milisegundos AS ms_con_auditoria,
       round(((c.milisegundos - s.milisegundos) / s.milisegundos) * 100, 1) AS sobrecosto_pct
  FROM resultado_rendimiento c
  JOIN resultado_rendimiento s
    ON s.volumen = c.volumen AND s.escenario = 'INSERT sin auditoria'
 WHERE c.escenario = 'INSERT con auditoria'
 ORDER BY c.volumen;
