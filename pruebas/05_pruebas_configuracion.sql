-- =============================================================================
-- AutoAudit - pruebas/05_pruebas_configuracion.sql
-- Casos de prueba del modulo de configuracion y del modulo de consulta.
--
-- Como en 03, cada caso comprueba su resultado con aserciones y el guion
-- aborta en el primer fallo, de modo que una ejecucion limpia equivale a que
-- todos pasaron.
--
-- Requiere haber ejecutado antes pruebas/01_datos_demo.sql.
-- =============================================================================

\set ON_ERROR_STOP on

-- Punto de partida limpio.
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT id FROM audit.tabla_auditada LOOP
        BEGIN PERFORM audit.eliminar_trigger(r.id); EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
END;
$$;
DELETE FROM audit.bitacora;
DELETE FROM audit.configuracion;
DELETE FROM audit.columna_auditada;
DELETE FROM audit.tabla_auditada;
DELETE FROM rrhh.asignacion;
DELETE FROM rrhh.empleado;

-- -----------------------------------------------------------------------------
-- Caso 1. Configuracion valida: persiste y despliega en una sola llamada.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_msg text;
    v_n   integer;
BEGIN
    v_msg := audit.configurar_auditoria('rrhh','empleado',
                ARRAY['nombre','puesto','salario'], ARRAY['INSERT','UPDATE','DELETE']);

    SELECT count(*) INTO v_n FROM audit.configuracion WHERE activa;
    IF v_n <> 9 THEN
        RAISE EXCEPTION 'Caso 1 fallido: se esperaban 9 configuraciones y hay %', v_n;
    END IF;

    SELECT count(*) INTO v_n
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='rrhh' AND c.relname='empleado' AND NOT t.tgisinternal;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'Caso 1 fallido: el trigger no quedo instalado';
    END IF;

    RAISE NOTICE 'Caso 1 configurar_auditoria: correcto (%)', v_msg;
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 2. Tabla inexistente: se rechaza.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    BEGIN
        PERFORM audit.configurar_auditoria('rrhh','tabla_fantasma', ARRAY['x']);
        RAISE EXCEPTION 'Caso 2 fallido: se acepto una tabla inexistente';
    EXCEPTION WHEN undefined_table THEN
        RAISE NOTICE 'Caso 2 tabla inexistente: correcto (rechazada)';
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 3. Tabla sin llave primaria: se rechaza antes de tocar nada.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    BEGIN
        PERFORM audit.configurar_auditoria('rrhh','sin_llave', ARRAY['dato']);
        RAISE EXCEPTION 'Caso 3 fallido: se acepto una tabla sin llave primaria';
    EXCEPTION WHEN invalid_table_definition THEN
        RAISE NOTICE 'Caso 3 tabla sin llave primaria: correcto (rechazada)';
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 4. Columna inexistente: se rechaza y no queda nada persistido.
-- Es el fallo que la version anterior de la interfaz dejaba pasar.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_n integer;
BEGIN
    BEGIN
        PERFORM audit.configurar_auditoria('rrhh','empleado', ARRAY['salario','no_existe']);
        RAISE EXCEPTION 'Caso 4 fallido: se acepto una columna inexistente';
    EXCEPTION WHEN undefined_column THEN
        NULL;
    END;

    SELECT count(*) INTO v_n FROM audit.columna_auditada WHERE columna = 'no_existe';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'Caso 4 fallido: quedo persistida la columna invalida';
    END IF;

    RAISE NOTICE 'Caso 4 columna inexistente: correcto (rechazada sin persistir)';
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 5. Evento no reconocido y auditoria del propio esquema audit.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    BEGIN
        PERFORM audit.configurar_auditoria('rrhh','empleado', ARRAY['salario'], ARRAY['TRUNCATE']);
        RAISE EXCEPTION 'Caso 5 fallido: se acepto un evento invalido';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    BEGIN
        PERFORM audit.configurar_auditoria('audit','bitacora', ARRAY['valor_nuevo']);
        RAISE EXCEPTION 'Caso 5 fallido: se acepto auditar el esquema audit';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    RAISE NOTICE 'Caso 5 evento invalido y esquema audit: correcto (ambos rechazados)';
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 6. Desactivar un evento surte efecto sin regenerar el trigger.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_id    integer;
    v_antes integer;
    v_desp  integer;
