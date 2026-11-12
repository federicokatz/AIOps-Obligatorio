# Validación de alertas y scripts de caos (10-11-2026)

Entorno: Minikube de 1 nodo, perfil `pharmago-test` (Docker, CNI Calico, Kubernetes v1.37.0), perfil `local` de `develop` más los cambios de la rama `feature/integracion-final`. Imágenes de backend reconstruidas el mismo día; UI reutilizada. Objetivo del caos: `pharmago-pharmacy-service` (1 réplica; límites 384Mi de memoria y 500m de CPU). Grafana y Prometheus por `kubectl port-forward`. Tiempos en UTC, medidos desde el T0 de cada fase. **Una sola ejecución por prueba y sin datos de negocio cargados** (no se aplicó `seed-data.sql`).

Archivos de apoyo: [CSV de la corrida completa](chaos-run-20261110-193124.csv), [estado de las 8 alertas cada 10 s](chaos-20261110/estado-alertas-cada-10s.txt), capturas en `capturas/20261110-*`.

## 1. Primera validación (pruebas sueltas, por la mañana)

| Falla | Script | Alerta | T0 | `pending` | `firing` | Captura |
| --- | --- | --- | --- | --- | --- | --- |
| Storage (300 MB en `/tmp`) | `volume-spike.sh pharmago-pharmacy-service 300` | Storage de pod alto (>100 MB) | 19:07:22 | +62 s | +104 s | [captura](capturas/20261110-alerta-storage-pod-firing.png) |
| CPU (4 bucles, 100 s) | `cpu-spike.sh pharmago-pharmacy-service 100` | CPU de pod alta (>80 % del límite) | 19:18:07 | +57 s | +91 s | [captura](capturas/20261110-alerta-cpu-firing.png) |
| Memoria (280 MB, 110 s) | `ram-spike.sh pharmago-pharmacy-service 280 110` | Memoria de pod alta (>85 % del límite) | 19:23:46 | +31 s | +56 s | [captura](capturas/20261110-alerta-memoria-firing.png) |

Línea base: las 8 reglas en `Normal` ([captura](capturas/20261110-alertas-baseline-8-reglas.png)). En la captura de storage la alerta de disco del **nodo** ("Disco disponible bajo") sigue en `Normal` mientras la del pod está en `Firing`.

## 2. Corrida completa de `chaos-all.sh`

Comando: `TARGET=pharmago-pharmacy-service PAUSE=110 REQUESTS=500 CPU_SECS=100 RAM_MB=290 RAM_SECS=100 DISK_MB=300 NET_SECS=30 DOWN_SECS=40 sh ./chaos-all.sh`. Las seis fases terminaron con código 0. Alertas registradas cada 10 s con la API de Grafana.

| Fase | T0 (UTC) | Alerta que reaccionó | `pending` | `firing` | Vuelve a `Normal` |
| --- | --- | --- | --- | --- | --- |
| requests (500 POST `/api/login`) | 19:31:24 | Rate limiting activo (429/s) | +26 s | +37 s | 19:33:02 |
| cpu (100 s) | 19:33:29 | CPU de pod alta | +76 s | +96 s | 19:35:36 |
| memoria (290 MB, 100 s) | 19:37:00 | Memoria de pod alta | +19 s | +50 s | 19:39:12 |
| storage (300 MB) | 19:40:35 | Storage de pod alto | +50 s | +81 s | 19:43:28 |
| red (corte de 30 s) | 19:42:27 | **ninguna** | — | — | — |
| desconexión (escala a 0, 40 s) | 19:44:48 | Servicio caído (target down) | +23 s | +43 s | 19:45:42 |

- **Desconexión:** la restauración de la réplica fue a las 19:45:28 y el pod llegó a `READY` a las 19:45:45 (**17 s** tras restaurar, 57 s desde T0). Coherente con los 16 s del 9-11.
- **Efecto cruzado:** la fase de storage también disparó la alerta de memoria (19:41:25 a 19:42:57): el archivo de 300 MB cuenta en el working set como caché de página. Es esperable, pero hay que explicarlo si aparece en la defensa.
- **El tráfico de fondo de esta corrida no sirve** ([registro](chaos-20261110/trafico-fondo-corrida-completa-429.txt)): mis 2 req/s a `/api/drug` agotaron el límite del gateway y casi todo fue `429` (951 de 1450 en las primeras mediciones). La alerta de rate limiting que aparece a las 19:41:46 es consecuencia de ese tráfico y no de una fase del caos. Se conserva por transparencia.

