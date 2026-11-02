-- =============================================================================
-- AutoAudit - pruebas/03_pruebas_funcionales.sql
-- Casos de prueba funcionales. Cada caso comprueba una exigencia concreta de
-- los criterios de aceptacion. El script aborta en el primer fallo.
--
-- Requiere haber ejecutado antes 01_datos_demo.sql y 02_configuracion_demo.sql.
-- =============================================================================

\set ON_ERROR_STOP on

-- Despliegue inicial de los triggers a partir de la configuracion vigente.
SELECT objeto, resultado FROM audit.regenerar_todos();

-- Punto de partida limpio para que los conteos sean comparables.
TRUNCATE audit.bitacora RESTART IDENTITY;
DELETE FROM rrhh.asignacion;
DELETE FROM rrhh.empleado;

-- -----------------------------------------------------------------------------
-- Caso 1. INSERT queda registrado en bitacora con todos los campos requeridos.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_filas integer;
    v_nulos integer;
    v_id    integer;
BEGIN
    INSERT INTO rrhh.empleado (nombre, puesto, salario)
    VALUES ('Ana Lopez', 'Analista', 7500.00)
    RETURNING id INTO v_id;

    SELECT count(*) INTO v_filas
      FROM audit.bitacora b
      JOIN audit.configuracion cfg ON cfg.id = b.configuracion_id
     WHERE cfg.tipo_evento_id = 1
       AND b.clave_primaria = 'id=' || v_id;

    IF v_filas <> 3 THEN
        RAISE EXCEPTION 'Caso 1 fallido: se esperaban 3 filas de INSERT y hay %', v_filas;
    END IF;

    -- El valor nuevo se captura y el anterior queda nulo, como corresponde.
    SELECT count(*) INTO v_nulos
      FROM audit.bitacora b
      JOIN audit.configuracion cfg ON cfg.id = b.configuracion_id
     WHERE cfg.tipo_evento_id = 1
       AND b.clave_primaria = 'id=' || v_id
       AND b.valor_anterior IS NOT NULL;

    IF v_nulos <> 0 THEN
        RAISE EXCEPTION 'Caso 1 fallido: un INSERT registro valor anterior';
    END IF;

    -- Usuario, estacion y fecha quedan poblados en cada fila.
    SELECT count(*) INTO v_nulos
      FROM audit.bitacora b
     WHERE b.usuario_id IS NULL OR b.estacion_id IS NULL OR b.fecha_hora IS NULL;

    IF v_nulos <> 0 THEN
        RAISE EXCEPTION 'Caso 1 fallido: hay filas sin usuario, estacion o fecha';
    END IF;

    RAISE NOTICE 'Caso 1 INSERT: correcto (% filas)', v_filas;
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 2. UPDATE captura valor antiguo y valor nuevo, y solo de las columnas
-- que efectivamente cambiaron.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_id    integer;
    v_filas integer;
    v_ant   text;
    v_nue   text;
BEGIN
    SELECT id INTO v_id FROM rrhh.empleado WHERE nombre = 'Ana Lopez';

    UPDATE rrhh.empleado
       SET salario = 8200.00
     WHERE id = v_id;

    SELECT count(*) INTO v_filas
      FROM audit.bitacora b
      JOIN audit.configuracion cfg ON cfg.id = b.configuracion_id
     WHERE cfg.tipo_evento_id = 2
       AND b.clave_primaria = 'id=' || v_id;

    IF v_filas <> 1 THEN
        RAISE EXCEPTION 'Caso 2 fallido: cambio una columna y se registraron % filas', v_filas;
    END IF;

    SELECT b.valor_anterior, b.valor_nuevo INTO v_ant, v_nue
      FROM audit.bitacora b
      JOIN audit.configuracion cfg ON cfg.id = b.configuracion_id
     WHERE cfg.tipo_evento_id = 2
       AND b.clave_primaria = 'id=' || v_id;

    IF v_ant <> '7500.00' OR v_nue <> '8200.00' THEN
        RAISE EXCEPTION 'Caso 2 fallido: valores incorrectos, anterior=% nuevo=%', v_ant, v_nue;
    END IF;

    RAISE NOTICE 'Caso 2 UPDATE: correcto (% -> %)', v_ant, v_nue;
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 3. Un UPDATE que no altera ninguna columna vigilada no genera bitacora.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_id     integer;
    v_antes  integer;
    v_despues integer;
