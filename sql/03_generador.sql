-- =============================================================================
-- AutoAudit - 03_generador.sql
-- Modulo de generacion dinamica de triggers.
--
-- Lee la configuracion vigente y construye, para cada tabla habilitada, una
-- funcion de trigger a la medida mas el trigger AFTER que la invoca. El codigo
-- generado lleva empotrada la lista de columnas vigiladas, de modo que en
-- tiempo de ejecucion no hay consultas a las tablas de configuracion y el
-- costo por fila se mantiene bajo.
--
-- Un cambio estructural de la configuracion (agregar o quitar columnas o
-- eventos) exige regenerar el trigger. En cambio, desactivar una configuracion
-- surte efecto de inmediato sin regenerar, porque audit.fn_registrar_cambio
-- revisa la bandera "activa" en cada llamada.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- audit.fn_columnas_llave_primaria
-- Devuelve las columnas que forman la llave primaria de una tabla, en orden.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_columnas_llave_primaria(
    p_esquema varchar(63),
    p_tabla   varchar(63)
)
RETURNS text[]
LANGUAGE sql
STABLE
AS $$
    SELECT array_agg(a.attname::text ORDER BY k.ord)
    FROM pg_constraint c
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'p'
      AND c.conrelid = format('%I.%I', p_esquema, p_tabla)::regclass;
$$;

COMMENT ON FUNCTION audit.fn_columnas_llave_primaria(varchar, varchar) IS
  'Columnas que forman la llave primaria de una tabla, consultadas en el diccionario de datos.';

