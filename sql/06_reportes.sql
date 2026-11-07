-- =============================================================================
-- AutoAudit - 06_reportes.sql
-- Modulo de consulta y reporte.
--
-- Contiene la vista de detalle de la bitacora y las consultas parametrizadas
-- de historial que exige el enunciado: por usuario, por columna y en orden
-- cronologico, con acotacion por rango de fechas.
--
-- Todas filtran por identificador y no por nombre. La bitacora tiene indice
-- sobre usuario_id y sobre configuracion_id, de modo que filtrar por el
-- identificador descarta filas antes de resolver las uniones. Filtrar por el
-- nombre del usuario o de la columna obliga a unir primero y recorrer mucho
-- mas. Las funciones por nombre que aparecen al final resuelven el nombre a
-- identificador en un paso aparte y luego delegan, para conservar esa ventaja.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- audit.v_bitacora_detalle
-- La bitacora con los nombres resueltos. Es la base de los tres reportes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW audit.v_bitacora_detalle AS
SELECT
    b.id,
    b.fecha_hora,
    u.nombre_usuario,
    e.direccion_ip,
    e.nombre_host,
    ta.esquema,
    ta.tabla,
    ta.esquema || '.' || ta.tabla AS objeto,
    col.columna,
    te.codigo                     AS evento,
    b.clave_primaria,
    b.valor_anterior,
    b.valor_nuevo,
    b.id_transaccion,
    b.usuario_id,
    col.id                        AS columna_auditada_id,
    b.configuracion_id
FROM audit.bitacora b
JOIN audit.configuracion    cfg ON cfg.id = b.configuracion_id
JOIN audit.columna_auditada col ON col.id = cfg.columna_auditada_id
JOIN audit.tabla_auditada   ta  ON ta.id  = col.tabla_auditada_id
JOIN audit.tipo_evento      te  ON te.id  = cfg.tipo_evento_id
JOIN audit.usuario_auditado u   ON u.id   = b.usuario_id
JOIN audit.estacion_trabajo e   ON e.id   = b.estacion_id;

COMMENT ON VIEW audit.v_bitacora_detalle IS
  'Bitacora con tabla, columna, evento, usuario y estacion ya resueltos.';

GRANT SELECT ON audit.v_bitacora_detalle TO PUBLIC;

-- -----------------------------------------------------------------------------
-- Tipo de retorno comun a las consultas de historial.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS audit.consultar_historial(integer, integer, varchar, varchar, timestamptz, timestamptz, integer);
DROP FUNCTION IF EXISTS audit.consultar_por_usuario(varchar, timestamptz, timestamptz, integer);
DROP FUNCTION IF EXISTS audit.consultar_por_columna(varchar, varchar, varchar, timestamptz, timestamptz, integer);
DROP FUNCTION IF EXISTS audit.consultar_por_registro(varchar, varchar, text, integer);

-- -----------------------------------------------------------------------------
-- audit.consultar_historial
--
-- Consulta parametrizada general. Todos los parametros son opcionales y se
-- combinan con Y logico; omitirlos todos devuelve la bitacora completa en
-- orden cronologico descendente.
-- -----------------------------------------------------------------------------
CREATE FUNCTION audit.consultar_historial(
    p_usuario_id          integer     DEFAULT NULL,
    p_columna_auditada_id integer     DEFAULT NULL,
    p_esquema             varchar(63) DEFAULT NULL,
    p_tabla               varchar(63) DEFAULT NULL,
    p_desde               timestamptz DEFAULT NULL,
    p_hasta               timestamptz DEFAULT NULL,
    p_limite              integer     DEFAULT 1000
)
RETURNS TABLE (
    fecha_hora      timestamptz,
    nombre_usuario  varchar(63),
    direccion_ip    inet,
    objeto          text,
    columna         varchar(63),
    evento          varchar(10),
    clave_primaria  text,
    valor_anterior  text,
    valor_nuevo     text
)
LANGUAGE sql
STABLE
AS $$
    SELECT d.fecha_hora, d.nombre_usuario, d.direccion_ip, d.objeto,
           d.columna, d.evento, d.clave_primaria, d.valor_anterior, d.valor_nuevo
      FROM audit.v_bitacora_detalle d
     WHERE (p_usuario_id          IS NULL OR d.usuario_id          = p_usuario_id)
       AND (p_columna_auditada_id IS NULL OR d.columna_auditada_id = p_columna_auditada_id)
       AND (p_esquema             IS NULL OR d.esquema             = p_esquema)
       AND (p_tabla               IS NULL OR d.tabla               = p_tabla)
       AND (p_desde               IS NULL OR d.fecha_hora         >= p_desde)
       AND (p_hasta               IS NULL OR d.fecha_hora         <= p_hasta)
     ORDER BY d.fecha_hora DESC, d.id DESC
     LIMIT coalesce(p_limite, 1000);
$$;

COMMENT ON FUNCTION audit.consultar_historial(integer, integer, varchar, varchar, timestamptz, timestamptz, integer) IS
  'Consulta parametrizada de historial. Todos los filtros son opcionales y se combinan con Y logico.';