BEGIN
    SELECT id INTO v_id FROM rrhh.empleado WHERE nombre = 'Ana Lopez';
    SELECT count(*) INTO v_antes FROM audit.bitacora;

    -- La columna "activo" no esta configurada para auditoria.
    UPDATE rrhh.empleado SET activo = false WHERE id = v_id;
    -- Reasignar el mismo valor tampoco debe producir registro.
    UPDATE rrhh.empleado SET salario = 8200.00 WHERE id = v_id;

    SELECT count(*) INTO v_despues FROM audit.bitacora;

    IF v_antes <> v_despues THEN
        RAISE EXCEPTION 'Caso 3 fallido: se registraron % filas espurias', v_despues - v_antes;
    END IF;

    RAISE NOTICE 'Caso 3 UPDATE sin cambio real: correcto (sin filas espurias)';
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 4. DELETE preserva los datos en bitacora aunque el registro fuente
-- desaparezca. Es la exigencia central del enunciado.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_id    integer;
    v_filas integer;
    v_total integer;
BEGIN
    SELECT id INTO v_id FROM rrhh.empleado WHERE nombre = 'Ana Lopez';

    DELETE FROM rrhh.empleado WHERE id = v_id;

    IF EXISTS (SELECT 1 FROM rrhh.empleado WHERE id = v_id) THEN
        RAISE EXCEPTION 'Caso 4 fallido: el registro fuente no se elimino';
    END IF;

    SELECT count(*) INTO v_filas
      FROM audit.bitacora b
      JOIN audit.configuracion cfg ON cfg.id = b.configuracion_id
     WHERE cfg.tipo_evento_id = 3
       AND b.clave_primaria = 'id=' || v_id;

    IF v_filas <> 3 THEN
        RAISE EXCEPTION 'Caso 4 fallido: se esperaban 3 filas de DELETE y hay %', v_filas;
    END IF;

    -- Toda la historia del registro sigue disponible pese a que ya no existe.
    SELECT count(*) INTO v_total
      FROM audit.bitacora
     WHERE clave_primaria = 'id=' || v_id;

    IF v_total < 7 THEN
        RAISE EXCEPTION 'Caso 4 fallido: la historia del registro quedo incompleta (% filas)', v_total;
    END IF;

    RAISE NOTICE 'Caso 4 DELETE: correcto (% filas de borrado, % de historia total)', v_filas, v_total;
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 5. Llave primaria compuesta.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_emp  integer;
    v_clave text;
    v_ant  text;
    v_nue  text;
BEGIN
    INSERT INTO rrhh.empleado (nombre, puesto, salario)
    VALUES ('Carlos Mejia', 'Desarrollador', 9000.00)
    RETURNING id INTO v_emp;

    INSERT INTO rrhh.asignacion (empleado_id, proyecto, horas)
    VALUES (v_emp, 'AutoAudit', 40.00);

    UPDATE rrhh.asignacion
       SET horas = 55.00
     WHERE empleado_id = v_emp AND proyecto = 'AutoAudit';

    SELECT b.clave_primaria, b.valor_anterior, b.valor_nuevo
      INTO v_clave, v_ant, v_nue
      FROM audit.bitacora b
      JOIN audit.configuracion cfg ON cfg.id = b.configuracion_id
      JOIN audit.columna_auditada col ON col.id = cfg.columna_auditada_id
      JOIN audit.tabla_auditada ta ON ta.id = col.tabla_auditada_id
     WHERE ta.tabla = 'asignacion' AND cfg.tipo_evento_id = 2;

    IF v_clave <> 'empleado_id=' || v_emp || '|proyecto=AutoAudit' THEN
        RAISE EXCEPTION 'Caso 5 fallido: clave compuesta mal armada: %', v_clave;
    END IF;

    IF v_ant <> '40.00' OR v_nue <> '55.00' THEN
        RAISE EXCEPTION 'Caso 5 fallido: valores incorrectos en llave compuesta';
    END IF;

    RAISE NOTICE 'Caso 5 llave compuesta: correcto (%)', v_clave;
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 6. Desactivar una configuracion detiene el registro sin necesidad de
-- regenerar el trigger.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_cfg    integer;
    v_emp    integer;
    v_antes  integer;
    v_despues integer;
