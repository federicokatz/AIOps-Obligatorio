# Contexto compartido del obligatorio AIOps

Este archivo es el punto de partida para las siguientes iteraciones del equipo. Antes de trabajar, leer `AGENTS.md`: la exploración de lógica de negocio .NET y del frontend Angular está restringida. Registrar aquí decisiones, evidencia y próximos pasos sin repetir una inspección general del template.

## Rúbrica y secuencia acordada

| Elemento (5 puntos cada uno) | Estado al 26-09-2026 | Próxima evidencia necesaria |
| --- | --- | --- |
| Plataforma Kubernetes | Desplegada en Minikube de un nodo; cada microservicio en su propio pod. | Diagrama y separación de nodos Kubernetes. |
| Alta disponibilidad | Una réplica por microservicio y probes iniciales. En curso: self healing y MTTR. | Medición de recuperación; después, protección frente a fallas reiteradas y solicitudes fallidas. |
| Despliegues seguros | RollingUpdate implícito en los tres deployments backend; sin prueba de disponibilidad continua. | Técnica documentada y prueba de reemplazo bajo tráfico. |
| Telemetría | Prometheus, Grafana, OTLP Collector, Fluent Bit, Elasticsearch y Kibana desplegados. Prometheus recolecta métricas de aplicación directamente y del collector. | Verificar flujo OTLP, métricas de pod/nodo, logs/trazas y cinco alertas. |
| Detección de anomalías | Pendiente. | Isolation Forest y SVM RBF sobre datasets docentes. |
| Contención de incidentes | Pendiente. | Runbook y ejercicios operacionales. |
| Scripts de caos | Diferidos hasta ver ingeniería de caos en clase. | Cubrir las seis clases de falla indicadas en la letra. |
| Defensa | Pendiente. | War room con telemetría, respuesta y explicación causal. |

Orden de trabajo: **self healing y MTTR** → rate limiting y solicitudes fallidas → separación de nodos y despliegues seguros → telemetría y alertas → plan de incidentes → detección de anomalías → informe y defensa. Los scripts de caos se retoman después de la clase correspondiente. El informe final debe cubrir cada elemento de la rúbrica en un máximo de diez páginas; entrega única por Gestión y productos versionados en GitHub.

## Arquitectura y línea base

- Clúster: contexto `minikube`, Kubernetes v1.37.0, un nodo `minikube` sobre WSL2. Gateway, Users y Pharmacy son Deployments separados, cada uno con una réplica en ese nodo.
- Tráfico: UI → API Gateway → Users/Pharmacy → SQL Server. Los servicios de observabilidad se despliegan en el mismo clúster. `k8s/port-forward.sh` expone localmente UI 4200, gateway 5000, Users 5001, Pharmacy 5002, Prometheus 9090, Grafana 3000 y Kibana 5601.
- Snapshot antes de esta iteración (26-09-2026, UTC): gateway `READY`, 2 reinicios, proceso iniciado 22:45:18 y `READY` 22:45:37; Pharmacy `READY`, 2 reinicios, 22:45:18 → 22:45:40; Users `READY`, 4 reinicios, 22:45:50 → 22:46:17. Estos tiempos corresponden al reinicio reciente del nodo, no a una prueba controlada de MTTR. Users registró una salida anterior con código 139; investigar si reaparece.
- Probes originales: gateway TCP; Users y Pharmacy HTTP `/health`. Gateway usaba startup cada 10 s tras 15 s, readiness cada 10 s y liveness cada 30 s tras 60 s. Los otros dos usaban intervalos equivalentes con `/health`. `AddHealthChecks()` de Users y Pharmacy no agrega verificaciones de dependencias.
- Rate limiting existente: API Gateway en modo IP, 100 solicitudes/minuto y 1000/hora, con contadores en memoria. No inferir que funcionará igual con varias réplicas; probarlo en su iteración.
- Estado observado de Elasticsearch y Kibana: ambos llegaron a `READY` tras el arranque; el `0/1` visto inicialmente era transitorio. La Metrics API de Kubernetes no está disponible (`kubectl top` falla); Prometheus tiene configuración de cAdvisor y node-exporter que debe verificarse para la evidencia de infraestructura.

Con una réplica por servicio, Kubernetes puede reiniciar un proceso y devolver su pod a `READY`, pero durante esa recuperación puede haber interrupción para clientes. El script de port forwarding tampoco es un instrumento fiable para medir disponibilidad durante el reinicio del pod al que quedó conectado.

## Decisiones de la primera iteración