-- -----------------------------------------------------------------------------
-- audit.consultar_por_usuario
-- Historial completo de las modificaciones hechas por un usuario.
-- -----------------------------------------------------------------------------
CREATE FUNCTION audit.consultar_por_usuario(
    p_nombre_usuario varchar(63),
    p_desde          timestamptz DEFAULT NULL,
    p_hasta          timestamptz DEFAULT NULL,
    p_limite         integer     DEFAULT 1000
)
RETURNS TABLE (
    fecha_hora      timestamptz,
    nombre_usuario  varchar(63),
    direccion_ip    inet,
    objeto          text,
    columna         varchar(63),
    evento          varchar(10),
    clave_primaria  text,
    valor_anterior  text,
    valor_nuevo     text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_id integer;
BEGIN
    SELECT u.id INTO v_id
      FROM audit.usuario_auditado u
     WHERE u.nombre_usuario = p_nombre_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'AutoAudit: el usuario % no tiene actividad registrada', p_nombre_usuario
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN QUERY
        SELECT * FROM audit.consultar_historial(
            p_usuario_id => v_id, p_desde => p_desde,
            p_hasta => p_hasta, p_limite => p_limite);
END;
$$;

-- -----------------------------------------------------------------------------
-- audit.consultar_por_columna
-- Todos los cambios registrados sobre una columna concreta.
-- -----------------------------------------------------------------------------
CREATE FUNCTION audit.consultar_por_columna(
    p_esquema varchar(63),
    p_tabla   varchar(63),
    p_columna varchar(63),
    p_desde   timestamptz DEFAULT NULL,
    p_hasta   timestamptz DEFAULT NULL,
    p_limite  integer     DEFAULT 1000
)
RETURNS TABLE (
    fecha_hora      timestamptz,
    nombre_usuario  varchar(63),
    direccion_ip    inet,
    objeto          text,
    columna         varchar(63),
    evento          varchar(10),
    clave_primaria  text,
    valor_anterior  text,
    valor_nuevo     text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_id integer;
BEGIN
    SELECT col.id INTO v_id
      FROM audit.columna_auditada col
      JOIN audit.tabla_auditada ta ON ta.id = col.tabla_auditada_id
     WHERE ta.esquema = p_esquema AND ta.tabla = p_tabla AND col.columna = p_columna;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'AutoAudit: la columna %.%.% no esta configurada para auditoria',
            p_esquema, p_tabla, p_columna USING ERRCODE = 'no_data_found';
    END IF;

    RETURN QUERY
        SELECT * FROM audit.consultar_historial(
            p_columna_auditada_id => v_id, p_desde => p_desde,
            p_hasta => p_hasta, p_limite => p_limite);
END;
$$;

-- -----------------------------------------------------------------------------
-- audit.consultar_por_registro
--
-- Historia completa de un registro concreto, aunque ya haya sido eliminado de
-- la tabla origen. Es la consulta que demuestra que la bitacora preserva los
-- datos tras un borrado.
--
-- La clave se arma igual que en el trigger: pares columna=valor separados por
-- barra vertical cuando la llave es compuesta.
-- -----------------------------------------------------------------------------
CREATE FUNCTION audit.consultar_por_registro(
    p_esquema        varchar(63),
    p_tabla          varchar(63),
    p_clave_primaria text,
    p_limite         integer DEFAULT 1000
)
RETURNS TABLE (
    fecha_hora      timestamptz,
    nombre_usuario  varchar(63),
    direccion_ip    inet,
    objeto          text,
    columna         varchar(63),
    evento          varchar(10),
    clave_primaria  text,
    valor_anterior  text,
    valor_nuevo     text
)
LANGUAGE sql
STABLE
AS $$
    SELECT d.fecha_hora, d.nombre_usuario, d.direccion_ip, d.objeto,
           d.columna, d.evento, d.clave_primaria, d.valor_anterior, d.valor_nuevo
      FROM audit.v_bitacora_detalle d
     WHERE d.esquema = p_esquema
       AND d.tabla   = p_tabla
       AND d.clave_primaria = p_clave_primaria
     ORDER BY d.fecha_hora ASC, d.id ASC
     LIMIT coalesce(p_limite, 1000);
$$;

COMMENT ON FUNCTION audit.consultar_por_registro(varchar, varchar, text, integer) IS
  'Historia completa de un registro en orden cronologico ascendente, aunque ya no exista en la tabla origen.';

-- -----------------------------------------------------------------------------
-- audit.resumen_actividad
-- Agregado por usuario y objeto. Util como portada de un informe.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW audit.v_resumen_actividad AS
SELECT
    nombre_usuario,
    objeto,
    evento,
    count(*)        AS cambios,
    min(fecha_hora) AS primer_cambio,
    max(fecha_hora) AS ultimo_cambio
FROM audit.v_bitacora_detalle
GROUP BY nombre_usuario, objeto, evento;

COMMENT ON VIEW audit.v_resumen_actividad IS
  'Cantidad de cambios por usuario, objeto y tipo de evento, con primera y ultima fecha.';

GRANT SELECT ON audit.v_resumen_actividad TO PUBLIC;
GRANT EXECUTE ON FUNCTION audit.consultar_historial(integer, integer, varchar, varchar, timestamptz, timestamptz, integer) TO PUBLIC;
GRANT EXECUTE ON FUNCTION audit.consultar_por_usuario(varchar, timestamptz, timestamptz, integer) TO PUBLIC;
GRANT EXECUTE ON FUNCTION audit.consultar_por_columna(varchar, varchar, varchar, timestamptz, timestamptz, integer) TO PUBLIC;
GRANT EXECUTE ON FUNCTION audit.consultar_por_registro(varchar, varchar, text, integer) TO PUBLIC;
