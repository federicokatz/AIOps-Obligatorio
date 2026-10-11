# Iteración 04 — Circuit breaker del gateway (solo configuración)

Requisito (rúbrica, Alta disponibilidad): "algún patrón que mitigue la eventualidad de tener un alto volumen de solicitudes fallidas". Continúa el análisis de la [iteración 02](iteracion-02-rate-limiting.md).

## Qué se verificó antes de implementar

La configuración de YARP del gateway (`appsettings.json`) tiene un único destino por cluster (el Service de Kubernetes) y el health check activo existe pero está en `Enabled: false`. Leyendo el código fuente de YARP (GitHub `microsoft/reverse-proxy`, porque la documentación oficial cambió de URL):

- El health check **pasivo** solo cuenta fallas de transporte (conexión, timeouts), **no** respuestas HTTP 500.
- La política por defecto `HealthyOrPanic` sigue enviando tráfico cuando todos los destinos están caídos; con un solo destino nunca corta. `HealthyAndUnknown` sí devuelve 503 sin intentar la conexión.
- El tiempo de reactivación del pasivo nunca baja de `DetectionWindowSize` (60 s por defecto, solo configurable desde código).

## Qué se agregó

- `k8s/configmaps/gateway-resilience.yaml`: `appsettings.Production.json` con `HealthCheck.Active` (sondeo de `/health` cada 3 s, timeout 2 s, 2 fallas consecutivas) y `AvailableDestinationsPolicy: HealthyAndUnknown` para `users-cluster` y `pharmacy-cluster`.
- `k8s/deployments/backend/api-gateway-deployment.yaml`: monta el ConfigMap en `/app/appsettings.Production.json`. Se superpone al `appsettings.json` de la imagen: **sin tocar código ni reconstruir la imagen**. Los perfiles `local` y `multinode` renderizan correctamente.

## Resultados medidos

Escenario: Pharmacy escalado a 0; solicitudes a `/api/drug` por el gateway. Detalle en [`evidencias/circuit-breaker-yarp-20261011.txt`](evidencias/circuit-breaker-yarp-20261011.txt).

| Configuración | Comportamiento con Pharmacy caído | Recuperación |
| --- | --- | --- |
| Sin circuit breaker | 502 en cada solicitud, ~0,88 s cada una | al volver el servicio |
| Pasivo (TransportFailureRate) | 10 × 502 y luego 503 en ~9 ms | ~55 s tras volver el servicio |
| **Activo (elegido)** | 502 durante ~10 s, luego 503 | inmediata (200 a los 43 s; el pod tarda ~14 s en arrancar) |

El 503 inmediato protege al gateway y al backend: no se acumulan conexiones ni hilos esperando un servicio caído, y la falla se comunica rápido a los clientes.

## Limitaciones

- Cubre "servicio **caído**" (el sondeo de `/health` falla). **No** cubre un servicio lento o que responde 500 con `/health` sano, porque `/health` es superficial (ver [contexto-aiops.md](contexto-aiops.md)). Para eso haría falta Polly o una malla de servicios.
- Detección de ~10 s con estos parámetros; se puede reducir bajando `Interval` (a costa de más sondeos).
- Una sola ejecución por escenario; repetir antes del informe.
- El rate limiting sigue siendo por réplica (ver iteración 02): este cambio no lo resuelve.

## Pendiente de verificar por el equipo

- Que la alerta "Servicio caído" de Grafana se dispare en este mismo escenario (no se comprobó).
- Captura de pantalla sugerida para el informe: panel de peticiones por endpoint y Alerting con Pharmacy caído; guardar en `docs/evidencias/capturas/`.

## Uso de IA

Análisis del código de YARP, configuración y pruebas con Claude Code; los resultados salen de ejecuciones reales registradas en `docs/evidencias/`.
