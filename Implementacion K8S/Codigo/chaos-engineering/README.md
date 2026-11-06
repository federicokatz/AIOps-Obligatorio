# Chaos Engineering

Requiere: app en K8s + `kubectl` con acceso al cluster. Para `load-requests.sh` y `chaos-all` también el port-forward del gateway (`k8s/port-forward.sh`, puerto 5000).

Cubre las seis fallas que pide la letra:

| Falla | Script | Uso |
|-------|--------|-----|
| Inyección de requests | `load-requests.sh` | `./load-requests.sh [N] [url]` |
| Sobrecarga de CPU | `cpu-spike.sh` | `./cpu-spike.sh [deploy] [seg]` |
| Sobrecarga de memoria | `ram-spike.sh` | `./ram-spike.sh [deploy] [MB]` |
| Sobrecarga de storage | `volume-spike.sh` | `./volume-spike.sh [deploy] [MB]` |
| Interrupción de red | `network-cut.sh` / `.ps1` | `./network-cut.sh [deploy] [seg\|restore]` |
| Desconexión de componente | `disconnect-component.sh` / `.ps1` | `./disconnect-component.sh [deploy] [scale\|pod] [seg]` |
| Las seis en secuencia | `chaos-all.sh` / `.ps1` | `./chaos-all.sh` (variables `TARGET`, `PAUSE`, etc.) |

Default deploy de los scripts base: `pharmago-api-gateway`. Los scripts nuevos y `chaos-all` usan `pharmago-pharmacy-service`.

## Scripts nuevos

- **`network-cut`**: aplica una `NetworkPolicy` de denegación total (ingress y egress) sobre el deployment, espera N segundos y la retira. `restore` la retira a mano. Se restaura también con Ctrl+C.
- **`disconnect-component`**: modo `scale` escala a 0 durante N segundos y devuelve las réplicas originales; modo `pod` borra los pods para medir el self healing.
- **`chaos-all`**: ejecuta requests → CPU → memoria → storage → red → desconexión, con pausa entre fallas para observar la recuperación, y guarda `docs/evidencias/chaos-run-<fecha>.csv` con T0 y T_fin de cada fase. Limpia los archivos que dejan los spikes de RAM y disco.

## Estado de validación

Estos scripts **se escribieron sin un clúster disponible y no se ejecutaron**. Falta probarlos; hasta entonces no hay evidencia de su efecto.

Puntos a verificar al probarlos:

- **`network-cut` depende del CNI.** Una `NetworkPolicy` solo se aplica si el CNI la soporta. Con el CNI por defecto de Minikube puede no tener efecto. Probar con `minikube start --cni=calico` y comprobar el corte, por ejemplo:
  `kubectl exec -n pharmago <pod-gateway> -- wget -qO- --timeout=2 http://pharmago-pharmacy-service/health`.
- **Storage:** `volume-spike` llena `/tmp` del pod, pero la alerta "Disco disponible bajo" mide el disco del nodo (< 15 %); con 300 MB puede no dispararse. Ajustar el tamaño o la alerta.
- **Memoria:** confirmar que la escritura en `/dev/shm` cuenta contra el límite de memoria del contenedor (384Mi).
- **Desconexión de la base (`pharmago-db`)**: probar el modo `pod`; el modo `scale` también aplica, pero el volumen persistente puede demorar el arranque.
- **`chaos-all.ps1`** necesita `sh` (Git Bash o WSL) para los scripts base, que solo existen en `.sh`.

## Ver el impacto

Grafana: dashboard "PharmaGo - Infra" → paneles "CPU por pod (pharmago)" y "Memoria por pod (pharmago)". Las alertas y la respuesta esperada de cada falla están en el [plan de contención](../../../docs/plan-contencion-incidentes.md) (PR en revisión).

## Uso de IA

Scripts redactados con Claude Code. Revisión y pruebas a cargo del equipo.
