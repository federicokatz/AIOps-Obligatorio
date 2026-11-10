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
| `network-cut` | **Funciona con Calico para conexiones nuevas; no corta las ya establecidas (10-11-2026).** Con tráfico por el gateway durante el corte el cliente recibió `200` y Prometheus siguió viendo `up=1` (hipótesis: las conexiones keep-alive existentes no se ven afectadas por la política). **Decisión del equipo (10-11-2026): documentarlo como limitación y usar `disconnect-component` para la desconexión de componentes.** Como inyección de "interrupción de red" no es fiable sin una variante que también las corte, ver [validación](../../../docs/evidencias/validacion-alertas-caos-20261110.md). Antes: `wget` al `/health` del servicio: `Healthy` antes, `timed out` durante el corte, `Healthy` al restaurar. La política se crea y se borra sola. Con el CNI por defecto de Minikube no se probó (puede no tener efecto). | Salida de la prueba (T0 00:01:04Z, fin 00:01:30Z) |
| `disconnect-component` modo `scale` | **Funciona.** 0 réplicas durante 15 s; `READY` de nuevo ~31 s después de bajar (incluye arranque del pod). | T0 00:01:39Z, READY 00:02:10Z |
| `disconnect-component` modo `pod` | **Funciona.** El pod se recrea y vuelve a `READY`. | Probado 00:02:10Z |
| `cpu-spike` | **Medido (09-11) y revalidado (10-11-2026):** CPU del pod 0,02 → 0,49 cores (~97-100 % del límite de 0,5); al terminar el script la CPU vuelve a reposo (0,03 cores), o sea que ya no deja bucles. La alerta de CPU dispara a +91 s (con la corrección de la expresión, ver validación). | [validación del 10-11](../../../docs/evidencias/validacion-alertas-caos-20261110.md) |
| `ram-spike` | **Reescrito y validado el 10-11-2026:** `ram-spike.sh [deployment] [MB] [segundos]` reserva memoria residente por bloques de 1 MB con `bash`. Con 280 MB en Pharmacy el pod se sostuvo en ~87-88 % del límite de 384Mi y la alerta de memoria disparó a +56 s, sin reinicios. **Con el límite real de 384Mi no provoca `OOMKilled` del servicio:** el kernel mata el proceso inyectado (exit 137) y el contenedor no se reinicia. Con el límite bajado a 72Mi solo en un clúster de pruebas y `ram-spike.sh <deployment> 36 30` sí hubo `OOMKilled` y reinicio en 1 s (ver validación). | [validación del 10-11](../../../docs/evidencias/validacion-alertas-caos-20261110.md) |
| `volume-spike` | **Escribe el archivo, pero no dispara la alerta de disco del nodo.** El nodo tiene ~92,6 % de disco libre (933 GB de 1007 GB): 300 MB no mueven el umbral de 15 %. **Agregada el 10-11-2026** la alerta `pharmago-pod-storage-high` (capa escribible por pod > 100 MB, métrica `container_filesystem_usage`): **validada**, dispara a +104 s con 300 MB mientras la del nodo sigue en `Normal`. | `df` y consulta a Prometheus |
| `load-requests` | **Se ejecuta sin error** (500 POST a `/api/login`, 36 s). **No se midió** la proporción de respuestas 200 y 429. | `docs/evidencias/chaos-run-20261109-121901.csv` |
| `chaos-all` | **Las seis fases corrieron en secuencia** el 09-11-2026 y dejaron el CSV con T0 y T_fin. La fase `desconexion` de esa corrida no es válida (falla de Calico, ver notas). Repetida con el clúster sano: `READY` 16 s después de restaurar, 3 de 3 veces. | [CSV](../../../docs/evidencias/chaos-run-20261109-121901.csv) y [notas](../../../docs/evidencias/chaos-run-20261109-notas.md) |
| `chaos-all` (10-11-2026) | **Corrida completa validada** con el stack actual: las 6 fases terminaron con código 0 y reaccionaron las alertas de rate limiting, CPU, memoria, storage por pod y servicio caído (la fase `red` no disparó ninguna). Desconexión: `READY` 17 s tras restaurar. Nuevo parámetro `RAM_SECS` / `-RamSecs`. | [CSV](../../../docs/evidencias/chaos-run-20261110-193124.csv) y [validación](../../../docs/evidencias/validacion-alertas-caos-20261110.md) |

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
