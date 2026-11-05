# Iteración 03 — Alertas en Grafana

Requisito (rúbrica, Telemetría): al menos 5 alertas en Grafana para detección de anomalías de las métricas definidas. Estado inicial medido el 11-10-2026: **0 reglas** (`/api/v1/provisioning/alert-rules` devolvía `[]`).

## Qué se agregó

- `k8s/configmaps/grafana-alert-rules.yaml`: ConfigMap con 7 reglas, grupo `pharmago-operacion`, evaluación cada 10 s.
- `k8s/deployments/ops/grafana-deployment.yaml`: monta el ConfigMap en `/etc/grafana/provisioning/alerting/alert-rules.yml`.

| Regla | Condición | `for` | Falla que cubre |
| --- | --- | --- | --- |
| Servicio caído | `up{job=~"api-gateway\|users-service\|pharmacy-service"} < 1` | 15 s | proceso caído, desconexión de componentes |
| Pod reiniciado | `changes(container_start_time_seconds[5m]) > 0` | 0 s | self healing en acción, crash repetido |
| CPU de pod alta | uso / límite de CPU > 80 % | 30 s | caos de CPU |
| Memoria de pod alta | working set / límite > 85 % | 30 s | caos de memoria, riesgo de OOM |
| Disco disponible bajo | mínimo de `node_filesystem_avail` < 15 % | 30 s | caos de storage |
| Tasa de 5xx alta | 5xx / total > 5 % | 30 s | fallas reiteradas |
| Rate limiting activo | 429/s > 1 | 15 s | alto volumen de solicitudes |

Las expresiones se validaron antes contra Prometheus y ninguna estaba disparada en estado normal. No existe `kube-state-metrics`, por eso los reinicios se detectan con `container_start_time_seconds`.

## Verificación (11-10-2026, Minikube de un nodo)

- Grafana carga las 7 reglas, todas con salud `ok` e `inactive` en reposo.
- Disparo real de la regla de 429: carga sostenida de ~50 s desde un pod del clúster al gateway. La regla pasó `inactive` → `pending` (t+16 s) → `firing` (t+32 s).
- Las demás reglas **no se han disparado todavía**: se validarán con los scripts de caos (CPU, memoria, storage, caída de pods).

## Incidencia durante el despliegue

La primera versión del ConfigMap tenía una expresión con comillas sin escapar y Grafana entró en `CrashLoopBackOff` ("failed to parse file alert-rules.yml"). El Grafana anterior siguió sirviendo gracias al RollingUpdate; se corrigió el YAML y se eliminó el pod defectuoso (los montajes `subPath` no se actualizan solos).

## Limitaciones

- Las alertas no tienen canal de notificación (contact point): solo se ven en Grafana. Falta definir el destino si el plan de incidentes lo requiere.
- Los umbrales son iniciales; ajustar con los resultados del caos para evitar falsos positivos.
- Elasticsearch y SQL Server usan ~63 % de su límite de memoria en reposo, cerca del umbral del 85 %.

## Uso de IA

Reglas y documentación generadas con Claude Code; las expresiones se probaron contra el Prometheus del clúster y el disparo de la alerta de 429 se observó en la API de Grafana.