## 3. Experimentos controlados (tráfico por debajo del límite)

Tráfico de fondo a `/api/drug` por el gateway ([registro](chaos-20261110/trafico-controlado-red-y-desconexion.txt)), tras reiniciar el gateway para reponer sus contadores. **Corrección posterior (10-11, tarde):** estos experimentos no tuvieron una sola fuente de tráfico. Mis loops de la corrida completa (2 req/s) nunca se detuvieron (`pkill` no mata procesos en Git Bash de Windows; hubo que usar `kill <PID>`), así que corrían a la vez con los loops de estos experimentos (~3,4 req/s en total). Por eso la mayoría de las respuestas fueron `429`. Lo que se afirma abajo sobre el corte de red se apoya en respuestas `200` y en `up=1`, que no dependen de ese ruido; la medición de continuidad se rehízo limpia en la sección 3b.

**Muerte del contenedor** (`docker kill` desde el nodo, T0 19:52:52): `restartCount` pasó de 0 a 1 (`lastState` con código 137); la alerta "Pod reiniciado" pasó a `firing` a los **+21 s**; "Servicio caído" tuvo un `pending` de ~10 s y no llegó a `firing`. El pod volvió a `READY` de inmediato.

**Corte de red** (`network-cut.sh pharmago-pharmacy-service 40`, 19:55:58 a 19:56:38): **no cortó el tráfico existente.** Durante el corte el cliente recibió `200` en `/api/drug` (19:56:14 a 19:56:30), Prometheus siguió viendo a Pharmacy con `up=1` en las 13 muestras del corte y no disparó ninguna alerta. Explicación probable: la `NetworkPolicy` de Calico solo bloquea conexiones **nuevas**; las conexiones HTTP con keep-alive ya establecidas (gateway → Pharmacy y Prometheus → Pharmacy) siguen pasando. Es una hipótesis: no se verificó con un contador de conexiones. El script cumple con aplicar y retirar la política (y con conexiones nuevas se había observado un `wget` que vencía por timeout, según las notas del 9-11), pero **como inyección de "interrupción de tráfico de red" no es fiable** tal cual está.

**Desconexión con tráfico** (escala a 0 durante 60 s, T0 19:57:24, restaurada 19:58:25, `READY` 19:58:40): el cliente vio `502` x2 (19:57:30 a 19:57:32) y `503` x12 (19:58:14 a 19:58:32, el circuito abierto del gateway); el resto del tiempo recibió `429`, que tapa lo que pasó (ver la corrección arriba y la medición limpia en 3b). Alertas: "Servicio caído" `firing` a +47 s; "Tasa de errores 5xx alta" `pending` a las 19:58:42 y `firing` a las 19:59:03 (+99 s), de nuevo en `Normal` a las 19:59:44. "Pod reiniciado" también pasó a `firing` a las 19:58:01 (y volvió a `Normal` a las 19:58:11), antes de restaurar la réplica; no se investigó la causa, pero indica que esa regla puede disparar en una desconexión sin que haya habido un reinicio de contenedor.

## 3b. Medición limpia de la desconexión (una sola fuente de tráfico)

Sonda finita de 110 solicitudes a ~0,65 req/s ([registro](chaos-20261110/sonda-limpia-desconexion-1-replica.txt)) con todos los loops anteriores detenidos y el gateway reiniciado. `disconnect-component.sh pharmago-pharmacy-service scale 40` (1 réplica de Pharmacy), T0 20:11:24, réplica restaurada 20:12:05.

