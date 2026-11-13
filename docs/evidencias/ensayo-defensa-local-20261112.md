# Ensayo de defensa en Minikube de un solo nodo (12-11-2026)

El docente indicó que la defensa puede hacerse con todo en Minikube de un nodo (perfil `local`). Este ensayo corre `chaos-all` completo sobre ese perfil con los manifiestos de la rama `feature/integracion-final`, mientras se registran las alertas de Grafana y lo que ve un cliente. Registros en [`ensayo-defensa-local-20261112/`](ensayo-defensa-local-20261112/) y [CSV de fases](chaos-run-20261112-131641.csv).

## Entorno y desvíos respecto del repo (leer primero)

- Minikube de **1 nodo**, perfil `pharmago-test`: runtime **Docker**, CNI **Calico**, creado con `--cpus=4 --memory=7000`. Manifiestos aplicados con `apply-k8s.sh --profile local` desde la rama; seed cargado con `--seed-data`.
- **Límites ampliados solo en el clúster, no en los manifiestos del repo:** Elasticsearch a 1,5 CPU y 2Gi (en el repo: 0,5 CPU y 1,5Gi) y colector OTLP a 512Mi (en el repo: 256Mi). Sin eso, Elasticsearch se congelaba (`timer thread slept for [1.3m]`, memoria clavada en su límite de 1,5Gi) tras reiniciar el clúster con ~400 mil logs acumulados, y Kibana reiniciaba. Decisión del equipo: no cambiar los manifiestos por ahora; en la defensa se arranca de cero y no habrá logs acumulados. Esto **no está probado** con el repo tal cual.
- La **vista de datos de Kibana** (`pharmago-logs-*`, campo de tiempo `@timestamp`) se creó a mano; el clúster no la traía.
- Una sola ejecución, con el sistema recién reiniciado y tráfico solo del propio caos. Pharmacy con 1 réplica (perfil `local`).
- Comando: `TARGET=pharmago-pharmacy-service PAUSE=110 REQUESTS=500 CPU_SECS=100 RAM_MB=290 RAM_SECS=100 DISK_MB=300 NET_SECS=30 DOWN_SECS=40 sh ./chaos-all.sh`.

## Resultados

Las 6 fases terminaron con código 0. Alertas registradas cada 10 s ([registro](ensayo-defensa-local-20261112/alertas-cada-10s.txt)):

| Fase | T0 (UTC) | Alerta que reaccionó | `pending` | `firing` | Vuelve a `Normal` |
| --- | --- | --- | --- | --- | --- |
| requests (500 POST `/api/login`) | 13:16:41 | Rate limiting activo | +36 s | +56 s | +86 s |
| cpu (100 s) | 13:18:38 | CPU de pod alta | +61 s | +91 s | +122 s |
| memoria (290 MB, 100 s) | 13:22:08 | Memoria de pod alta | +23 s | +44 s | +114 s |
| storage (300 MB) | 13:25:43 | Storage de pod alto | +72 s | +92 s | +183 s |
| red (corte de 30 s) | 13:27:34 | **ninguna** | | | |
| desconexión (escala a 0, 40 s) | 13:29:55 | Servicio caído | +33 s | +43 s | +63 s |

- **Las expresiones corregidas funcionan con runtime Docker** (`pod!="",container=""`): CPU y memoria dispararon. Antes solo estaban verificadas con containerd.
- **Efecto cruzado:** la fase de storage disparó también la alerta de memoria (de 13:26:45 a 13:28:06): el archivo de 300 MB cuenta en el working set como caché de página.
- **Lo que vio un cliente** (sonda interna continua, ~6000 solicitudes a Pharmacy `/health`, [registro](ensayo-defensa-local-20261112/sonda-continua-pharmacy.txt)): **0 fallos** en las fases requests, cpu, memoria y storage; **28,9 s de fallos (26 solicitudes)** en la fase `red` y **40,1 s (40 solicitudes)** en `desconexión`. Con 1 réplica el corte coincide con lo que dura la falla. La sonda abre una conexión nueva por solicitud, que es lo que bloquea la política de red.
- La alerta "Pod reiniciado" y la de 5xx no se ejercitaron en esta corrida.

## Estado de las 8 alertas (al menos un disparo comprobado cada una)

| Alerta | Dónde se vio disparar |
| --- | --- |
| Servicio caído | esta corrida (+43 s) y `ensayo-multinode-20261110.md` |
| Pod reiniciado | `validacion-alertas-caos-20261110.md`, sección 3 (`docker kill`, +21 s) |
| CPU de pod alta | esta corrida (+91 s) |
| Memoria de pod alta | esta corrida (+44 s) |
| Disco disponible bajo (nodo) | `validacion-alertas-caos-20261110.md`, sección 3c (filesystem de prueba de 300 MB, +59 s; sintético) |
| Storage de pod alto | esta corrida (+92 s) |
| Tasa de errores 5xx alta | `validacion-alertas-caos-20261110.md`, sección 3 (+99 s en una desconexión con tráfico) |
| Rate limiting activo (429/s) | esta corrida (+56 s) |

## Capturas

- [Dashboard "Infra" durante el caos de CPU](capturas/20261112-dashboard-infra-cpu-chaos.png): CPU por pod con el pico de Pharmacy, red por nodo y por pod, memoria por pod y disco del nodo.
- [Dashboard "Overview" con toda la corrida](capturas/20261112-dashboard-overview-chaos-all.png): requests por endpoint, latencia, `429` y throughput.
- [Kibana, logs JSON del gateway](capturas/20261112-kibana-logs-gateway-json.png): `LogLevel`, `Category` y `Message` de las peticiones reales (por ejemplo `HTTP GET /api/drug completed 200`).

## Observaciones para la defensa

- **Logs con correlación y traza:** los logs de peticiones llevan `Scopes[].TraceId`, `SpanId` y `ParentId` (anidados, no de primer nivel) y los eventos de negocio de Users llevan `correlation_id` en `State`.
- **El panel "Tasa de Error por Endpoint (%)" del dashboard Overview supera el 100 %** (362 % de media y 391 % de máximo en `/api/login`). Divide `pharmago_http_errors_total` entre `pharmago_http_requests_total`; si los `429` del rate limiter se rechazan antes de contarse como petición, el numerador supera al denominador. No se investigó el código de las métricas; conviene no mostrar ese panel sin explicarlo.
- **Ruido de logs:** el colector OTLP genera el ~92 % de los logs del namespace (380 mil de 411 mil documentos en 41 h) porque su pipeline de trazas exporta a `debug/traces` con `verbosity: detailed` y las trazas no tienen otro destino. Es parte de la evidencia de trazas del equipo, pero llena Elasticsearch.
- **El colector OTLP opera cerca de su límite de memoria** (94 % de 256Mi tras 41 h encendido): la alerta de memoria disparaba en reposo. Con un arranque limpio es menos probable; conviene reiniciarlo antes de la defensa si lleva días encendido.
- **Arranque en frío pesado:** Elasticsearch y Kibana arrancan a la vez y, con 0,5 CPU para Elasticsearch, pueden tardar o reiniciarse. Dar margen antes de empezar el caos.

## Qué NO se probó

- Los manifiestos del repo tal cual (con los límites originales de Elasticsearch y del colector) bajo la carga de esta corrida.
- Un arranque desde cero (clúster nuevo) con medición del tiempo hasta que todo esté `Ready`.
- La alerta de 5xx y "Pod reiniciado" en el perfil `local` en esta corrida.
- Más de una ejecución, y tráfico real de clientes distinto al del caos.
