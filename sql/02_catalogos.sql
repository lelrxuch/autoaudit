-- =============================================================================
-- AutoAudit - 02_catalogos.sql
-- Carga del catalogo de eventos y funciones de resolucion de usuario y estacion.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Catalogo de operaciones auditables.
-- -----------------------------------------------------------------------------
INSERT INTO audit.tipo_evento (id, codigo, descripcion) VALUES
    (1, 'INSERT', 'Alta de un registro nuevo'),
    (2, 'UPDATE', 'Modificacion de un registro existente'),
    (3, 'DELETE', 'Eliminacion de un registro')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- audit.fn_resolver_usuario
--
-- Devuelve el identificador del usuario indicado y lo da de alta la primera vez
-- que aparece. Actualiza la marca de ultima actividad en cada llamada.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_resolver_usuario(p_usuario varchar(63))
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = audit, pg_temp
AS $$
DECLARE
    v_id integer;
BEGIN
    INSERT INTO audit.usuario_auditado (nombre_usuario)
    VALUES (p_usuario)
    ON CONFLICT (nombre_usuario) DO UPDATE
        SET ultima_actividad = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION audit.fn_resolver_usuario(varchar) IS
  'Devuelve el id del usuario auditado, dandolo de alta si es la primera vez que aparece.';

-- -----------------------------------------------------------------------------
-- audit.fn_resolver_estacion
--
-- Equivalente al anterior para la estacion de trabajo. Las conexiones por
-- socket local no reportan direccion de red y se agrupan en una sola fila.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_resolver_estacion(p_ip inet)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = audit, pg_temp
AS $$
DECLARE
    v_id integer;
BEGIN
    IF p_ip IS NULL THEN
        SELECT id INTO v_id
        FROM audit.estacion_trabajo
        WHERE direccion_ip IS NULL;

        IF v_id IS NULL THEN
            INSERT INTO audit.estacion_trabajo (direccion_ip, nombre_host)
            VALUES (NULL, 'conexion local')
            RETURNING id INTO v_id;
        ELSE
            UPDATE audit.estacion_trabajo
               SET ultima_actividad = now()
             WHERE id = v_id;
        END IF;

        RETURN v_id;
    END IF;

    INSERT INTO audit.estacion_trabajo (direccion_ip, nombre_host)
    VALUES (p_ip, host(p_ip))
    ON CONFLICT (direccion_ip) DO UPDATE
        SET ultima_actividad = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION audit.fn_resolver_estacion(inet) IS
  'Devuelve el id de la estacion de trabajo, dandola de alta si es la primera vez que aparece.';

-- -----------------------------------------------------------------------------
-- audit.fn_contexto
--
-- Resuelve el usuario y la estacion de la sesion actual una sola vez y guarda
-- los identificadores en variables de configuracion de sesion.
--
-- Sin esta memoria intermedia, cada columna modificada obligaria a ejecutar un
-- INSERT ... ON CONFLICT DO UPDATE sobre usuario_auditado y otro sobre
-- estacion_trabajo. En una carga masiva eso genera cientos de miles de tuplas
-- muertas sobre tablas de una sola fila y degrada el rendimiento de forma
-- severa. Resolviendo una vez por sesion, el costo se vuelve despreciable.
--
-- Las variables de sesion son transaccionales: si la transaccion se revierte,
-- el valor en memoria se descarta junto con el alta del usuario, de modo que
-- la memoria intermedia nunca queda apuntando a una fila inexistente.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_contexto(
    OUT p_usuario_id  integer,
    OUT p_estacion_id integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = audit, pg_temp
AS $$
DECLARE
    v_usuario  text := current_setting('autoaudit.usuario_id',  true);
    v_estacion text := current_setting('autoaudit.estacion_id', true);
BEGIN
    IF v_usuario IS NULL OR v_usuario = '' THEN
        p_usuario_id := audit.fn_resolver_usuario(session_user::varchar(63));
        PERFORM set_config('autoaudit.usuario_id', p_usuario_id::text, false);
    ELSE
        p_usuario_id := v_usuario::integer;
    END IF;

    IF v_estacion IS NULL OR v_estacion = '' THEN
        p_estacion_id := audit.fn_resolver_estacion(inet_client_addr());
        PERFORM set_config('autoaudit.estacion_id', p_estacion_id::text, false);
    ELSE
        p_estacion_id := v_estacion::integer;
    END IF;
END;
$$;

COMMENT ON FUNCTION audit.fn_contexto() IS
  'Devuelve el usuario y la estacion de la sesion, resolviendolos una sola vez por sesion.';

-- -----------------------------------------------------------------------------
-- audit.fn_registrar_cambio
--
-- Punto unico de escritura en la bitacora. Las funciones de trigger generadas
-- llaman aqui en lugar de insertar directamente, de modo que la validacion de
-- la configuracion vigente ocurre en un solo lugar.
--
-- Devuelve verdadero si el cambio quedo registrado y falso si la configuracion
-- estaba desactivada en el momento del cambio.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_registrar_cambio(
    p_configuracion_id  integer,
    p_clave_primaria    text,
    p_valor_anterior    text,
    p_valor_nuevo       text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = audit, pg_temp
AS $$
DECLARE
    v_usuario_id  integer;
    v_estacion_id integer;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM audit.configuracion
        WHERE id = p_configuracion_id AND activa
    ) THEN
        RETURN false;
    END IF;

    SELECT c.p_usuario_id, c.p_estacion_id
      INTO v_usuario_id, v_estacion_id
      FROM audit.fn_contexto() c;

    INSERT INTO audit.bitacora (
        configuracion_id, usuario_id, estacion_id,
        clave_primaria, valor_anterior, valor_nuevo
    ) VALUES (
        p_configuracion_id, v_usuario_id, v_estacion_id,
        p_clave_primaria, p_valor_anterior, p_valor_nuevo
    );

    RETURN true;
END;
$$;

COMMENT ON FUNCTION audit.fn_registrar_cambio(integer, text, text, text) IS
  'Punto unico de escritura en la bitacora. Valida que la configuracion siga activa antes de registrar.';

REVOKE ALL ON FUNCTION audit.fn_registrar_cambio(integer, text, text, text) FROM PUBLIC;
