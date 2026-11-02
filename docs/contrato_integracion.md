# Contrato de integración

Este documento fija los nombres y las firmas que ya están implementados en la
rama de generación de triggers, para que el módulo de configuración, las
consultas de reporte y la interfaz se programen en paralelo sin esperar.

Nada de lo que aparece aquí va a cambiar. Si algo resulta insuficiente, se
agrega una función nueva en lugar de modificar una existente.

## Lo que ya está hecho

El esquema `audit` con sus siete tablas, el catálogo de eventos, el generador
dinámico de triggers, las vistas de consulta al diccionario de datos del motor
y el juego de pruebas. Se instala con un solo comando:

```
psql -d basedatos -f sql/00_instalar.sql
```

## Tablas de configuración

La jerarquía es `tabla_auditada` contiene `columna_auditada`, y cada columna se
combina con un `tipo_evento` para producir una fila de `configuracion`.

| Tabla | Columnas que importan para configurar |
|:--|:--|
| `audit.tabla_auditada` | `id`, `esquema`, `tabla`, `activa` |
| `audit.columna_auditada` | `id`, `tabla_auditada_id`, `columna`, `activa` |
| `audit.configuracion` | `id`, `columna_auditada_id`, `tipo_evento_id`, `activa` |
| `audit.tipo_evento` | `id` 1 = INSERT, 2 = UPDATE, 3 = DELETE |

Las tres primeras tienen restricción de unicidad, de modo que conviene usar
`ON CONFLICT DO NOTHING` o `DO UPDATE SET activa = true` al insertar.

## Funciones disponibles

| Función | Devuelve | Para qué sirve |
|:--|:--|:--|
| `audit.generar_trigger(tabla_auditada_id)` | `text` | Código SQL del trigger, sin ejecutarlo |
| `audit.generar_trigger(esquema, tabla)` | `text` | Lo mismo, identificando por nombre |
| `audit.aplicar_trigger(tabla_auditada_id)` | `text` | Genera e instala el trigger |
| `audit.eliminar_trigger(tabla_auditada_id)` | `text` | Retira el trigger, conserva la bitácora |
| `audit.regenerar_todos()` | tabla | Redespliega todo según la configuración vigente |

La regla de uso es simple. Después de cualquier cambio estructural en la
configuración, hay que llamar a `audit.regenerar_todos()`. Activar o desactivar
una configuración ya existente no requiere regenerar nada porque surte efecto
de inmediato.

## Vistas para la interfaz

`audit.v_diccionario_tablas` lista las tablas de los esquemas de usuario con
una columna `tiene_llave_primaria`. Solo las que la tienen pueden auditarse, así
que ese es el filtro que debe aplicar la pantalla de selección.

`audit.v_diccionario_columnas` lista las columnas de cada tabla con su tipo de
dato y una marca de llave primaria.

`audit.v_estado_auditoria` devuelve, por tabla, cuántas columnas se vigilan,
cuántos eventos hay configurados por tipo y si el trigger está instalado. Sirve
para la pantalla de estado y para confirmar que un despliegue funcionó.

## Estructura de la bitácora

```
audit.bitacora (
    id, configuracion_id, usuario_id, estacion_id,
    fecha_hora, clave_primaria, valor_anterior, valor_nuevo, id_transaccion
)
```

`clave_primaria` guarda en texto los pares de columna y valor de la llave
primaria del registro afectado, por ejemplo `id=42`, o bien
`empleado_id=7|proyecto=AutoAudit` cuando la llave es compuesta.

Para mostrar el nombre de la tabla, el de la columna y el tipo de evento hay
que unir la bitácora con la configuración:

```sql
SELECT b.fecha_hora,
       u.nombre_usuario,
       e.direccion_ip,
       ta.esquema || '.' || ta.tabla AS tabla,
       col.columna,
       te.codigo AS evento,
       b.clave_primaria,
       b.valor_anterior,
       b.valor_nuevo
  FROM audit.bitacora b
  JOIN audit.configuracion    cfg ON cfg.id = b.configuracion_id
  JOIN audit.columna_auditada col ON col.id = cfg.columna_auditada_id
  JOIN audit.tabla_auditada   ta  ON ta.id  = col.tabla_auditada_id
  JOIN audit.tipo_evento      te  ON te.id  = cfg.tipo_evento_id
  JOIN audit.usuario_auditado u   ON u.id   = b.usuario_id
  JOIN audit.estacion_trabajo e   ON e.id   = b.estacion_id
 ORDER BY b.fecha_hora DESC;
```

Esa consulta es la base de los tres reportes que pide el enunciado. Para el
filtro por usuario conviene filtrar por `b.usuario_id`, y para el filtro por
columna por `cfg.columna_auditada_id`, porque ambos tienen índice. Filtrar por
el nombre del usuario o de la columna obliga a resolver la unión primero y
resulta más lento sobre bitácoras grandes.

## Lo que falta y a quién le toca

El módulo de configuración, que valide la existencia de tabla y columnas contra
las vistas del diccionario, restrinja el acceso a usuarios administrativos y
persista la configuración en las tres tablas descritas arriba.

Las consultas parametrizadas de historial por usuario y por columna, el orden
cronológico y la exportación en formato estándar.

La interfaz y el manual de configuración y activación.

## Advertencia sobre cargas masivas

El trigger agrega alrededor de ciento treinta microsegundos por fila insertada
con tres columnas vigiladas. En operaciones individuales eso es imperceptible,
pero en una carga de decenas de miles de registros el sobrecosto es notorio. Si
la interfaz va a ofrecer una carga masiva, conviene desactivar las
configuraciones afectadas antes y reactivarlas después, que es una simple
actualización de la bandera `activa` y no requiere regenerar triggers.