BEGIN
    INSERT INTO rrhh.empleado (nombre, puesto, salario)
    VALUES ('Ana Lopez','Analista',7500.00) RETURNING id INTO v_id;

    PERFORM audit.desactivar_evento('rrhh','empleado','salario','UPDATE');

    SELECT count(*) INTO v_antes FROM audit.bitacora;
    UPDATE rrhh.empleado SET salario = 8000.00 WHERE id = v_id;
    SELECT count(*) INTO v_desp FROM audit.bitacora;

    IF v_antes <> v_desp THEN
        RAISE EXCEPTION 'Caso 6 fallido: se registro un cambio con el evento desactivado';
    END IF;

    PERFORM audit.activar_evento('rrhh','empleado','salario','UPDATE');
    UPDATE rrhh.empleado SET salario = 8500.00 WHERE id = v_id;
    SELECT count(*) INTO v_desp FROM audit.bitacora;

    IF v_desp <> v_antes + 1 THEN
        RAISE EXCEPTION 'Caso 6 fallido: al reactivar no se reanudo el registro';
    END IF;

    RAISE NOTICE 'Caso 6 desactivar y activar evento: correcto (sin regenerar)';
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 7. Desactivar una columna regenera el trigger y deja de registrarla.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_id    integer;
    v_antes integer;
    v_desp  integer;
BEGIN
    SELECT id INTO v_id FROM rrhh.empleado WHERE nombre = 'Ana Lopez';

    PERFORM audit.desactivar_columna('rrhh','empleado','puesto');

    SELECT count(*) INTO v_antes FROM audit.bitacora;
    UPDATE rrhh.empleado SET puesto = 'Coordinadora' WHERE id = v_id;
    SELECT count(*) INTO v_desp FROM audit.bitacora;

    IF v_antes <> v_desp THEN
        RAISE EXCEPTION 'Caso 7 fallido: se registro una columna desactivada';
    END IF;

    -- Las demas columnas siguen vigiladas.
    UPDATE rrhh.empleado SET nombre = 'Ana Lopez Diaz' WHERE id = v_id;
    SELECT count(*) INTO v_desp FROM audit.bitacora;
    IF v_desp <> v_antes + 1 THEN
        RAISE EXCEPTION 'Caso 7 fallido: dejo de registrar una columna que sigue activa';
    END IF;

    RAISE NOTICE 'Caso 7 desactivar columna: correcto (regenerado, el resto sigue)';
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 8. Desactivar la tabla retira el trigger y conserva la bitacora.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_id     integer;
    v_hist   integer;
    v_trig   integer;
    v_antes  integer;
    v_desp   integer;
BEGIN
    SELECT count(*) INTO v_hist FROM audit.bitacora;
    SELECT id INTO v_id FROM rrhh.empleado WHERE nombre = 'Ana Lopez Diaz';

    PERFORM audit.desactivar_tabla('rrhh','empleado');

    SELECT count(*) INTO v_trig
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='rrhh' AND c.relname='empleado' AND NOT t.tgisinternal;
    IF v_trig <> 0 THEN
        RAISE EXCEPTION 'Caso 8 fallido: el trigger no fue retirado';
    END IF;

    SELECT count(*) INTO v_antes FROM audit.bitacora;
    IF v_antes <> v_hist THEN
        RAISE EXCEPTION 'Caso 8 fallido: se perdio bitacora al desactivar';
    END IF;

    UPDATE rrhh.empleado SET salario = 9999.00 WHERE id = v_id;
    SELECT count(*) INTO v_desp FROM audit.bitacora;
    IF v_desp <> v_antes THEN
        RAISE EXCEPTION 'Caso 8 fallido: siguio registrando con la tabla desactivada';
    END IF;

    PERFORM audit.activar_tabla('rrhh','empleado');
    UPDATE rrhh.empleado SET salario = 10000.00 WHERE id = v_id;
    SELECT count(*) INTO v_desp FROM audit.bitacora;
    IF v_desp <> v_antes + 1 THEN
        RAISE EXCEPTION 'Caso 8 fallido: al reactivar la tabla no se reanudo el registro';
    END IF;

    RAISE NOTICE 'Caso 8 desactivar y activar tabla: correcto (bitacora intacta)';
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 9. Restriccion de privilegios administrativos.
-- Se crea un rol sin privilegios y se comprueba que no puede configurar.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autoaudit_prueba_sin_privilegios') THEN
        CREATE ROLE autoaudit_prueba_sin_privilegios LOGIN;
    END IF;
END;
$$;

