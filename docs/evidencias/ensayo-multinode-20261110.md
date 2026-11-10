# Ensayo multinode: ubicación real de pods y 1 contra 2 réplicas (10-11-2026)

Objetivo: comprobar con pods reales (no solo con el scheduler) que el overlay `multinode` deja cada servicio en su nodo, y medir **qué ve un cliente** ante fallas de Pharmacy con 1 y con 2 réplicas. Registros en [`ensayo-multinode-20261110/`](ensayo-multinode-20261110/).

## Entorno y alcance (leer antes que los resultados)

- Minikube, perfil `multi`: 5 nodos (contenedores Docker en **un solo host**, 1,8 GB y 2 CPU cada uno): `multi-m02`, `m03` y `m04` con `node-type=backend` (taint `pharmago.io/dedicated=backend`), `multi-m05` como `ops` y el control-plane `multi` como `frontend` sin carga. Runtime containerd y el CNI por defecto de Minikube para clústeres multinodo.
- **Stack reducido.** No caben los 1,8 GB por nodo con todo el stack, así que se desplegaron solo SQL Server (nodo ops), los 3 servicios backend (overlay `multinode`, 2 réplicas cada uno) y, al principio, Prometheus, Grafana, el colector OTLP, `node-exporter` y el agente de nodo. **No se desplegaron** UI, Elasticsearch, Kibana, Fluent Bit ni cAdvisor. Para la medición se apagó además la telemetría (ver "Primer intento inválido").
- Imágenes de backend reconstruidas el mismo día. **No se cargó `seed-data.sql`**: el cliente consulta `/api/drug` con la base sin datos de negocio.
- **Una sola ejecución por escenario.** El cliente es una sonda que hace una solicitud cada ~1,3 s por el gateway (por `kubectl port-forward`, que cae en una sola de sus dos réplicas), así que la resolución es de ~1,3 s: un corte más corto puede no verse y uno de unos segundos se cuenta como 1 o 2 solicitudes fallidas.
- Todo ocurre en una sola computadora: demuestra separación entre nodos de Kubernetes, no entre nodos físicos.

## 1. Ubicación real de los pods

[Registro](ensayo-multinode-20261110/ubicacion-pods.txt): los 7 pods de aplicación en `Running`, **0 pods `Pending` o sin nodo**. Gateway (2 réplicas) en `multi-m03`, Pharmacy (2) en `multi-m04`, Users (2) en `multi-m02`, SQL Server en el nodo ops. Cada servicio quedó entero en un único nodo, distinto del de los otros dos, y se mantuvo así tras los rolling restarts y las caídas de contenedor de los escenarios de abajo. Esto confirma con pods en ejecución lo que antes solo se había visto como asignación del scheduler ([prueba del 10-11](multinode-scheduling-20261110.txt)).

Consecuencia ya documentada: las dos réplicas de cada servicio comparten nodo, así que **la caída de ese nodo tumba el servicio completo**; no se probó.

## 2. Qué ve un cliente: 1 contra 2 réplicas de Pharmacy

Sonda finita de 75 solicitudes (50 en los escenarios 5 y 6). La falla se aplica a los 20 s. Gateway con contadores de rate limit repuestos antes de empezar.

| # | Réplicas | Falla | Solicitudes | Resultado del cliente |
| --- | :---: | --- | ---: | --- |
| 1 | 2 | borrar un pod (ordenado) | 75 | 75 `200`, sin fallos |
| 2 | 2 | `rollout restart` | 75 | 75 `200`, sin fallos |
| 3 | 1 | borrar el pod (ordenado) | 75 | 74 `200` y 1 `502` (21:33:57, recuperado en ~2 s) |
| 4 | 1 | `rollout restart` | 75 | 75 `200`, sin fallos |
| 5 | 2 | **crash del contenedor** (`crictl stop` en el nodo) | 50 | **50 `200`**, sin fallos; todos `Ready` ~9 s después |
| 6 | 1 | **crash del contenedor** (`crictl stop` en el nodo) | 50 | 48 `200` y **2 `502`** (21:41:23 a 21:41:24, recuperado a las 21:41:26); `Ready` ~7 s después |

Lectura:

- **Rolling update (despliegues seguros):** sin ningún fallo con 1 y con 2 réplicas, en una ejecución cada una. Es coherente con `maxUnavailable: 0` y `maxSurge: 1`, pero no demuestra 100 % en general: son 75 solicitudes cada una.
- **Borrado ordenado de un pod:** con 1 réplica hubo un `502`; el `preStop` de 5 s y el `terminationGracePeriodSeconds` mantienen el servicio atendiendo mientras arranca el reemplazo.
- **Crash de contenedor, la falla que pide la rúbrica:** con 1 réplica el cliente vio **~3 s de errores** (2 solicitudes); con 2 réplicas **no vio ninguno**, porque la otra réplica siguió atendiendo mientras el contenedor se reiniciaba. Es la evidencia para sostener las 2 réplicas, con el límite de que es **una sola ejecución** por caso.

## 3. Primer intento inválido (se conserva)

La primera corrida de los escenarios 1 a 4 dio muchos `000` (sin respuesta) y `500`, y en uno los fallos empezaban **antes** de aplicar la falla ([registros](ensayo-multinode-20261110/), archivos `ens-INVALIDO-nodo-saturado-*`). Causa: el nodo ops (1,8 GB, 2 CPU) estaba al 94 % de memoria y 167 % de CPU con SQL Server, Prometheus, Grafana y el colector juntos: Prometheus y el colector se reiniciaron y los servicios fallaron sondas. Esa corrida mide la sobrecarga del nodo, no las réplicas. Se apagaron Prometheus, Grafana, el colector y los DaemonSets de métricas, el nodo bajó a ~1,15 GB y 2 % de CPU, y se repitió todo. **Los resultados de la tabla son de la repetición.**

Lección para la defensa: con nodos de 1,8 GB no cabe el stack completo; con el stack de observabilidad encendido hacen falta nodos ops más grandes (o menos componentes) o las mediciones de disponibilidad se contaminan.

## 4. Qué NO se probó

- La **caída de un nodo** completo (el servicio entero cae porque las réplicas comparten nodo).
- El ensayo con el **stack completo** (UI, Elasticsearch, Kibana, Fluent Bit) y con telemetría encendida durante las fallas.
- `chaos-all` y las alertas de Grafana sobre `multinode`.
- Más de una ejecución por escenario, otros servicios (Users, gateway) y tráfico real de clientes con datos de negocio.
- El MTTR que percibe un cliente más allá de la resolución de ~1,3 s de la sonda.
