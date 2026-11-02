# Resultados de la última ejecución

Ejecutado sobre PostgreSQL 16.15 en Ubuntu 24.04 y sobre PostgreSQL 18.6 en Fedora 44,
partiendo en ambos casos de una base recién creada e instalada con `sql/00_instalar.sql`.
Los nueve casos funcionales pasan en las dos versiones. Las cifras de rendimiento
corresponden a la ejecución sobre 18.6, que es la versión que exige el enunciado.

## Pruebas funcionales

Los nueve casos pasaron. El guion aborta al primer fallo, de modo que una
ejecución completa equivale a que todos pasaron.

| Caso | Qué verifica | Resultado |
|:--:|:--|:--|
| 1 | INSERT registra una fila por columna vigilada, con usuario, estación y fecha | correcto, 3 filas |
| 2 | UPDATE captura valor anterior y nuevo | correcto, 7500.00 a 8200.00 |
| 3 | UPDATE sin cambio real no genera filas | correcto, sin filas espurias |
| 4 | DELETE preserva los datos tras eliminar el registro fuente | correcto, 3 filas de borrado y 7 de historia |
| 5 | Llave primaria compuesta | correcto, `empleado_id=2\|proyecto=AutoAudit` |
| 6 | Activación y desactivación en caliente sin regenerar | correcto |
| 7 | Tabla sin llave primaria es rechazada | correcto |
| 8 | Columna inexistente es rechazada | correcto |
| 9 | Configuración con bitácora no puede eliminarse | correcto, atrapa 23503 y 23001 |

## Pruebas de rendimiento

Medidas sobre PostgreSQL 18.6 en Fedora 44. Tabla de prueba con tres columnas
vigiladas ante las tres operaciones, que es la configuración más exigente
posible.

| Escenario | Volumen | Milisegundos | Filas en bitácora | Microsegundos por fila |
|:--|--:|--:|--:|--:|
| INSERT sin auditoría | 1 000 | 2,05 | 0 | 2,0 |
| INSERT sin auditoría | 5 000 | 6,31 | 0 | 1,3 |
| INSERT sin auditoría | 20 000 | 26,27 | 0 | 1,3 |
| INSERT sin auditoría | 50 000 | 63,79 | 0 | 1,3 |
| INSERT con auditoría | 1 000 | 59,04 | 3 016 | 59,0 |
| INSERT con auditoría | 5 000 | 293,33 | 18 016 | 58,7 |
| INSERT con auditoría | 20 000 | 1 350,12 | 78 016 | 67,5 |
| INSERT con auditoría | 50 000 | 4 978,38 | 228 016 | 99,6 |
| UPDATE con auditoría | 1 000 | 27,52 | 229 016 | 27,5 |
| UPDATE con auditoría | 5 000 | 115,95 | 234 016 | 23,2 |
| UPDATE con auditoría | 20 000 | 570,27 | 254 016 | 28,5 |
| DELETE con auditoría | 10 000 | 796,38 | 284 016 | 79,6 |

El costo por fila crece de 59 a 100 microsegundos mientras la bitácora pasa de
3 016 a 228 016 filas. El crecimiento corresponde al mantenimiento de los
cuatro índices de la bitácora, cuyo costo de inserción sube con el logaritmo
del número de filas. La bitácora creció 75 veces y el costo unitario se
multiplicó por 1,7.

Las cuatro mediciones de inserción no son independientes: cada una parte de la
bitácora que dejó la anterior, de modo que la de 50 000 corre sobre una
bitácora que ya acumulaba 78 000 filas.

## Consultas históricas

Medidas sobre una bitácora de 284 016 filas.

| Consulta | Filas devueltas | Milisegundos |
|:--|--:|--:|
| Por usuario | 284 016 | 10,93 |
| Por columna | 1 | 0,07 |
| Por registro afectado | 18 | 0,05 |

La consulta por usuario devolvió la bitácora completa porque en el escenario de
prueba todas las filas pertenecían a un mismo usuario, de modo que esa cifra
corresponde a un recorrido total y no a una búsqueda selectiva.

## Nota sobre versiones

PostgreSQL 18 cambió el código de error de las acciones `RESTRICT`, que pasó de
23503 (`foreign_key_violation`) a 23001 (`restrict_violation`), por el commit
086c84b23. El cambio no figura en las notas de versión. El caso 9 atrapa ambas
condiciones y por eso pasa en 16.15 y en 18.6.
