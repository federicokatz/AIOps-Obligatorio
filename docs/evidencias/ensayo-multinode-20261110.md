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

Consecuencia: las dos réplicas de cada servicio comparten nodo, así que **la caída de ese nodo tumba el servicio completo**. Se probó en la sección 6, donde además apareció un problema de reprogramación con la afinidad actual.

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

## 4. Camino A: repetir el crash, medido desde dentro del clúster

La sonda de la sección 2 tenía resolución de ~1,3 s y una sola ejecución. Se repitió con un pod sonda dentro del clúster que hace ~10 solicitudes por segundo directo al Service de Pharmacy (`/health`), sin pasar por el gateway ni su rate limit, matando el contenedor con `crictl stop` en el nodo. Tres corridas por caso, y el orden importa (ver abajo). Registros: `camino-A-*.txt`.

| Réplicas | Corrida | Solicitudes fallidas | Ventana de errores |
| :---: | :---: | ---: | ---: |
| 2 | 1 / 2 / 3 | 5 / 6 / 7 | 0,81 / 0,64 / 0,81 s |
| 1 | 1 / 2 / 3 | 25 / 31 / 36 | **12,8 / 27,6 / 32,0 s** |

- Con 2 réplicas la caída visible es de unos 0,7 s y no cambia entre corridas: es el rezago de kube-proxy en sacar el endpoint del contenedor muerto. Los primeros fallos aparecen ~1,4 s después de pedir el stop (lo que tarda el contenedor en terminar).
- **Con 1 réplica la caída crece a cada crash consecutivo** (12,8 s, 27,6 s, 32,0 s; `restartCount` 3, 4, 4). Es el *backoff exponencial* de kubelet: cuanto más se mata el mismo contenedor, más espera para reiniciarlo (hasta 5 minutos). Por eso la medición de ~3 s de la sección 2 era la de un **primer** crash. Esto es relevante para el requisito de la rúbrica de resistir fallas reiteradas: con 1 réplica, una serie de crashes degrada el servicio cada vez más; con 2 réplicas, la otra absorbe el golpe.

## 5. Camino B: gateway y Users

Mismo método, dos corridas por caso. El gateway se midió por su Service con `GET /api/drug` cada ~1 s (por debajo del rate limit); Users directo en `/health` a ~10 req/s. Registros: `camino-B-*.txt`.

| Servicio | 2 réplicas | 1 réplica |
| --- | --- | --- |
| Gateway | 0 y 0 solicitudes fallidas | 2 (1,0 s) y 6 (10,1 s) |
| Users | 4 (0,17 s) y 5 (0,52 s) | 9 (2,5 s) y 22 (17,7 s) |

El comportamiento se repite en los tres servicios: con 2 réplicas el cliente casi no nota el crash y con 1 réplica la segunda caída consecutiva dura mucho más.

## 6. Camino C: caída de un nodo completo

Se detuvo con `minikube node stop` el nodo donde estaban las 2 réplicas de Pharmacy y se midió desde dentro del clúster (a ~10 req/s). Registros: `camino-C-*.txt`.

| Caso | Corte visible | Qué pasó |
| --- | ---: | --- |
| C1. Sin nodo de repuesto, `podAffinity` **obligatoria** (la del overlay actual) | 130 s | Hasta que el nodo volvió (estuvo 93 s apagado) más ~16 s. Los pods no se movieron. |
| C2. Con un 4.º nodo backend de repuesto, afinidad **obligatoria**, tolerancia por defecto 300 s | **473 s** | **No usó el repuesto.** A los 5 min Kubernetes marcó los pods para eliminar y creó reemplazos, pero quedaron `Pending`: `0/6 nodes are available: ... 3 node(s) didn't match pod affinity rules`. Solo se recuperó cuando volvió el nodo caído. |
| C3. Con repuesto, afinidad **preferida**, tolerancia 30 s | **87 s** | Los 2 pods se reprogramaron juntos en el repuesto; el servicio volvió a +89,5 s con el nodo original todavía caído. |
| C4. Con repuesto, afinidad **preferida**, tolerancia 300 s (por defecto) | 347 s | Mismo comportamiento que C3, pero tras esperar los 300 s de tolerancia (más ~40 s de detección). |

**Hallazgo:** la `podAffinity` obligatoria de cada servicio hacia sí mismo (decisión del overlay `multinode`, que evitaba que un servicio ocupara dos nodos y dejara a otro en `Pending`) **impide que el servicio se cure cuando cae su nodo**, porque los reemplazos solo pueden ir a un nodo que ya tenga un pod del mismo servicio, y ese es el nodo muerto. Con la afinidad **preferida** (peso 100) las réplicas siguen compartiendo nodo en el despliegue normal y pueden ir a otro nodo cuando hace falta. Con 4 nodos backend y afinidad preferida, los tres servicios quedaron cada uno entero en un único nodo y sin pods `Pending`. El tiempo de curación está dominado por la tolerancia de eviction (`tolerationSeconds`, 300 s por defecto, más ~40 s de detección del nodo caído).

