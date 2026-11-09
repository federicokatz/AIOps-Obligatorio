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

Probado el 06-11-2026 en Minikube de **un nodo** (perfil `local`, driver Docker, CNI **Calico**), contra el microservicio `pharmago-pharmacy-service`. Las alertas de Grafana no estaban cargadas en esta rama, así que el efecto se verificó con consultas a Prometheus.

| Script | Resultado | Evidencia |
| --- | --- | --- |
| `network-cut` | **Funciona con Calico.** `wget` al `/health` del servicio: `Healthy` antes, `timed out` durante el corte, `Healthy` al restaurar. La política se crea y se borra sola. Con el CNI por defecto de Minikube no se probó (puede no tener efecto). | Salida de la prueba (T0 00:01:04Z, fin 00:01:30Z) |
| `disconnect-component` modo `scale` | **Funciona.** 0 réplicas durante 15 s; `READY` de nuevo ~31 s después de bajar (incluye arranque del pod). | T0 00:01:39Z, READY 00:02:10Z |
| `disconnect-component` modo `pod` | **Funciona.** El pod se recrea y vuelve a `READY`. | Probado 00:02:10Z |
| `cpu-spike` | **Funciona, con un defecto.** CPU del pod: 0,02 → 0,46 cores (~93 % del límite de 0,5). **El script deja sus 4 bucles corriendo al terminar** (sigue en ~0,50 cores minutos después); `chaos-all` los mata en su limpieza. | Consultas a Prometheus |
| `ram-spike` | **Funciona solo parcialmente.** `/dev/shm` mide 64 MB; con más de 64 MB el `dd` falla y escribe el resto en `/tmp` (disco, no memoria). El working set subió de 32 a 183 MB con 200 MB pedidos, en gran parte por caché de página. Para presionar de verdad el límite de 384Mi hace falta otra técnica. | Consultas a Prometheus |
| `volume-spike` | **Escribe el archivo, pero no dispara la alerta de disco.** El nodo tiene ~92,6 % de disco libre (933 GB de 1007 GB): 300 MB no mueven el umbral de 15 %. | `df` y consulta a Prometheus |
| `load-requests` | **Se ejecuta sin error** (500 POST a `/api/login`, 36 s). **No se midió** la proporción de respuestas 200 y 429. | `docs/evidencias/chaos-run-20261109-121901.csv` |
| `chaos-all` | **Las seis fases corrieron en secuencia** el 09-11-2026 y dejaron el CSV con T0 y T_fin. La fase `desconexion` de esa corrida no es válida (falla de Calico, ver notas). Repetida con el clúster sano: `READY` 16 s después de restaurar, 3 de 3 veces. | [CSV](../../../docs/evidencias/chaos-run-20261109-121901.csv) y [notas](../../../docs/evidencias/chaos-run-20261109-notas.md) |

Puntos abiertos:

- **Storage:** para disparar "Disco disponible bajo" habría que alertar sobre uso por contenedor (`container_fs_usage_bytes`, que existe en Prometheus pero no devolvió series con el filtro `namespace="pharmago"`) o fijar un límite de `ephemeral-storage` por pod.
- **Memoria:** una presión real sobre el límite requiere ocupar RAM con un proceso que la reserve (no `dd` a `/dev/shm`).
- **Desconexión de la base (`pharmago-db`)**: no probada.
- **`chaos-all.ps1`** necesita `sh` (Git Bash o WSL) para los scripts base, que solo existen en `.sh`.
- Un solo nodo: no demuestra separación entre nodos físicos.

## Ver el impacto

Grafana: dashboard "PharmaGo - Infra" → paneles "CPU por pod (pharmago)" y "Memoria por pod (pharmago)". Las alertas y la respuesta esperada de cada falla están en el [plan de contención](../../../docs/plan-contencion-incidentes.md) (PR en revisión).

## Uso de IA

Scripts redactados con Claude Code. Revisión y pruebas a cargo del equipo.
