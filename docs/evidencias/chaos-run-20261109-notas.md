# Notas de la corrida chaos-all del 09-11-2026

Datos: [`chaos-run-20261109-121901.csv`](chaos-run-20261109-121901.csv). Entorno: Minikube de un nodo (perfil `local`, driver Docker, CNI Calico), objetivo `pharmago-pharmacy-service`, pausa de 20 s entre fallas.

| Fase | T0 (UTC) | Duración | Observación |
| --- | --- | --- | --- |
| requests | 12:19:01 | 36 s | 500 POST a `/api/login` por el gateway; el script terminó sin error. No se midió la proporción 200/429 en esta corrida. |
| cpu | 12:19:57 | 33 s | Terminó sin error. |
| memoria | 12:20:50 | 11 s | `dd` de 200 MB (cae a `/tmp`: `/dev/shm` mide 64 MB). |
| storage | 12:21:24 | 3 s | 300 MB en `/tmp`. |
| red | 12:21:48 | 31 s | NetworkPolicy aplicada y retirada. |
| desconexion | 12:22:39 | 3 min 32 s | **Fase anómala, ver abajo.** |

## La fase `desconexion` no es un MTTR válido

El pod de Pharmacy no volvió a `READY` en 180 s tras restaurar la réplica, y el script igual imprimió "Recuperado" con código 0 (defecto del script, corregido después: ahora falla si el rollout vence).

Causa encontrada: el plugin CNI de Calico devolvía `error getting ClusterInformation: connection is unauthorized: Unauthorized` y el pod quedaba en `ContainerCreating` (evento `FailedCreatePodSandBox`). El clúster llevaba más de dos días encendido y el token que usa el CNI para hablar con el API server había vencido. Se resolvió reiniciando el DaemonSet `calico-node` (`kubectl delete pod -n kube-system -l k8s-app=calico-node`); después el pod llegó a `Running 1/1`.

**No usar los 3 min 32 s como tiempo de recuperación del sistema**: mide una falla del entorno local, no el self healing. Para el MTTR de la desconexión hay que repetir la fase con el clúster sano.

## Qué sí quedó verificado
- Las seis fases se ejecutan en secuencia y dejan el CSV con T0 y T_fin.
- `network-cut` retiró su política (`kubectl get networkpolicy -n pharmago` → vacío al final).
- Los archivos del caos de RAM y disco y los bucles de CPU se limpian entre fases (probado por separado el 06-11-2026; ver README de `chaos-engineering`).

## Uso de IA
Corrida y análisis hechos con Claude Code sobre el clúster local del equipo.

## Repetición de la desconexión con el clúster sano (09-11-2026)

Después de reiniciar `calico-node`, se repitió la fase `desconexion` tres veces: `disconnect-component.sh pharmago-pharmacy-service scale 30` (escala a 0 durante 30 s y restaura la réplica). Tiempo medido desde que se restaura la réplica hasta que el rollout llega a `READY`.

| Corrida | T0 (UTC) | Réplica restaurada | `READY` | Restauración → `READY` |
| --- | --- | --- | --- | --- |
| 1 | 12:34:10 | 12:34:41 | 12:34:57 | 16 s |
| 2 | 12:34:57 | 12:35:28 | 12:35:44 | 16 s |
| 3 | 12:35:44 | 12:36:15 | 12:36:31 | 16 s |

Las tres terminaron con "Recuperado (READY)". Esto reemplaza al valor anómalo de 3 min 32 s de la corrida de `chaos-all`, que se conserva arriba por transparencia.

Cómo leer los 16 s: incluyen asignar el pod, crearlo, arrancar el proceso .NET y pasar la `startupProbe`/`readinessProbe` (tiempo medido con `kubectl rollout status`, que aproxima por arriba). Es con **una sola réplica** de Pharmacy, así que durante esos segundos más los 30 s de desconexión el servicio no atiende; no mide continuidad de tráfico. Coherente con el rango de 5 a 10 s medido antes para el reinicio de un proceso (ahí el pod ya existía y solo se reinicia el contenedor, sin recrear el pod). Un solo nodo, sin tráfico de fondo durante la prueba.
