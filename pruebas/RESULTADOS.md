# Resultados de la última ejecución

Ejecutado sobre PostgreSQL 16.15 en Ubuntu 24.04, partiendo de una base recién
creada e instalada con `sql/00_instalar.sql`.

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
| 9 | Configuración con bitácora no puede eliminarse | correcto |

## Pruebas de rendimiento

Tabla de prueba con tres columnas vigiladas ante las tres operaciones, que es
la configuración más exigente posible.

| Escenario | Volumen | Milisegundos | Filas en bitácora | Microsegundos por fila |
|:--|--:|--:|--:|--:|
| INSERT sin auditoría | 1 000 | 2,26 | 0 | 2,3 |
| INSERT sin auditoría | 5 000 | 8,64 | 0 | 1,7 |
| INSERT sin auditoría | 20 000 | 34,65 | 0 | 1,7 |
| INSERT sin auditoría | 50 000 | 145,75 | 0 | 2,9 |
| INSERT con auditoría | 1 000 | 131,51 | 3 012 | 131,5 |
| INSERT con auditoría | 5 000 | 546,39 | 18 012 | 109,3 |
| INSERT con auditoría | 20 000 | 2 422,53 | 78 012 | 121,1 |
| INSERT con auditoría | 50 000 | 6 212,31 | 228 012 | 124,2 |
| UPDATE con auditoría | 1 000 | 56,83 | 229 012 | 56,8 |
| UPDATE con auditoría | 5 000 | 223,30 | 234 012 | 44,7 |
| UPDATE con auditoría | 20 000 | 1 019,17 | 254 012 | 51,0 |
| DELETE con auditoría | 10 000 | 1 284,56 | 284 012 | 128,5 |

El costo por fila se mantiene estable entre mil y cincuenta mil registros, lo
que indica que el mecanismo escala de forma lineal y que la bitácora no se
degrada conforme crece.

## Consultas históricas

Medidas sobre una bitácora de 284 012 filas.

| Consulta | Filas devueltas | Milisegundos |
|:--|--:|--:|
| Por usuario | 284 012 | 20,63 |
| Por columna | 2 | 0,12 |
| Por registro afectado | 18 | 0,08 |

La consulta por usuario devolvió la bitácora completa porque en el escenario de
prueba todas las filas pertenecían a un mismo usuario, de modo que esa cifra
corresponde a un recorrido total y no a una búsqueda selectiva.
