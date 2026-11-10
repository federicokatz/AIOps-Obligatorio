# Iteración 02 — Rate limiting y solicitudes fallidas (análisis)

Estado: **análisis documental, sin cambios de código ni de manifiestos.** Fuentes: `tutoriales/rate-limit/`, `Backend/RATE_LIMITING_GUIDE.md`, `Backend/MICROSERVICES_MIGRATION_SUMMARY.md`, `k8s/README-k8s.md`, `chaos-engineering/README.md` y el deployment del gateway. No se leyó código C#.

## Requisito de la rúbrica (Alta disponibilidad)

> "El sistema debe ser resiliente a ataques que inciten fallas reiteradas. Se debe implementar algún patrón que mitigue la eventualidad de tener un alto volumen de solicitudes fallidas."

## Lo que existe hoy

- Rate limiting en el API Gateway, con tres modos en `appsettings.json`: `IP`, `User` y `Disabled`. Valores por defecto: 100 solicitudes/min y 1000/h.
- Un script de prueba (`tutoriales/rate-limit/test-rate-limit.sh`): 120 GET a `/api/drug` por `127.0.0.1:5000`, espera ~100 respuestas 200 y ~20 respuestas 429.
- Scripts de caos que generan carga (`chaos-engineering/load-requests.sh`).
- El gateway corre con `replicas: 1`.
- **No hay circuit breaker.** `MICROSERVICES_MIGRATION_SUMMARY.md` lo lista como mejora futura ("Implementar Polly").

## Conclusiones

1. **Los contadores son por réplica.** La guía describe contadores en memoria. Con N réplicas del gateway el límite efectivo pasa a ser hasta N× el configurado, y un reinicio de pod (el self healing de la iteración 01) pone los contadores en cero. Es una suposición a verificar con una prueba, no un hecho medido.
2. **El límite por IP puede ser inútil dentro de Kubernetes.** La propia guía advierte que si el tráfico llega desde el servidor del frontend o un balanceador, todos los clientes comparten una IP. Con `kubectl port-forward` tampoco sirve para repartir carga, porque queda pegado a un solo pod.
3. **Rate limiting y fallas son cosas distintas.** El rate limiting corta por *volumen* de solicitudes, sin importar si fallan. Lo que pide la rúbrica es mitigar muchas solicitudes *fallidas*; el patrón adecuado es un circuit breaker, que hoy no existe.
4. **Afinar el límite por usuario obliga a tocar código.** `como-tunear-rate-limit.md` indica que el modo `User` tiene los límites duplicados en una constante de `UserRateLimitMiddleware.cs`, además del JSON. El modo `IP` se puede ajustar solo con configuración.
5. **El script de prueba actual no mide lo importante.** Envía 120 solicitudes secuenciales: no prueba concurrencia, varias réplicas ni el efecto sobre la disponibilidad.

## Opciones (sin tocar lógica de negocio)

| Opción | Cubre | Costo / riesgo |
| --- | --- | --- |
| A. Ajustar `RateLimiting`/`IpRateLimiting` en `appsettings.json` y desplegar ≥2 réplicas | Rate limiting con límites explícitos | Solo configuración, pero queda el límite por réplica y no hay circuit breaker. |
| B. Ingress NGINX delante del gateway (addon `minikube addons enable ingress`) con anotaciones `limit-rps` / `limit-connections` | Límite común a todas las réplicas del gateway, tráfico filtrado antes de llegar a los pods | Hay que verificar cómo se ve la IP del cliente y la memoria disponible en Minikube. |
| C. Health checks pasivos de YARP (`HealthCheck.Passive` en la configuración del cluster) | Aproxima un circuit breaker por configuración | Hay que **verificar en la documentación de YARP** cómo se comporta con un único destino (Service de K8s) y qué responde cuando no quedan destinos sanos. |
| D. Malla de servicios (Istio/Linkerd) con `outlierDetection` y `connectionPool` | Circuit breaker real a nivel de infraestructura | Alto consumo de memoria; el clúster local ya pide 6 GB. |
| E. Polly en el gateway | Circuit breaker de aplicación | Requiere editar C#; hoy contradice la regla del `CLAUDE.md` y necesita excepción explícita. |

## Recomendación

Combinar **B + C**: ingress con límite compartido y health checks pasivos de YARP, ambos por configuración. Dejar **D** y **E** como plan de respaldo si C no alcanza. Antes de decidir:

1. Leer la configuración de YARP del gateway (`appsettings.json`) y la documentación oficial de health checks pasivos de YARP.
2. Medir el comportamiento actual con 2 réplicas para confirmar la conclusión 1.

## Pendientes y preguntas abiertas

- `appsettings*.json` del gateway es configuración y la regla actualizada de `CLAUDE.md` permite leerla: es el primer paso de la iteración.
- Definir cómo se prueba una "falla reiterada": inyectar errores con un script de caos (por ejemplo, detener o cortar Users) mientras `load-requests.sh` genera tráfico, y registrar códigos 5xx y 429 más el tiempo de recuperación.
- Evidencia a guardar en `docs/evidencias/` cuando se ejecute cualquier prueba.

## Uso de IA

Análisis y redacción asistidos por Claude Code (lectura de documentación del repo y síntesis). Las conclusiones están marcadas como hipótesis cuando no se verificaron; hay que revisarlas y medirlas antes de incluirlas en el informe.

## Resultados medidos (11-10-2026, Minikube de un nodo)

Configuración: modo IP, 100 solicitudes/min y 1000/h, valores por defecto. Evidencia en `docs/evidencias/rate-limit-*.txt`.

| Prueba | Réplicas del gateway | Solicitudes | 200 | 429 |
| --- | ---: | ---: | ---: | ---: |
| Línea base (`test-rate-limit.sh`, vía port-forward) | 1 | 120 | 100 | 20 |
| Desde un pod del clúster, vía Service, contadores en cero | 2 | 120 | 120 | 0 |
| Ídem | 2 | 250 | 200 | 50 |

**Conclusión 1 confirmada:** con 2 réplicas el límite efectivo pasó de 100 a ~200 solicitudes/min, es decir, N × el valor configurado, porque cada réplica lleva su propio contador. Caveat: todas las solicitudes salieron de un mismo pod (misma IP de origen) y el reparto entre réplicas lo hace kube-proxy; la prueba es de una sola ejecución por caso.

Otros hallazgos:
- Grafana tiene **0 reglas de alerta** definidas (API `/api/v1/provisioning/alert-rules` devuelve `[]`); la rúbrica pide al menos 5.
- El dashboard "PharmaGo - Overview" muestra "No data" en los paneles de 429 hasta que el gateway rechaza solicitudes: sirve para validar el rate limiting en las próximas pruebas.
- El gateway se devolvió a 1 réplica (`kubectl scale`) para no dejar divergencia entre el clúster y los manifiestos.