| Qué ve el cliente | Resultado |
| --- | --- |
| Solicitudes | 110: 83 `200`, 2 `502`, 25 `503` (0 `429`) |
| Primer fallo | 20:11:30, 6 s después de T0 (el pod tarda en terminar) |
| Circuito abierto (503) | desde 20:11:33 |
| Primer `200` de nuevo | 20:12:13, **8 s después de restaurar** la réplica |
| Caída visible | ~43 s (los 40 s apagado más la recuperación) |

Es con **1 réplica de Pharmacy** (perfil `local`), así que el corte coincide con el tiempo apagado. La comparación con 2 réplicas, que es lo que justificaría esa decisión, sigue pendiente.

**Rate limiting verificado a mano** (gateway recién reiniciado, un cliente a ~1 req/s por port-forward, que cae en una sola réplica): 75 solicitudes dieron 67 `200` y 8 `429`, con el **primer `429` en la solicitud #51**. Coincide con el límite configurado de 50 por minuto por réplica. La regla de **500 por hora por réplica** equivale a unas 16 solicitudes por minuto de tráfico sostenido entre las dos réplicas; un cliente que supere eso durante una hora recibe `429` aunque respete el límite por minuto.

## 3c. Pruebas complementarias

**Las 8 expresiones de alerta devuelven datos.** Se tomó cada `expr` directamente del ConfigMap versionado y se ejecutó contra Prometheus: las 8 devuelven series (de 1 a 15 según la regla). Es la comprobación que habría detectado el defecto 1 de la sección 4.

**Alerta de disco del nodo** (`Disco disponible bajo`, <15 % libre). El nodo de pruebas tiene 1 TB con 91 % libre, y la regla toma el **mínimo** entre todos los filesystems no `tmpfs` ni `overlay` (el más bajo en reposo era `/usr/lib/modules`, de 0,1 GB y solo lectura, con 41,8 %). Llenar el 85 % de un disco real no es viable, así que se creó un filesystem **ext4 de 300 MB en el nodo** (archivo de bucle montado en `/mnt/chaos-disk`, `node-exporter` reiniciado para que lo vea) y se llenó con 250 MB: el mínimo bajó a 0,8 % libre y la alerta pasó a `pending` a los +26 s y a `firing` a los +59 s ([captura](capturas/20261110-alerta-disco-nodo-firing.png)). Después se desmontó y se borró. **Es una prueba sintética**: demuestra que la regla y su cableado funcionan, no que un disco real de producción se llene así. Si el filesystem de bucle no se agrega, la alerta del nodo seguiría sin ser alcanzable con los scripts del repo.

**OOM del servicio.** Con el límite de memoria de Pharmacy bajado **solo en el clúster de pruebas** a 72Mi (`kubectl set resources`, sin tocar los manifiestos) y `ram-spike.sh pharmago-pharmacy-service 36 30`: el contenedor del servicio murió por `OOMKilled` (código 137) a las 20:18:43, `restartCount` pasó de 0 a 1 y arrancó de nuevo 1 s después, quedando `READY`. Con el límite real de 384Mi esto no ocurre (el kernel mata el proceso inyectado, que es el mayor): hace falta que lo inyectado sea menor que lo que usa el servicio y que la suma supere el límite, por eso se bajó el límite. Los límites originales (128Mi/384Mi) se restauraron después. No se verificó si "Pod reiniciado" llegó a disparar en este caso.

**Datos de negocio.** `apply-k8s.sh --profile local --seed-data` cargó el `seed-data.sql` del repo sin errores con `sqlcmd` (incluida la versión adaptada para DBeaver). Con eso el login de `admin` devuelve un token (`200`) y `/api/drug` devuelve medicamentos.

## 3d. Stack en reposo (falsos positivos)

30 minutos (20:20 a 20:51 UTC) con el stack completo, datos de negocio cargados y **sin ningún caos**, con tráfico suave de ~7 solicitudes por minuto (un `GET /api/drug` cada 10 s y un login válido por minuto, bien por debajo de los límites del gateway). Registros: [estado de las alertas](chaos-20261110/soak-30min-estado-alertas.txt) cada 10 s y [tráfico](chaos-20261110/soak-30min-trafico.txt).