- Añadir `/health` superficial al gateway y convertir sus probes TCP a HTTP. La liveness de los tres servicios comprueba el proceso HTTP; no consulta base de datos ni servicios vecinos, para evitar reinicios en cascada.
- Probes iniciales: startup `/health` cada 5 s, timeout 2 s, hasta 36 fallos (180 s); readiness cada 3 s, timeout 2 s, un fallo; liveness cada 5 s, timeout 2 s, tres fallos. Reevaluar ante falsos positivos.
- Medir tres fallas aisladas por microservicio con `k8s/measure-self-healing.ps1`. El script confirma que PID 1 es `dotnet`, detiene el contenedor exacto desde CRI, espera un nuevo container ID y `READY`, y reemplaza el pod entre intentos para reiniciar el backoff de kubelet. La duración medida es desde la inyección hasta observar `READY` mediante consultas a Kubernetes: aproxima por arriba el MTTR real y **no** mide continuidad de tráfico.
- La letra pide reducir el MTTR al mínimo posible, idealmente al orden de pocos segundos; **no fija un umbral numérico**. Los 30 s usados en el plan inicial fueron una referencia provisoria propuesta para esta primera medición, no un criterio del docente. Evaluar la recuperación automática en los nueve intentos, comparar los tiempos y seguir reduciéndolos.

### Resultado medido (26-09-2026)

Comando: `& 'Implementacion K8S/Codigo/k8s/measure-self-healing.ps1' -Trials 3 -TimeoutSeconds 180` desde la raíz del repo en PowerShell. CSV: [`evidencias/self-healing-20260926-230325.csv`](evidencias/self-healing-20260926-230325.csv). Cada fila conserva el pod, timestamps UTC de inyección, pérdida y recuperación observadas, contadores de reinicio y código de salida 137.

| Servicio | Intentos | Tiempos hasta observar `READY` (s) | Promedio (s) | Máximo (s) |
| --- | ---: | --- | ---: | ---: |
| API Gateway | 3/3 recuperados | 6,11; 8,87; 8,93 | 7,97 | 8,93 |
| Users | 3/3 recuperados | 8,68; 10,05; 10,03 | 9,59 | 10,05 |
| Pharmacy | 3/3 recuperados | 5,22; 5,25; 5,23 | 5,23 | 5,25 |

En los nueve intentos se observó `NotReady`, aumentó `restartCount` de 0 a 1, cambió el container ID y volvió `READY`. Los tres deployments quedaron `1/1`; los tres `/health` respondieron `Healthy` a través del proxy de Kubernetes. Se midieron entre 5,22 y 10,05 s **para fallas aisladas de proceso en este nodo**; estos números son la evidencia para discutir cuánto se acercan a “pocos segundos”. El script reemplazó el pod entre intentos para evitar el backoff acumulado; una secuencia rápida de fallas repetidas requiere otra prueba. Estos resultados no prueban disponibilidad continua para clientes, recuperación ante caída del nodo ni recuperación de dependencias.

## Limitaciones y decisiones pendientes

- El equipo ampliará Minikube local más adelante. Varios nodos de Minikube en una sola computadora demuestran separación entre nodos Kubernetes, pero no cumplen literalmente “nodos físicos” distintos de la rúbrica. Explicitarlo en el informe.
- `/health` es superficial: un 200 no prueba conectividad con SQL Server ni éxito de operaciones de negocio. Las fallas de dependencias se cubrirán con telemetría y el plan de incidentes.
- No ejecutar `apply-k8s.ps1` para esta iteración: su limpieza de PVs no es necesaria. Aplicar solo los tres deployments backend tras cargar la nueva imagen del gateway.
- Conservar los cambios preexistentes en `Backend/seed-data.sql`, `AGENTS.md` y la letra del obligatorio.

## Registro de iteraciones

| Fecha | Cambio o prueba | Resultado y evidencia | Próximo paso |
| --- | --- | --- | --- |
| 26-09-2026 | Inspección acotada de letra, manifiestos y clúster. | Línea base de arriba; clúster de un nodo. | Validar, desplegar y medir self healing. |
| 26-09-2026 | Build Docker del gateway y rollout secuencial de los tres servicios. | Build sin advertencias; los tres deployments llegaron a `READY`; `/health` del gateway respondió `Healthy` a través del proxy de Kubernetes. | Ejecutar la medición controlada. |
| 26-09-2026 | Primer intento de inyección con `kubectl exec ... kill -KILL 1`. | No cambió el container ID ni aumentó `restartCount`; se canceló la medición. | Usar `crictl stop` desde el nodo y registrar el resultado. |
| 26-09-2026 | Nueve fallas aisladas desde CRI. | [CSV](evidencias/self-healing-20260926-230325.csv); 9/9 recuperadas, máximo 10,05 s. | Planificar y probar rate limiting y fallas repetidas, sin extrapolar estos resultados a disponibilidad continua. |

Agregar una fila por iteración y enlazar desde aquí cada CSV o informe de evidencia generado. No reemplazar resultados fallidos por una conclusión sin registro.
