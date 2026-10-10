# Objetivo del obligatorio AIOps

Resumen para agentes y equipo. Fuente: letra "Obligatorio AIOps.docx" (raíz del repo) y notas de clase 0–5. Ante discrepancias, manda la letra.

## Foco

Experimentar con herramientas técnicas para **mejorar la respuesta a incidentes**, partiendo de un proyecto existente (PharmaGo: .NET + Angular + SQL Server, API Gateway YARP + microservicios Users y Pharmacy). **No se desarrolla funcionalidad de negocio**: se trabaja sobre el despliegue, la resiliencia, la telemetría, la contención de incidentes, el caos y la detección de anomalías. Los agentes **no deben leer código C# ni Angular** (ver [CLAUDE.md](../CLAUDE.md)).

## Datos de entrega

- Entrega: **16/11/2026 21:00** en gestion.ort.edu.uy (zip/rar/pdf, máx. 40 MB). Todo versionado en GitHub.
- **Defensa: 23/11/2026**, obligatoria y eliminatoria; war-room con script de caos provisto por los docentes.
- Puntaje: 8 ítems × 5 = 40; mínimo para aprobar 40 según la letra (la letra dice "máximo: 0", error de tipeo). Equipo de 3 personas (la letra menciona 3 y también 2 en otro lugar: confirmar con el docente si surge duda).
- Informe: una sección por elemento de la rúbrica (desafíos y resultados), **máximo 10 páginas**.
- IA generativa: permitida como apoyo; hay que **citar herramienta y contexto de uso**, revisar todo y poder defenderlo. El docente puede convocar a defensa individual.

## Rúbrica (5 puntos cada una)

| Ítem | Resultado esperado |
| --- | --- |
| Implementación de plataforma | Sobre Kubernetes; cada microservicio en un pod independiente; **microservicios en nodos físicos distintos**; diagrama de despliegue. |
| Alta disponibilidad | Autocuración tras errores en runtime (volver a READY) y MTTR mínimo (idealmente pocos segundos; la letra no fija un número). Patrón que mitigue alto volumen de solicitudes fallidas (rate limiting, circuit breaker, etc.). |
| Despliegues seguros | Reemplazo de componentes con 100 % de disponibilidad; técnica documentada y explicada (rolling, blue/green, canary…). |
| Telemetría | Logs JSON estructurados; trazas OTLP; métricas de pod/contenedor y nodo (CPU, memoria, storage, red) vía OTLP → Prometheus → Grafana; logs en Kibana/Elasticsearch; **mínimo 5 alertas** en Grafana. |
| Detección de anomalías | **Isolation Forest** y **SVM con kernel RBF** sobre datasets que entregan los docentes. |
| Plan de contención | Plan/runbook de mitigación de incidentes operacionales (ciclo Prepare-Detect-Respond-Recover-Learn de la clase 5). |
| Scripts de caos | Al menos un script que cubra: inyección de requests, CPU, memoria, storage, corte de red y desconexión de componentes internos. |
| Defensa | Ejecutar el caos, mostrar efectos con telemetría y respuesta del sistema; explicar por qué los mecanismos garantizan lo observado. |

Tecnologías indicadas: GitHub (tableros, repos, CI/CD), Cypress + Cucumber (BDD), .NET/Angular, Grafana, OTLP, Prometheus. Extras de pipeline suman para compensar áreas débiles.

## Qué se vio en clase (resumen)

- **0–1**: DevOps, métricas DORA, qué es AIOps, MTTD/MTTR/MTBF, telemetría y atributos de calidad.
- **2**: arquitecturas resilientes (ISO 25010, SLA/SLO/SLI, backoff exponencial, rate limiting, circuit breaker, YARP, self-healing).
- **3**: Kubernetes self-healing: control loops, Pods/Deployments/Services, probes (startup/readiness/liveness), scheduling (taints, affinity), estrategias de despliegue y rollback.
- **4**: logs estructurados y correlación por trace id, métricas con PromQL, dashboards y alertas en Grafana.
- **5**: gestión de incidentes (playbooks, severidad, postmortem) y Bash para chaos engineering.
- Falta aún (según el calendario): ingeniería de caos formal y detección de anomalías con ML.

Notas completas del curso: carpeta de Obsidian `AIOps/` (fuera del repo).

## Orden de trabajo acordado

Self healing y MTTR → rate limiting / circuit breaker → separación de nodos y despliegues seguros → telemetría y alertas → plan de incidentes → detección de anomalías → informe y defensa. Scripts de caos tras la clase correspondiente.

## Estado y ramas

Ver el análisis de ramas más reciente en la conversación/PR; resumen al 10/10/2026:

- `develop`: perfiles `local` y `multinode` (Kustomize + `configure-nodes`), CI de GitHub Actions (build/tests .NET, build Angular, validación de manifiestos). Aún **sin** los cambios de self-healing.
- `codex/self-healing` (no mergeada): probes HTTP `/health` en los tres servicios, `measure-self-healing.ps1`, CSV con 9/9 recuperaciones (5,2–10,05 s), `docs/contexto-aiops.md`.
- Pendiente: rate limiting multi-réplica / circuit breaker, múltiples réplicas, despliegue seguro, alertas, anomalías, runbook, caos, diagrama.

## Limitaciones a explicitar en el informe

- Minikube multinodo local demuestra separación entre nodos de Kubernetes, **no** nodos físicos distintos.
- `/health` es superficial (no verifica SQL Server ni dependencias).
- El MTTR medido por `kubectl` aproxima por arriba y no mide continuidad de tráfico para clientes.