DO $$
BEGIN
    SET LOCAL ROLE autoaudit_prueba_sin_privilegios;

    IF audit.fn_es_administrador() THEN
        RESET ROLE;
        RAISE EXCEPTION 'Caso 9 fallido: un rol sin privilegios se reporta como administrador';
    END IF;

    BEGIN
        PERFORM audit.configurar_auditoria('rrhh','empleado', ARRAY['salario']);
        RESET ROLE;
        RAISE EXCEPTION 'Caso 9 fallido: un rol sin privilegios pudo configurar auditoria';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;

    RESET ROLE;
    RAISE NOTICE 'Caso 9 restriccion administrativa: correcto (rechazado en la base)';
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 10. La bitacora rechaza la escritura directa de un usuario comun.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    SET LOCAL ROLE autoaudit_prueba_sin_privilegios;
    BEGIN
        INSERT INTO audit.bitacora (configuracion_id, usuario_id, estacion_id, clave_primaria)
        VALUES (1, 1, 1, 'falsificado');
        RESET ROLE;
        RAISE EXCEPTION 'Caso 10 fallido: se pudo escribir directamente en la bitacora';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    RESET ROLE;
    RAISE NOTICE 'Caso 10 escritura directa en bitacora: correcto (denegada)';
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 11. Consultas parametrizadas de historial.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_usuario varchar(63) := session_user;
    v_todas   integer;
    v_usr     integer;
    v_col     integer;
BEGIN
    SELECT count(*) INTO v_todas FROM audit.consultar_historial();
    IF v_todas = 0 THEN
        RAISE EXCEPTION 'Caso 11 fallido: la consulta general no devolvio filas';
    END IF;

    SELECT count(*) INTO v_usr FROM audit.consultar_por_usuario(v_usuario);
    IF v_usr <> v_todas THEN
        RAISE EXCEPTION 'Caso 11 fallido: consulta por usuario devolvio % de % filas', v_usr, v_todas;
    END IF;

    SELECT count(*) INTO v_col FROM audit.consultar_por_columna('rrhh','empleado','salario');
    IF v_col = 0 THEN
        RAISE EXCEPTION 'Caso 11 fallido: consulta por columna no devolvio filas';
    END IF;

    -- Un usuario sin actividad debe producir un error claro, no una lista vacia.
    BEGIN
        PERFORM audit.consultar_por_usuario('usuario_que_no_existe');
        RAISE EXCEPTION 'Caso 11 fallido: no se rechazo un usuario inexistente';
    EXCEPTION WHEN no_data_found THEN
        NULL;
    END;

    RAISE NOTICE 'Caso 11 consultas parametrizadas: correcto (% totales, % por columna)', v_todas, v_col;
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 12. Orden cronologico y acotacion por fechas.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_fechas timestamptz[];
    v_i      integer;
    v_rango  integer;
BEGIN
    SELECT array_agg(fecha_hora) INTO v_fechas FROM audit.consultar_historial();

    FOR v_i IN 2 .. cardinality(v_fechas) LOOP
        IF v_fechas[v_i] > v_fechas[v_i-1] THEN
            RAISE EXCEPTION 'Caso 12 fallido: el historial no viene en orden descendente';
        END IF;
    END LOOP;

    SELECT count(*) INTO v_rango
      FROM audit.consultar_historial(p_desde => now() - interval '1 hour');
    IF v_rango <> cardinality(v_fechas) THEN
        RAISE EXCEPTION 'Caso 12 fallido: el filtro por fecha descarto filas recientes';
    END IF;

    SELECT count(*) INTO v_rango
      FROM audit.consultar_historial(p_hasta => now() - interval '1 hour');
    IF v_rango <> 0 THEN
        RAISE EXCEPTION 'Caso 12 fallido: el filtro por fecha devolvio filas fuera de rango';
    END IF;

    RAISE NOTICE 'Caso 12 orden cronologico y rango de fechas: correcto';
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 13. La historia de un registro sobrevive a su eliminacion.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_id    integer;
    v_clave text;
    v_antes integer;
    v_desp  integer;
BEGIN
    SELECT id INTO v_id FROM rrhh.empleado WHERE nombre = 'Ana Lopez Diaz';
    v_clave := 'id=' || v_id;

    SELECT count(*) INTO v_antes FROM audit.consultar_por_registro('rrhh','empleado',v_clave);

    DELETE FROM rrhh.empleado WHERE id = v_id;

    SELECT count(*) INTO v_desp FROM audit.consultar_por_registro('rrhh','empleado',v_clave);

    IF v_desp <= v_antes THEN
        RAISE EXCEPTION 'Caso 13 fallido: el borrado no quedo registrado';
    END IF;

    IF EXISTS (SELECT 1 FROM rrhh.empleado WHERE id = v_id) THEN
        RAISE EXCEPTION 'Caso 13 fallido: el registro no se elimino';
    END IF;

    RAISE NOTICE 'Caso 13 historia tras eliminacion: correcto (% filas conservadas)', v_desp;
END;
$$;

-- -----------------------------------------------------------------------------
-- Resumen
-- -----------------------------------------------------------------------------
SELECT nombre_usuario, objeto, evento, cambios
  FROM audit.v_resumen_actividad
 ORDER BY objeto, evento;
