-- =============================================================================
-- AutoAudit - pruebas/02_configuracion_demo.sql
-- Configuracion de auditoria de las tablas de ejemplo.
--
-- Mientras el modulo de configuracion no este disponible, estas inserciones
-- cumplen su papel y fijan el estado que el generador espera encontrar.
-- =============================================================================

-- Tabla rrhh.empleado: se vigilan nombre, puesto y salario.
INSERT INTO audit.tabla_auditada (esquema, tabla)
VALUES ('rrhh', 'empleado')
ON CONFLICT (esquema, tabla) DO NOTHING;

INSERT INTO audit.columna_auditada (tabla_auditada_id, columna)
SELECT ta.id, c.columna
  FROM audit.tabla_auditada ta
  CROSS JOIN (VALUES ('nombre'), ('puesto'), ('salario')) AS c(columna)
 WHERE ta.esquema = 'rrhh' AND ta.tabla = 'empleado'
ON CONFLICT (tabla_auditada_id, columna) DO NOTHING;

-- Las tres operaciones quedan habilitadas para esas tres columnas.
INSERT INTO audit.configuracion (columna_auditada_id, tipo_evento_id)
SELECT col.id, te.id
  FROM audit.columna_auditada col
  JOIN audit.tabla_auditada ta ON ta.id = col.tabla_auditada_id
  CROSS JOIN audit.tipo_evento te
 WHERE ta.esquema = 'rrhh' AND ta.tabla = 'empleado'
ON CONFLICT (columna_auditada_id, tipo_evento_id) DO NOTHING;

-- Tabla rrhh.asignacion: solo se vigilan las horas, y solo en UPDATE y DELETE.
INSERT INTO audit.tabla_auditada (esquema, tabla)
VALUES ('rrhh', 'asignacion')
ON CONFLICT (esquema, tabla) DO NOTHING;

INSERT INTO audit.columna_auditada (tabla_auditada_id, columna)
SELECT ta.id, 'horas'
  FROM audit.tabla_auditada ta
 WHERE ta.esquema = 'rrhh' AND ta.tabla = 'asignacion'
ON CONFLICT (tabla_auditada_id, columna) DO NOTHING;

INSERT INTO audit.configuracion (columna_auditada_id, tipo_evento_id)
SELECT col.id, te.id
  FROM audit.columna_auditada col
  JOIN audit.tabla_auditada ta ON ta.id = col.tabla_auditada_id
  CROSS JOIN audit.tipo_evento te
 WHERE ta.esquema = 'rrhh' AND ta.tabla = 'asignacion'
   AND te.codigo IN ('UPDATE', 'DELETE')
ON CONFLICT (columna_auditada_id, tipo_evento_id) DO NOTHING;
