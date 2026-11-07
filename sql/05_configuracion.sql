-- =============================================================================
-- AutoAudit - 05_configuracion.sql
-- Modulo de configuracion de auditoria.
--
-- Concentra en la base de datos la validacion y el control de acceso que el
-- enunciado exige. La interfaz grafica se limita a llamar a estas funciones,
-- de modo que una configuracion hecha desde psql pasa por los mismos
-- controles que una hecha desde la aplicacion. Validar unicamente en el
-- cliente no serviria, porque el cliente se puede modificar o evitar.
--
-- Las funciones son SECURITY INVOKER a proposito. Se ejecutan con los
-- privilegios de quien las llama, de manera que los permisos otorgados sobre
-- las tablas del esquema audit siguen vigentes y la restriccion no depende
-- solo de la comprobacion explicita que hacen al inicio.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- audit.fn_es_administrador
-- Es administrador quien sea superusuario o miembro del rol autoaudit_admin.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_es_administrador()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper)
        OR pg_has_role(current_user, 'autoaudit_admin', 'MEMBER');
$$;

COMMENT ON FUNCTION audit.fn_es_administrador() IS
  'Verdadero si el usuario actual es superusuario o miembro de autoaudit_admin.';

-- -----------------------------------------------------------------------------
-- audit.fn_exigir_administrador
-- Aborta la operacion si quien llama no tiene privilegios administrativos.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_exigir_administrador()
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT audit.fn_es_administrador() THEN
        RAISE EXCEPTION
            'AutoAudit: el usuario % no tiene privilegios para configurar auditoria', current_user
            USING ERRCODE = 'insufficient_privilege',
                  HINT = 'Solicite al administrador que lo agregue al rol autoaudit_admin.';
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- audit.fn_validar_objeto
-- Comprueba contra el diccionario de datos que la tabla exista, que tenga
-- llave primaria y que todas las columnas indicadas existan en ella.
--
-- Es la validacion que el enunciado pide hacer antes de activar la auditoria.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_validar_objeto(
    p_esquema  varchar(63),
    p_tabla    varchar(63),
    p_columnas text[]
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_tiene_pk  boolean;
    v_faltantes text;
BEGIN
    IF p_esquema IS NULL OR p_tabla IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: debe indicar esquema y tabla'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_esquema = 'audit' THEN
        RAISE EXCEPTION 'AutoAudit: no se puede auditar el propio esquema audit'
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'Auditar la bitacora con la bitacora produciria recursion infinita.';
    END IF;

    SELECT tiene_llave_primaria INTO v_tiene_pk
      FROM audit.v_diccionario_tablas
     WHERE esquema = p_esquema AND tabla = p_tabla;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no existe en el diccionario de datos',
            p_esquema, p_tabla USING ERRCODE = 'undefined_table';
    END IF;

    IF NOT v_tiene_pk THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no tiene llave primaria y no puede auditarse',
            p_esquema, p_tabla USING ERRCODE = 'invalid_table_definition',
            HINT = 'Sin llave primaria la bitacora no puede identificar el registro afectado.';
    END IF;

    IF p_columnas IS NULL OR cardinality(p_columnas) = 0 THEN
        RAISE EXCEPTION 'AutoAudit: debe indicar al menos una columna'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT string_agg(c, ', ' ORDER BY c) INTO v_faltantes
      FROM unnest(p_columnas) AS c
     WHERE NOT EXISTS (
            SELECT 1 FROM audit.v_diccionario_columnas dc
             WHERE dc.esquema = p_esquema
               AND dc.tabla   = p_tabla
               AND dc.columna = c
     );

    IF v_faltantes IS NOT NULL THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no tiene las columnas: %',
            p_esquema, p_tabla, v_faltantes USING ERRCODE = 'undefined_column';
    END IF;
END;
$$;

COMMENT ON FUNCTION audit.fn_validar_objeto(varchar, varchar, text[]) IS
  'Valida contra el diccionario de datos que la tabla y las columnas existan y que la tabla tenga llave primaria.';

-- -----------------------------------------------------------------------------
-- audit.fn_ids_eventos
-- Traduce codigos de evento a identificadores del catalogo y rechaza los que
-- no existan.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_ids_eventos(p_eventos text[])
RETURNS smallint[]
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ids        smallint[];
    v_invalidos  text;
BEGIN
    IF p_eventos IS NULL OR cardinality(p_eventos) = 0 THEN
        RAISE EXCEPTION 'AutoAudit: debe indicar al menos un evento'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT string_agg(e, ', ' ORDER BY e) INTO v_invalidos
      FROM unnest(p_eventos) AS e
     WHERE upper(e) NOT IN (SELECT codigo FROM audit.tipo_evento);

    IF v_invalidos IS NOT NULL THEN
        RAISE EXCEPTION 'AutoAudit: eventos no reconocidos: %', v_invalidos
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'Los eventos validos son INSERT, UPDATE y DELETE.';
    END IF;

    SELECT array_agg(DISTINCT te.id ORDER BY te.id) INTO v_ids
      FROM unnest(p_eventos) AS e
      JOIN audit.tipo_evento te ON te.codigo = upper(e);

    RETURN v_ids;
END;
$$;

-- -----------------------------------------------------------------------------
-- audit.configurar_auditoria
--
-- Punto de entrada unico para habilitar auditoria sobre una tabla. Valida,
-- persiste la configuracion y, salvo que se pida lo contrario, despliega el
-- trigger de inmediato.
--
-- El despliegue se comprueba antes de dar por buena la operacion. Como
-- audit.regenerar_todos() captura los errores por tabla y los devuelve como
-- texto en lugar de propagarlos, confiar en que no lanzo excepcion dejaria
-- pasar configuraciones cuyo trigger nunca se instalo.
--
-- Toda la operacion ocurre en una transaccion: si el despliegue falla, la
-- configuracion no queda persistida y la tabla no se envenena para futuros
-- despliegues.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.configurar_auditoria(
    p_esquema   varchar(63),
    p_tabla     varchar(63),
    p_columnas  text[],
    p_eventos   text[] DEFAULT ARRAY['INSERT','UPDATE','DELETE'],
    p_desplegar boolean DEFAULT true
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_tabla_id   integer;
    v_col_id     integer;
    v_ids        smallint[];
    v_col        text;
    v_evento     smallint;
    v_resultado  text;
    v_n_cfg      integer := 0;
BEGIN
    PERFORM audit.fn_exigir_administrador();
    PERFORM audit.fn_validar_objeto(p_esquema, p_tabla, p_columnas);
    v_ids := audit.fn_ids_eventos(p_eventos);

    INSERT INTO audit.tabla_auditada (esquema, tabla, activa)
    VALUES (p_esquema, p_tabla, true)
    ON CONFLICT (esquema, tabla) DO UPDATE SET activa = true
    RETURNING id INTO v_tabla_id;

    FOREACH v_col IN ARRAY p_columnas LOOP
        INSERT INTO audit.columna_auditada (tabla_auditada_id, columna, activa)
        VALUES (v_tabla_id, v_col, true)
        ON CONFLICT (tabla_auditada_id, columna) DO UPDATE SET activa = true
        RETURNING id INTO v_col_id;

        FOREACH v_evento IN ARRAY v_ids LOOP
            INSERT INTO audit.configuracion (columna_auditada_id, tipo_evento_id, activa)
            VALUES (v_col_id, v_evento, true)
            ON CONFLICT (columna_auditada_id, tipo_evento_id) DO UPDATE SET activa = true;
            v_n_cfg := v_n_cfg + 1;
        END LOOP;
    END LOOP;

    IF NOT p_desplegar THEN
        RETURN format('Configuracion guardada para %s.%s: %s configuraciones. Trigger no desplegado.',
                      p_esquema, p_tabla, v_n_cfg);
    END IF;

    SELECT resultado INTO v_resultado
      FROM audit.regenerar_todos()
     WHERE tabla_auditada_id = v_tabla_id;

    IF v_resultado IS NULL OR v_resultado LIKE 'error:%' THEN
        RAISE EXCEPTION 'AutoAudit: fallo el despliegue de %.%: %',
            p_esquema, p_tabla, coalesce(v_resultado, 'el generador no devolvio resultado')
            USING ERRCODE = 'triggered_action_exception';
    END IF;

    RETURN format('Auditoria activa sobre %s.%s: %s configuraciones, trigger desplegado.',
                  p_esquema, p_tabla, v_n_cfg);
END;
$$;

COMMENT ON FUNCTION audit.configurar_auditoria(varchar, varchar, text[], text[], boolean) IS
  'Valida, persiste y despliega la auditoria de una tabla. Revierte todo si el despliegue falla.';

-- -----------------------------------------------------------------------------
-- audit.desactivar_evento
--
-- Deja de registrar un evento concreto sobre una columna. Surte efecto de
-- inmediato, sin regenerar el trigger, porque audit.fn_registrar_cambio
-- consulta la bandera activa en cada llamada.
--
-- Se desactiva en lugar de eliminar para conservar la bitacora acumulada, que
-- referencia la configuracion mediante una llave foranea con RESTRICT.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.desactivar_evento(
    p_esquema varchar(63),
    p_tabla   varchar(63),
    p_columna varchar(63),
    p_evento  text
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_n integer;
BEGIN
    PERFORM audit.fn_exigir_administrador();

    UPDATE audit.configuracion cfg
       SET activa = false
      FROM audit.columna_auditada col
      JOIN audit.tabla_auditada   ta ON ta.id = col.tabla_auditada_id
      JOIN audit.tipo_evento      te ON te.codigo = upper(p_evento)
     WHERE cfg.columna_auditada_id = col.id
       AND cfg.tipo_evento_id = te.id
       AND ta.esquema = p_esquema AND ta.tabla = p_tabla
       AND col.columna = p_columna;

    GET DIAGNOSTICS v_n = ROW_COUNT;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'AutoAudit: no existe configuracion de % sobre %.%.%',
            upper(p_evento), p_esquema, p_tabla, p_columna
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN format('Evento %s desactivado sobre %s.%s.%s',
                  upper(p_evento), p_esquema, p_tabla, p_columna);
END;
$$;

-- -----------------------------------------------------------------------------
-- audit.activar_evento
-- Reanuda el registro. Tampoco requiere regenerar el trigger, siempre que la
-- configuracion ya existiera. Si nunca existio, hay que usar
-- audit.configurar_auditoria, que si regenera.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.activar_evento(
    p_esquema varchar(63),
    p_tabla   varchar(63),
    p_columna varchar(63),
    p_evento  text
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_n integer;
BEGIN
    PERFORM audit.fn_exigir_administrador();

    UPDATE audit.configuracion cfg
       SET activa = true
      FROM audit.columna_auditada col
      JOIN audit.tabla_auditada   ta ON ta.id = col.tabla_auditada_id
      JOIN audit.tipo_evento      te ON te.codigo = upper(p_evento)
     WHERE cfg.columna_auditada_id = col.id
       AND cfg.tipo_evento_id = te.id
       AND ta.esquema = p_esquema AND ta.tabla = p_tabla
       AND col.columna = p_columna;

    GET DIAGNOSTICS v_n = ROW_COUNT;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'AutoAudit: no existe configuracion de % sobre %.%.%',
            upper(p_evento), p_esquema, p_tabla, p_columna
            USING ERRCODE = 'no_data_found',
                  HINT = 'Use audit.configurar_auditoria para crearla.';
    END IF;

    RETURN format('Evento %s activado sobre %s.%s.%s',
                  upper(p_evento), p_esquema, p_tabla, p_columna);
END;
$$;

-- -----------------------------------------------------------------------------
-- audit.desactivar_columna
-- Deja de vigilar una columna entera. Requiere regenerar porque la lista de
-- columnas va empotrada en el codigo del trigger.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.desactivar_columna(
    p_esquema varchar(63),
    p_tabla   varchar(63),
    p_columna varchar(63)
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_tabla_id  integer;
    v_n         integer;
    v_resultado text;
BEGIN
    PERFORM audit.fn_exigir_administrador();

    SELECT ta.id INTO v_tabla_id
      FROM audit.tabla_auditada ta
     WHERE ta.esquema = p_esquema AND ta.tabla = p_tabla;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no esta habilitada para auditoria',
            p_esquema, p_tabla USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE audit.columna_auditada
       SET activa = false
     WHERE tabla_auditada_id = v_tabla_id AND columna = p_columna;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'AutoAudit: la columna %.%.% no esta configurada',
            p_esquema, p_tabla, p_columna USING ERRCODE = 'no_data_found';
    END IF;

    -- Si quedan columnas activas se regenera; si no, se retira el trigger.
    IF EXISTS (SELECT 1 FROM audit.columna_auditada
                WHERE tabla_auditada_id = v_tabla_id AND activa) THEN
        SELECT resultado INTO v_resultado
          FROM audit.regenerar_todos() WHERE tabla_auditada_id = v_tabla_id;

        IF v_resultado IS NULL OR v_resultado LIKE 'error:%' THEN
            RAISE EXCEPTION 'AutoAudit: fallo la regeneracion de %.%: %',
                p_esquema, p_tabla, coalesce(v_resultado, 'sin resultado')
                USING ERRCODE = 'triggered_action_exception';
        END IF;
        RETURN format('Columna %s desactivada y trigger regenerado sobre %s.%s',
                      p_columna, p_esquema, p_tabla);
    END IF;

    PERFORM audit.eliminar_trigger(v_tabla_id);
    RETURN format('Columna %s desactivada. Era la ultima, el trigger de %s.%s fue retirado.',
                  p_columna, p_esquema, p_tabla);
END;
$$;

-- -----------------------------------------------------------------------------
-- audit.desactivar_tabla
-- Suspende la auditoria de una tabla y retira su trigger. La configuracion y
-- la bitacora se conservan intactas.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.desactivar_tabla(
    p_esquema varchar(63),
    p_tabla   varchar(63)
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_tabla_id integer;
BEGIN
    PERFORM audit.fn_exigir_administrador();

    UPDATE audit.tabla_auditada
       SET activa = false
     WHERE esquema = p_esquema AND tabla = p_tabla
    RETURNING id INTO v_tabla_id;

    IF v_tabla_id IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no esta habilitada para auditoria',
            p_esquema, p_tabla USING ERRCODE = 'no_data_found';
    END IF;

    PERFORM audit.eliminar_trigger(v_tabla_id);

    RETURN format('Auditoria suspendida sobre %s.%s. La configuracion y la bitacora se conservan.',
                  p_esquema, p_tabla);
END;
$$;

-- -----------------------------------------------------------------------------
-- audit.activar_tabla
-- Reanuda la auditoria de una tabla suspendida y vuelve a desplegar su trigger.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.activar_tabla(
    p_esquema varchar(63),
    p_tabla   varchar(63)
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_tabla_id  integer;
    v_resultado text;
BEGIN
    PERFORM audit.fn_exigir_administrador();

    UPDATE audit.tabla_auditada
       SET activa = true
     WHERE esquema = p_esquema AND tabla = p_tabla
    RETURNING id INTO v_tabla_id;

    IF v_tabla_id IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no esta registrada',
            p_esquema, p_tabla USING ERRCODE = 'no_data_found';
    END IF;

    SELECT resultado INTO v_resultado
      FROM audit.regenerar_todos() WHERE tabla_auditada_id = v_tabla_id;

    IF v_resultado IS NULL OR v_resultado LIKE 'error:%' THEN
        RAISE EXCEPTION 'AutoAudit: fallo el despliegue de %.%: %',
            p_esquema, p_tabla, coalesce(v_resultado, 'sin resultado')
            USING ERRCODE = 'triggered_action_exception';
    END IF;

    RETURN format('Auditoria reanudada sobre %s.%s', p_esquema, p_tabla);
END;
$$;

-- -----------------------------------------------------------------------------
-- Privilegios. Las funciones quedan disponibles para consulta, pero cada una
-- exige privilegios administrativos al ejecutarse.
-- -----------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION audit.fn_es_administrador() TO PUBLIC;