-- -----------------------------------------------------------------------------
-- audit.fn_nombre_objeto
-- Construye nombres de funcion y trigger que no exceden el limite de 63
-- caracteres de PostgreSQL y que son unicos por tabla auditada.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_nombre_objeto(
    p_prefijo varchar(20),
    p_id      integer,
    p_tabla   varchar(63)
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_prefijo || p_id::text || '_' || left(regexp_replace(p_tabla, '[^a-zA-Z0-9_]', '_', 'g'), 30);
$$;

-- -----------------------------------------------------------------------------
-- audit.generar_trigger
--
-- Construye y devuelve el codigo SQL del trigger de una tabla auditada, sin
-- ejecutarlo. Separar la generacion de la aplicacion permite revisar el codigo
-- antes de desplegarlo y facilita documentarlo.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.generar_trigger(p_tabla_auditada_id integer)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $gen$
DECLARE
    v_esquema       varchar(63);
    v_tabla         varchar(63);
    v_pk            text[];
    v_col           text;
    v_nombre_fn     text;
    v_nombre_tg     text;
    v_pk_new        text := '';
    v_pk_old        text := '';
    v_bloque_ins    text := '';
    v_bloque_upd    text := '';
    v_bloque_del    text := '';
    v_faltantes     text;
    v_sql           text;
    r               record;
BEGIN
    SELECT esquema, tabla
      INTO v_esquema, v_tabla
      FROM audit.tabla_auditada
     WHERE id = p_tabla_auditada_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'AutoAudit: no existe tabla auditada con id %', p_tabla_auditada_id
            USING ERRCODE = 'no_data_found';
    END IF;

    -- Validacion 1: la tabla origen debe existir en el diccionario de datos.
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = v_esquema
           AND table_name   = v_tabla
           AND table_type   = 'BASE TABLE'
    ) THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no existe o no es una tabla base',
            v_esquema, v_tabla USING ERRCODE = 'undefined_table';
    END IF;

    -- Validacion 2: toda columna configurada debe existir en la tabla origen.
    SELECT string_agg(DISTINCT col.columna, ', ')
      INTO v_faltantes
      FROM audit.columna_auditada col
     WHERE col.tabla_auditada_id = p_tabla_auditada_id
       AND col.activa
       AND NOT EXISTS (
            SELECT 1 FROM information_schema.columns ic
             WHERE ic.table_schema = v_esquema
               AND ic.table_name   = v_tabla
               AND ic.column_name  = col.columna
       );

    IF v_faltantes IS NOT NULL THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no tiene las columnas configuradas: %',
            v_esquema, v_tabla, v_faltantes USING ERRCODE = 'undefined_column';
    END IF;

    -- Validacion 3: sin llave primaria no se puede identificar el registro
    -- afectado en la bitacora.
    v_pk := audit.fn_columnas_llave_primaria(v_esquema, v_tabla);
    IF v_pk IS NULL OR cardinality(v_pk) = 0 THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% carece de llave primaria y no puede auditarse',
            v_esquema, v_tabla USING ERRCODE = 'invalid_table_definition';
    END IF;

    v_nombre_fn := audit.fn_nombre_objeto('tg_fn_', p_tabla_auditada_id, v_tabla);
    v_nombre_tg := audit.fn_nombre_objeto('tg_autoaudit_', p_tabla_auditada_id, v_tabla);

    -- Expresion que arma el identificador del registro afectado. Con llave
    -- compuesta se concatenan los pares columna=valor separados por barra.
    FOREACH v_col IN ARRAY v_pk LOOP
        IF v_pk_new <> '' THEN
            v_pk_new := v_pk_new || ' || ''|'' || ';
            v_pk_old := v_pk_old || ' || ''|'' || ';
        END IF;
        v_pk_new := v_pk_new || quote_literal(v_col || '=') || ' || NEW.' || quote_ident(v_col) || '::text';
        v_pk_old := v_pk_old || quote_literal(v_col || '=') || ' || OLD.' || quote_ident(v_col) || '::text';
    END LOOP;

    -- Bloque INSERT: registra el valor inicial de cada columna vigilada.
    FOR r IN
        SELECT cfg.id AS config_id, col.columna
          FROM audit.configuracion cfg
          JOIN audit.columna_auditada col ON col.id = cfg.columna_auditada_id
         WHERE col.tabla_auditada_id = p_tabla_auditada_id
           AND cfg.activa AND col.activa
           AND cfg.tipo_evento_id = 1
         ORDER BY col.columna
    LOOP
        v_bloque_ins := v_bloque_ins || format(
            E'        PERFORM audit.fn_registrar_cambio(%s, v_pk, NULL, NEW.%I::text);\n',
            r.config_id, r.columna);
    END LOOP;

    -- Bloque UPDATE: registra solo las columnas que de verdad cambiaron de
    -- valor. IS DISTINCT FROM trata los nulos como un valor mas y evita
    -- registros espurios cuando una columna pasa de nulo a nulo.
    FOR r IN
        SELECT cfg.id AS config_id, col.columna
          FROM audit.configuracion cfg
          JOIN audit.columna_auditada col ON col.id = cfg.columna_auditada_id
         WHERE col.tabla_auditada_id = p_tabla_auditada_id
           AND cfg.activa AND col.activa
           AND cfg.tipo_evento_id = 2
         ORDER BY col.columna
    LOOP
        v_bloque_upd := v_bloque_upd || format(
            E'        IF NEW.%I IS DISTINCT FROM OLD.%I THEN\n            PERFORM audit.fn_registrar_cambio(%s, v_pk, OLD.%I::text, NEW.%I::text);\n        END IF;\n',
            r.columna, r.columna, r.config_id, r.columna, r.columna);
    END LOOP;

    -- Bloque DELETE: conserva el ultimo valor conocido de cada columna.
    FOR r IN
        SELECT cfg.id AS config_id, col.columna
          FROM audit.configuracion cfg
          JOIN audit.columna_auditada col ON col.id = cfg.columna_auditada_id
         WHERE col.tabla_auditada_id = p_tabla_auditada_id
           AND cfg.activa AND col.activa
           AND cfg.tipo_evento_id = 3
         ORDER BY col.columna
    LOOP
        v_bloque_del := v_bloque_del || format(
            E'        PERFORM audit.fn_registrar_cambio(%s, v_pk, OLD.%I::text, NULL);\n',
            r.config_id, r.columna);
    END LOOP;

    IF v_bloque_ins = '' AND v_bloque_upd = '' AND v_bloque_del = '' THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no tiene ninguna configuracion activa',
            v_esquema, v_tabla USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Ensamblado de la funcion de trigger.
    v_sql := format(
        E'CREATE OR REPLACE FUNCTION audit.%I()\nRETURNS trigger\nLANGUAGE plpgsql\nSECURITY DEFINER\nSET search_path = audit, pg_temp\nAS $cuerpo$\nDECLARE\n    v_pk text;\nBEGIN\n',
        v_nombre_fn);

    IF v_bloque_ins <> '' THEN
        v_sql := v_sql
            || E'    IF TG_OP = ''INSERT'' THEN\n'
            || format(E'        v_pk := %s;\n', v_pk_new)
            || v_bloque_ins;
    ELSE
        v_sql := v_sql || E'    IF TG_OP = ''INSERT'' THEN\n        NULL;\n';
    END IF;

    IF v_bloque_upd <> '' THEN
        v_sql := v_sql
            || E'    ELSIF TG_OP = ''UPDATE'' THEN\n'
            || format(E'        v_pk := %s;\n', v_pk_new)
            || v_bloque_upd;
    ELSE
        v_sql := v_sql || E'    ELSIF TG_OP = ''UPDATE'' THEN\n        NULL;\n';
    END IF;

    IF v_bloque_del <> '' THEN
        v_sql := v_sql
            || E'    ELSIF TG_OP = ''DELETE'' THEN\n'
            || format(E'        v_pk := %s;\n', v_pk_old)
            || v_bloque_del;
    ELSE
        v_sql := v_sql || E'    ELSIF TG_OP = ''DELETE'' THEN\n        NULL;\n';
    END IF;

    -- En un trigger AFTER FOR EACH ROW el valor de retorno se ignora.
    v_sql := v_sql
        || E'    END IF;\n'
        || E'    RETURN NULL;\n'
        || E'END;\n'
        || E'$cuerpo$;\n\n';

    -- Ensamblado del trigger. Se recrea siempre para que la definicion refleje
    -- exactamente la configuracion vigente.
    v_sql := v_sql || format(
        E'DROP TRIGGER IF EXISTS %I ON %I.%I;\nCREATE TRIGGER %I\n    AFTER INSERT OR UPDATE OR DELETE ON %I.%I\n    FOR EACH ROW EXECUTE FUNCTION audit.%I();\n',
        v_nombre_tg, v_esquema, v_tabla,
        v_nombre_tg, v_esquema, v_tabla, v_nombre_fn);

    RETURN v_sql;