**Decisión (12-11-2026, tras consultar al docente):** no se cambian los manifiestos. El docente indicó que la afinidad obligatoria entre réplicas es una restricción poco habitual (las réplicas caen juntas) pero que se deje así, que el ítem de plataforma está cerrado y que todo esto se mencione en el informe como experimentación con affinities, anti-affinities, taints y tolerations. La defensa puede hacerse en Minikube de un nodo. El hallazgo queda como limitación documentada.

Los casos C3 y C4 se hicieron **solo en el clúster de pruebas** (parches con `kubectl patch`), no con los manifiestos del repo, que siguen con afinidad obligatoria. Requieren un nodo backend de repuesto y la imagen cargada en él.

## 7. Camino D: telemetría y `chaos-all` sobre `multinode`

Se encendió la telemetría (Prometheus, Grafana, colector, `node-exporter`, agente de nodo) con **un 6.º nodo dedicado a observabilidad** (`multi-m06`) para no saturar el nodo de SQL Server. Sigue sin UI, Elasticsearch, Kibana ni Fluent Bit.

- **Métricas de todos los nodos:** Prometheus recibió `node-exporter` de los 6 nodos, métricas de CPU de 23 pods, storage por nodo y red (`container_network_*` y `k8s_pod_network_io`) de los 6 nodos y de los pods, y las 8 reglas de Grafana quedaron cargadas.
- **`chaos-all` completo** ([CSV](chaos-run-20261110-230822.csv), alertas en `camino-D-alertas-chaos-all.txt`): las 6 fases terminaron con código 0. Reaccionaron:

| Fase | T0 (UTC) | Alerta | `pending` | `firing` |
| --- | --- | --- | --- | --- |
| requests | 23:08:22 | Rate limiting activo | +25 s | +46 s |
| storage | 23:17:31 | Storage de pod alto | +30 s | +61 s |
| desconexión | 23:21:43 | Servicio caído | +24 s | +34 s |

- **CPU y memoria no dispararon** en esa corrida, y era un defecto: sobre el pod afectado la CPU llegó a 0,534 cores (107 % de su límite) y el working set a 373 MB (93 %), pero las expresiones marcaron 53 % y 46 %, **exactamente la mitad**. Con containerd, `container_spec_*` existe a nivel de pod y a nivel de contenedor, ambos con la etiqueta `pod`, y el filtro `pod!=""` del arreglo anterior sumaba las dos en el denominador. Con Docker (el clúster de la mañana) solo existía la del pod y por eso funcionó. **Corrección:** las tres expresiones de límites usan `pod!="",container=""` (solo la serie a nivel de pod). Sobre los mismos datos da 106,7 % y 92,7 %. Se aplicó y se repitieron los spikes: CPU `firing` a +102 s y memoria a +56 s ([registro](ensayo-multinode-20261110/camino-D-alertas-verificacion-cpu-memoria.txt)). Se revalidó el 12-11 en el clúster con runtime Docker: CPU y memoria disparan (ver [ensayo-defensa-local-20261112.md](ensayo-defensa-local-20261112.md)).
- **Lo que vio un cliente** (sonda continua de ~7800 solicitudes en 21 min, `camino-D-sonda-continua-pharmacy.txt`): ningún fallo en las fases requests, CPU, memoria y storage; **28,9 s de fallos en la fase `red`** (26 solicitudes) y **40,2 s en `desconexión`** (47 solicitudes).
- **`network-cut`:** esta sonda abre una conexión nueva por solicitud, y con eso el corte sí se nota y dura lo que dura la política. Es coherente con la hipótesis de que la política bloquea conexiones nuevas y no las ya establecidas con keep-alive, que son las del gateway y de Prometheus. Ninguna alerta reaccionó en esa fase.

## 8. Qué NO se probó

- El **stack completo** (UI, Elasticsearch, Kibana, Fluent Bit) en `multinode`; los registros en Kibana no se verificaron aquí.
- El 100 % de disponibilidad en **rolling updates** con más de 75 solicitudes por caso y con otros servicios además de Pharmacy.
- Los casos C3 y C4 con los **manifiestos del repo** (se hicieron con parches en el clúster) y la caída del nodo de **Users y del gateway**.
- El efecto de bajar `tolerationSeconds` en nodos que parpadean (puede provocar evicciones innecesarias).
- Tráfico real de clientes con datos de negocio en `multinode` (no se cargó `seed-data.sql` allí).