BEGIN
    SELECT cfg.id INTO v_cfg
      FROM audit.configuracion cfg
      JOIN audit.columna_auditada col ON col.id = cfg.columna_auditada_id
      JOIN audit.tabla_auditada ta ON ta.id = col.tabla_auditada_id
     WHERE ta.tabla = 'empleado' AND col.columna = 'salario' AND cfg.tipo_evento_id = 2;

    UPDATE audit.configuracion SET activa = false WHERE id = v_cfg;

    SELECT id INTO v_emp FROM rrhh.empleado WHERE nombre = 'Carlos Mejia';
    SELECT count(*) INTO v_antes FROM audit.bitacora;

    UPDATE rrhh.empleado SET salario = 9999.00 WHERE id = v_emp;

    SELECT count(*) INTO v_despues FROM audit.bitacora;

    IF v_antes <> v_despues THEN
        RAISE EXCEPTION 'Caso 6 fallido: se registro un cambio con configuracion desactivada';
    END IF;

    -- Se restituye el estado para no afectar las pruebas siguientes.
    UPDATE audit.configuracion SET activa = true WHERE id = v_cfg;

    UPDATE rrhh.empleado SET salario = 9500.00 WHERE id = v_emp;
    SELECT count(*) INTO v_despues FROM audit.bitacora;

    IF v_despues <> v_antes + 1 THEN
        RAISE EXCEPTION 'Caso 6 fallido: al reactivar no se reanudo el registro';
    END IF;

    RAISE NOTICE 'Caso 6 activacion y desactivacion en caliente: correcto';
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 7. El generador rechaza una tabla sin llave primaria.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_id integer;
BEGIN
    INSERT INTO audit.tabla_auditada (esquema, tabla)
    VALUES ('rrhh', 'sin_llave')
    ON CONFLICT (esquema, tabla) DO UPDATE SET activa = true
    RETURNING id INTO v_id;

    INSERT INTO audit.columna_auditada (tabla_auditada_id, columna)
    VALUES (v_id, 'dato')
    ON CONFLICT (tabla_auditada_id, columna) DO NOTHING;

    INSERT INTO audit.configuracion (columna_auditada_id, tipo_evento_id)
    SELECT col.id, 1 FROM audit.columna_auditada col WHERE col.tabla_auditada_id = v_id
    ON CONFLICT DO NOTHING;

    BEGIN
        PERFORM audit.generar_trigger(v_id);
        RAISE EXCEPTION 'Caso 7 fallido: se genero trigger para una tabla sin llave primaria';
    EXCEPTION WHEN invalid_table_definition THEN
        RAISE NOTICE 'Caso 7 tabla sin llave primaria: correcto (rechazada)';
    END;

    -- Se desactiva para que no interfiera con la regeneracion masiva.
    UPDATE audit.tabla_auditada SET activa = false WHERE id = v_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 8. El generador rechaza una columna que no existe en la tabla origen.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_tabla integer;
    v_col   integer;
BEGIN
    SELECT id INTO v_tabla FROM audit.tabla_auditada
     WHERE esquema = 'rrhh' AND tabla = 'empleado';

    INSERT INTO audit.columna_auditada (tabla_auditada_id, columna)
    VALUES (v_tabla, 'columna_inexistente')
    RETURNING id INTO v_col;

    BEGIN
        PERFORM audit.generar_trigger(v_tabla);
        RAISE EXCEPTION 'Caso 8 fallido: se acepto una columna inexistente';
    EXCEPTION WHEN undefined_column THEN
        RAISE NOTICE 'Caso 8 columna inexistente: correcto (rechazada)';
    END;

    DELETE FROM audit.columna_auditada WHERE id = v_col;
END;
$$;

-- -----------------------------------------------------------------------------
-- Caso 9. La bitacora no admite eliminacion de configuracion referenciada.
-- La integridad referencial protege la historia acumulada.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_cfg integer;
BEGIN
    SELECT configuracion_id INTO v_cfg FROM audit.bitacora LIMIT 1;

    BEGIN
        DELETE FROM audit.configuracion WHERE id = v_cfg;
        RAISE EXCEPTION 'Caso 9 fallido: se elimino una configuracion con bitacora asociada';
    EXCEPTION WHEN foreign_key_violation OR restrict_violation THEN
        RAISE NOTICE 'Caso 9 integridad de la bitacora: correcto (eliminacion bloqueada)';
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- Resumen de la bitacora producida por las pruebas.
-- -----------------------------------------------------------------------------
SELECT
    ta.esquema || '.' || ta.tabla AS objeto,
    te.codigo                     AS evento,
    col.columna,
    count(*)                      AS registros
FROM audit.bitacora b
JOIN audit.configuracion    cfg ON cfg.id  = b.configuracion_id
JOIN audit.columna_auditada col ON col.id  = cfg.columna_auditada_id
JOIN audit.tabla_auditada   ta  ON ta.id   = col.tabla_auditada_id
JOIN audit.tipo_evento      te  ON te.id   = cfg.tipo_evento_id
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