END;
$gen$;

COMMENT ON FUNCTION audit.generar_trigger(integer) IS
  'Devuelve el codigo SQL del trigger de una tabla auditada, sin ejecutarlo.';

-- -----------------------------------------------------------------------------
-- Sobrecarga por nombre de esquema y tabla, para uso desde el modulo de
-- configuracion y desde la interfaz.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.generar_trigger(
    p_esquema varchar(63),
    p_tabla   varchar(63)
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_id integer;
BEGIN
    SELECT id INTO v_id
      FROM audit.tabla_auditada
     WHERE esquema = p_esquema AND tabla = p_tabla;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no esta habilitada para auditoria',
            p_esquema, p_tabla USING ERRCODE = 'no_data_found';
    END IF;

    RETURN audit.generar_trigger(v_id);
END;
$$;

-- -----------------------------------------------------------------------------
-- audit.aplicar_trigger
-- Genera el codigo y lo ejecuta. Deja constancia del despliegue en la tabla
-- de configuracion.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.aplicar_trigger(p_tabla_auditada_id integer)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql     text;
    v_esquema varchar(63);
    v_tabla   varchar(63);
BEGIN
    SELECT esquema, tabla INTO v_esquema, v_tabla
      FROM audit.tabla_auditada WHERE id = p_tabla_auditada_id;

    v_sql := audit.generar_trigger(p_tabla_auditada_id);

    BEGIN
        EXECUTE v_sql;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'AutoAudit: fallo al desplegar el trigger de %.%: %',
            v_esquema, v_tabla, SQLERRM;
    END;

    UPDATE audit.tabla_auditada
       SET trigger_desplegado = true
     WHERE id = p_tabla_auditada_id;

    RETURN format('Trigger desplegado sobre %s.%s', v_esquema, v_tabla);
END;
$$;

COMMENT ON FUNCTION audit.aplicar_trigger(integer) IS
  'Genera y ejecuta el trigger de una tabla auditada.';

-- -----------------------------------------------------------------------------
-- audit.eliminar_trigger
-- Retira el trigger y su funcion. La bitacora acumulada no se toca.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.eliminar_trigger(p_tabla_auditada_id integer)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_esquema   varchar(63);
    v_tabla     varchar(63);
    v_nombre_fn text;
    v_nombre_tg text;
BEGIN
    SELECT esquema, tabla INTO v_esquema, v_tabla
      FROM audit.tabla_auditada WHERE id = p_tabla_auditada_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'AutoAudit: no existe tabla auditada con id %', p_tabla_auditada_id;
    END IF;

    v_nombre_fn := audit.fn_nombre_objeto('tg_fn_', p_tabla_auditada_id, v_tabla);
    v_nombre_tg := audit.fn_nombre_objeto('tg_autoaudit_', p_tabla_auditada_id, v_tabla);

    IF EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = v_esquema AND table_name = v_tabla
    ) THEN
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I',
                       v_nombre_tg, v_esquema, v_tabla);
    END IF;

    EXECUTE format('DROP FUNCTION IF EXISTS audit.%I()', v_nombre_fn);

    UPDATE audit.tabla_auditada
       SET trigger_desplegado = false
     WHERE id = p_tabla_auditada_id;

    RETURN format('Trigger retirado de %s.%s', v_esquema, v_tabla);