- **Tráfico:** 180 de 180 `GET /api/drug` con `200` y 30 de 30 logins con `200`.
- **Alertas:** ninguna disparó sola. La única que apareció fue "Pod reiniciado", de 20:20:39 a 20:23:44: es el rastro de mis reinicios previos (el OOM de las 20:18:43 y la recarga del seed), porque esa regla mira una ventana de 5 minutos. Desde las 20:27 las 8 reglas estuvieron en `Normal` el resto de la prueba.
- **Alcance:** una sola observación de 30 minutos con carga mínima. No descarta falsos positivos con carga alta ni en periodos largos; el umbral de memoria (85 %) sigue cerca del uso de SQL Server y Elasticsearch según el plan de contención.

## 4. Defectos encontrados y corregidos

1. **Las alertas de CPU y memoria no podían dispararse (defecto heredado del PR #5).** Usaban `container!=""` también sobre `container_spec_cpu_quota`, `container_spec_cpu_period` y `container_spec_memory_limit_bytes`. En este clúster esas series de límites existen solo a nivel de pod (etiquetas `pod` y `namespace`, sin `container`), así que el denominador quedaba vacío y la regla no tenía datos. Con la expresión original la CPU llegó a 0,49 cores (97 % del límite) y la alerta nunca salió de `Normal`. **Corrección:** el filtro de los límites pasa a `pod!=""`. **Segunda corrección (misma tarde, en un clúster con containerd):** con ese filtro las series de límites a nivel de pod y a nivel de contenedor se sumaban dos veces y las alertas marcaban la mitad del valor real (53 % con la CPU al 107 % del límite). Quedó `pod!="",container=""`, que toma solo la serie a nivel de pod; verificado en `multinode` (ver `ensayo-multinode-20261110.md`, sección 7). Revalidado con runtime Docker el 12-11 (ver `ensayo-defensa-local-20261112.md`).
2. **`ram-spike.sh` (versión anterior) no sostenía el consumo.** Una asignación grande en el shell (`x=$(head ... | tr ...)`) duplica la memoria de forma transitoria: con 300 MB el pico superó el límite de 402 MB, el kernel mató solo el proceso inyectado (exit 137) y el pod siguió `READY` con 0 reinicios. Se reescribió con bloques de 1 MB.
3. **En `bash -c`, si `sleep` es el último comando, bash lo reemplaza con `exec` y libera la memoria al instante.** Se agregó un `echo` final.
4. **Git Bash en Windows convierte los argumentos que empiezan con `/` en rutas de Windows** al llamar a `kubectl.exe`: un `kubectl exec ... rm -f /tmp/chaos_fill` no borró nada. `chaos-all.sh` ahora limpia con `sh -c`. Desde PowerShell no ocurre.
5. **`chaos-all` no permitía fijar la duración del caos de memoria.** Se agregó `RAM_SECS` (`-RamSecs` en PowerShell); con 30 s la alerta de memoria (que necesita sostener el consumo ~50 s) no llega a disparar.

## 5. Qué NO se probó o quedó sin resolver

- **OOM del servicio con el límite real (384Mi).** El caos de memoria no lo provoca: el kernel mata el proceso inyectado. Solo se obtuvo `OOMKilled` del servicio bajando el límite a 72Mi en el clúster de pruebas (sección 3c).
- **Alerta de disco del nodo con un disco real:** solo se probó con un filesystem de prueba de 300 MB (sección 3c); con el disco de 1 TB sigue siendo inalcanzable con los scripts.
- **`network-cut`** como interrupción real de tráfico: ver sección 3. Falta una variante que también corte las conexiones establecidas (por ejemplo, reiniciar la conexión de los clientes o usar otra técnica) y verificar con tráfico.
- **Continuidad percibida por un cliente con 2 réplicas** de Pharmacy: solo se midió con 1 réplica (sección 3b).
- **Cuánto tarda un cliente en ver recuperado el servicio** (el MTTR medido es hasta `READY` del pod, como en el resto del repo).
- Falsos positivos con carga alta o en periodos largos (solo hay 30 minutos de reposo, sección 3d), el comportamiento con 2 réplicas de Users y Pharmacy en el mismo stack, y tráfico real de clientes con datos de negocio.