END;
$$;

-- -----------------------------------------------------------------------------
-- audit.regenerar_todos
-- Recorre las tablas activas y vuelve a desplegar sus triggers. Es el
-- procedimiento a ejecutar despues de cualquier cambio estructural de la
-- configuracion. Un fallo en una tabla no detiene el resto.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.regenerar_todos()
RETURNS TABLE (tabla_auditada_id integer, objeto text, resultado text)
LANGUAGE plpgsql
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT id, esquema, tabla
          FROM audit.tabla_auditada
         WHERE activa
         ORDER BY id
    LOOP
        tabla_auditada_id := r.id;
        objeto := r.esquema || '.' || r.tabla;
        BEGIN
            PERFORM audit.aplicar_trigger(r.id);
            resultado := 'desplegado';
        EXCEPTION WHEN OTHERS THEN
            resultado := 'error: ' || SQLERRM;
        END;
        RETURN NEXT;
    END LOOP;

    -- Las tablas desactivadas pierden su trigger pero conservan configuracion.
    FOR r IN
        SELECT id, esquema, tabla
          FROM audit.tabla_auditada
         WHERE NOT activa AND trigger_desplegado
         ORDER BY id
    LOOP
        tabla_auditada_id := r.id;
        objeto := r.esquema || '.' || r.tabla;
        BEGIN
            PERFORM audit.eliminar_trigger(r.id);
            resultado := 'retirado';
        EXCEPTION WHEN OTHERS THEN
            resultado := 'error: ' || SQLERRM;
        END;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION audit.regenerar_todos() IS
  'Redespliega los triggers de todas las tablas activas y retira los de las desactivadas.';

-- -----------------------------------------------------------------------------
-- Vista de estado. Util para la interfaz y para verificar el despliegue.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW audit.v_estado_auditoria AS
SELECT
    ta.id                AS tabla_auditada_id,
    ta.esquema,
    ta.tabla,
    ta.activa            AS tabla_activa,
    ta.trigger_desplegado,
    count(DISTINCT col.id) FILTER (WHERE col.activa)  AS columnas_activas,
    count(cfg.id) FILTER (WHERE cfg.activa AND cfg.tipo_evento_id = 1) AS eventos_insert,
    count(cfg.id) FILTER (WHERE cfg.activa AND cfg.tipo_evento_id = 2) AS eventos_update,
    count(cfg.id) FILTER (WHERE cfg.activa AND cfg.tipo_evento_id = 3) AS eventos_delete
FROM audit.tabla_auditada ta
LEFT JOIN audit.columna_auditada col ON col.tabla_auditada_id = ta.id
LEFT JOIN audit.configuracion    cfg ON cfg.columna_auditada_id = col.id
GROUP BY ta.id, ta.esquema, ta.tabla, ta.activa, ta.trigger_desplegado;

COMMENT ON VIEW audit.v_estado_auditoria IS
  'Estado actual de la auditoria por tabla: columnas vigiladas, eventos configurados y despliegue.';

GRANT SELECT ON audit.v_estado_auditoria TO PUBLIC;
