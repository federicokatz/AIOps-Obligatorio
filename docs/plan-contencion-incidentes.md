# Plan de contención de incidentes operacionales

Estado: **borrador completo, pendiente de revisión del equipo.** Los playbooks de CPU, memoria, storage, red y desconexión se contrastaron con los scripts de caos el 09-11-2026 en Minikube de un solo nodo (evidencia en `docs/evidencias/chaos-run-20261109-notas.md`, rama `feature/chaos-scripts`). Falta validar el flood con `load-requests.sh` y la caída de la base de datos.

Este plan cubre el ítem "Plan de contención de incidentes operacionales" de la rúbrica. Está pensado para usarse en vivo durante el war-room de la defensa: dice qué mirar, quién decide y qué ejecutar. Se apoya en lo ya implementado (probes, self healing, circuit breaker, rate limiting, alertas de Grafana).

> **Dependencia:** varias alertas y mecanismos citados (las 7 reglas de Grafana, el circuit breaker YARP, las 2 réplicas del gateway con rate limit dividido) están hoy en la rama `feature/rate-limiting` y **no en `develop`**. Este plan asume que esa rama se integra antes de la defensa. Si no se integra, hay que ajustar las secciones marcadas con ⚠.

## 1. Alcance

- **Sistema:** PharmaGo en Kubernetes (namespace `pharmago`): UI → API Gateway (YARP) → Users / Pharmacy → SQL Server, más la pila de observabilidad (Prometheus, Grafana, OTLP Collector, Fluent Bit, Elasticsearch, Kibana).
- **Incidentes cubiertos** (los seis tipos de falla de la letra): sobrecarga de requests, CPU, memoria, storage, interrupción de red y desconexión de componentes internos.
- **Fuera de alcance:** fallas de lógica de negocio, caída de un nodo completo, pérdida de datos de SQL Server, ataques de seguridad más allá de la inyección de volumen.

## 2. Ciclo de gestión

Se sigue el ciclo visto en la clase 5. Cada fase tiene su resultado esperado y dónde se implementa en este proyecto.

| Fase | Objetivo | En este proyecto |
| --- | --- | --- |
| **Prepare** | Que el equipo y el sistema estén listos antes del incidente. | Probes, réplicas, límites de recursos, rate limiting, circuit breaker, alertas, dashboards, scripts de caos, este plan. Checklist previo en la sección 6. |
| **Detect** | Enterarse rápido y con evidencia. | 7 reglas de Grafana (`pharmago-operacion`, evaluación cada 10 s), dashboards "PharmaGo - Overview" e "Infra", logs JSON en Kibana, trazas por correlation id. |
| **Respond** | Contener el impacto y estabilizar. | Mecanismos automáticos (Kubernetes, YARP) y acciones manuales del playbook correspondiente. |
| **Recover** | Volver al estado normal y comprobarlo. | Criterios de recuperación por playbook (pods `READY`, alerta en `Normal`, `/health` respondiendo, tráfico sin 5xx). |
| **Learn** | Que no se repita y quede registrado. | Postmortem (sección 7) y evidencia en `docs/evidencias/`. |

## 3. Severidades

Los umbrales siguen las alertas ya definidas. **Son una propuesta del equipo, no un SLO fijado por el docente**: se ajustan con los resultados del caos.

| Sev | Criterio (medible) | Ejemplo | Respuesta esperada |
| --- | --- | --- | --- |
| **SEV1 — crítico** | Los usuarios no pueden operar: alerta "Servicio caído" activa para el gateway o para dos o más servicios; o 5xx > 5 % sostenido más de 1 minuto. | Gateway sin réplicas `READY`; Users y Pharmacy caídos a la vez. | Se asume el rol de comandante de inmediato; todas las acciones se registran; objetivo: contener en minutos. |
| **SEV2 — alto** | Degradación visible pero el sistema sigue atendiendo: un servicio de backend caído (el circuit breaker responde 503), recursos de un pod > 85 % de su límite, o rate limiting activo de forma sostenida. | Pharmacy caído; CPU de un pod al 100 % de su límite; flood de requests con 429. | Diagnóstico y acción del playbook; seguimiento hasta que la alerta vuelva a `Normal`. |
| **SEV3 — bajo** | Señal temprana sin impacto en usuarios: un reinicio de pod que se autocuró, disco del nodo bajo el 15 % sin errores, un pico breve de 429. | "Pod reiniciado" disparada y el pod ya está `READY`. | Registrar, vigilar y revisar la causa; sin acción urgente. |

Regla de escalamiento: si una SEV2 no mejora en 5 minutos, o se suma una segunda falla, se trata como SEV1.

## 4. Roles para la defensa

El equipo es de tres personas. En un incidente real o en el war-room se asignan estos roles antes de empezar la ejecución del caos. Un integrante puede cubrir más de un rol si hace falta, pero el comandante no debería ejecutar comandos.

| Rol | Responsabilidad | Herramientas |
| --- | --- | --- |
| **Comandante** | Declara la severidad, decide qué acción tomar y cuándo, y comunica el estado. Es el único que ordena cambios. | Ninguna en particular; sigue el playbook. |
| **Operador** | Ejecuta los comandos de diagnóstico y contención que ordena el comandante. | `kubectl`, scripts del repo. |
| **Observador / escriba** | Vigila Grafana y Kibana, registra la línea de tiempo (hora de inyección, detección, acción, recuperación) y guarda evidencia. | Grafana, Prometheus, Kibana, `docs/evidencias/`. |

Asignación para la defensa (propuesta; el equipo puede cambiarla):

| Rol | Integrante | Motivo |
| --- | --- | --- |
| Comandante | Timoteo López | Coordina el plan, decide y comunica; no ejecuta comandos. |
| Operador | Juan Manuel Vergara | Autor del self healing, rate limiting y circuit breaker; conoce los comandos de `kubectl` y los manifiestos del gateway. |
| Observador / escriba | Federico Katz | Autor de la telemetría y los dashboards; conoce Grafana, Prometheus y Kibana. |

Como la defensa puede incluir preguntas individuales, los tres deben conocer los tres roles: en los ensayos conviene **rotarlos** para que cualquiera pueda cubrir a otro.

Línea de tiempo mínima a registrar en cada incidente: `T0` inyección o inicio, `T1` detección (alerta o síntoma), `T2` primera acción, `T3` contención, `T4` recuperación verificada. De ahí salen MTTD (T1 − T0) y MTTR (T4 − T0).

## 5. Playbooks por tipo de falla

Cada playbook tiene los mismos campos. Convenciones:

- Namespace `pharmago`. Deployments: `pharmago-api-gateway`, `pharmago-users-service`, `pharmago-pharmacy-service`, `pharmago-ui`. Los pods llevan la etiqueta `app=<deployment>`.
- Accesos locales con `k8s/port-forward.sh`: gateway `5000`, Prometheus `9090`, Grafana `3000`, Kibana `5601`.
- **Estado de validación** de cada playbook: **Probado** (hay evidencia en `docs/evidencias/`), **Parcial** (algo medido, algo supuesto) o **A validar** (diseñado sobre la configuración, aún no ejecutado). Se actualiza cuando se corran los scripts de caos.
- Tras cada contención, el observador registra T0–T4 (sección 4).

### 5.1 Sobrecarga de requests (flood)

**Estado:** Parcial. Probado: rate limiting dividido (100/min efectivos con 2 réplicas) y disparo de la alerta de 429 (`pending` a los 16 s, `firing` a los 32 s). No probado: flood con `load-requests.sh` y usuarios distintos. ⚠ Depende de `feature/rate-limiting`.

| Campo | Contenido |
| --- | --- |
| **Falla / inyección** | `chaos-engineering/load-requests.sh [N]` lanza N POST a `/api/login` en paralelo. |
| **Síntoma** | Respuestas 429 en el gateway; latencia creciente; si el backend se satura, 5xx. |
| **Detección** | Alerta "Rate limiting activo (429/s)" (> 1/s, 15 s). Si degrada: "Tasa de errores 5xx alta". Dashboard Overview: tasa de requests y códigos HTTP. |
| **Qué hace el sistema solo** | El gateway rechaza con 429 el exceso (50 solicitudes/min por réplica, 5/min en login). Si un backend cae, YARP corta con 503 (ver 5.6). |
| **Diagnóstico** | 1) Gateway: `kubectl get pods -n pharmago -l app=pharmago-api-gateway`. 2) Proporción 429/200/5xx en Grafana. 3) Origen del tráfico en Kibana (campo de IP/ruta de los logs del gateway; confirmar nombre del campo al probar). 4) Descartar que el backend esté degradado (5.2 y 5.3). |
| **Contención** | Si el rate limit alcanza: **no hacer nada** y vigilar que 5xx se mantenga bajo 5 %. Si hay 5xx por saturación: escalar el backend afectado (`kubectl scale deploy/<nombre> -n pharmago --replicas=2`) y, si el flood es de un origen identificable, bloquearlo fuera del clúster (no hay mecanismo interno). |
| **Recuperación** | Alerta 429 en `Normal`, 5xx < 5 %, pods `READY`, una solicitud normal a `/api/drug` devuelve 200. |
| **Humano vs. automático** | Automático: el rechazo con 429. Humano: decidir si hay que escalar o bloquear origen. |
| **Límites conocidos** | El límite es aproximado entre réplicas (kube-proxy reparte al azar) y un reinicio de pod reinicia sus contadores. Probado desde una sola IP. |

### 5.2 Sobrecarga de CPU

**Estado:** Probado. Con `cpu-spike.sh` la CPU del pod pasó de 0,02 a 0,46 cores (~93 % del límite de 0,5), medido en Prometheus. Defecto del script: deja sus 4 bucles corriendo al terminar; hay que matarlos o reemplazar el pod (`chaos-all` ya los limpia). No se confirmó el disparo de la alerta en Grafana en esta tanda (las alertas viven en `feature/rate-limiting`).

| Campo | Contenido |
| --- | --- |
| **Falla / inyección** | `chaos-engineering/cpu-spike.sh [deployment] [segundos]` ejecuta 4 bucles ocupados dentro del pod. |
| **Síntoma** | CPU del pod pegada al límite (500m); latencia mayor; el contenedor es limitado (throttling), no reiniciado. |
| **Detección** | Alerta "CPU de pod alta (% del límite)" (> 80 %, 30 s). Panel "CPU por pod" del dashboard Infra. |
| **Qué hace el sistema solo** | El límite de CPU acota el daño a ese pod y al nodo. Kubernetes **no** reinicia por CPU alta. Si la liveness `/health` no responde a tiempo (timeout 2 s, 3 fallos), el pod se reinicia. |
| **Diagnóstico** | 1) Qué pod: panel de CPU por pod. 2) `kubectl top pod -n pharmago` (⚠ la Metrics API no está disponible en este clúster; usar Grafana). 3) Latencia y 5xx del servicio afectado. 4) Si hay réplicas, ver si el resto absorbe el tráfico. |
| **Contención** | Eliminar el pod afectado para que el Deployment lo reemplace: `kubectl delete pod <pod> -n pharmago`. Con réplicas (gateway) no hay corte; con 1 réplica hay una ventana de recuperación de unos segundos. Si la carga es real y sostenida, escalar réplicas. |
| **Recuperación** | Alerta en `Normal`, pod nuevo `READY`, latencia normal. |
| **Humano vs. automático** | Automático: el límite de CPU y, eventualmente, el reinicio por liveness. Humano: reemplazar el pod o escalar. |
| **Límites conocidos** | Con una sola réplica en users y pharmacy, borrar el pod implica corte breve. El MTTR medido del reinicio de un proceso fue de 5,2 a 10,05 s. |

### 5.3 Sobrecarga de memoria

**Estado:** Parcial. `/dev/shm` mide solo 64 MB: con 200 MB pedidos el `dd` falla y el resto cae a `/tmp` (disco). El working set subió de 32 a 183 MB, en gran parte por caché de página; no se llegó al límite de 384Mi ni a un OOM. Para presionar el límite de verdad hace falta otra técnica (un proceso que reserve RAM).

| Campo | Contenido |
| --- | --- |
| **Falla / inyección** | `chaos-engineering/ram-spike.sh [deployment] [MB]` escribe MB en `/dev/shm` (o `/tmp` si falla). |
| **Síntoma** | Memoria del pod subiendo hacia 384Mi; si la supera, el contenedor es terminado por OOM y reiniciado. |
| **Detección** | Alerta "Memoria de pod alta (% del límite)" (> 85 %, 30 s). "Pod reiniciado" si hubo OOM. Panel "Memoria por pod". |
| **Qué hace el sistema solo** | Al superar el límite, el kernel mata el contenedor y kubelet lo reinicia (`OOMKilled`, código 137); readiness lo saca del tráfico mientras tanto. |
| **Diagnóstico** | 1) `kubectl describe pod <pod> -n pharmago` y buscar `Last State: Terminated, Reason: OOMKilled`. 2) `restartCount`. 3) Tendencia de memoria en Grafana (¿fuga o pico?). |
| **Contención** | Pico puntual: esperar la recuperación automática. Fuga repetida: reemplazar el pod, reducir tráfico y, como medida temporal, subir el límite de memoria del Deployment (cambio de manifiesto que requiere PR). |
| **Recuperación** | Pod `READY`, memoria bajo 85 %, alerta en `Normal`, contador de reinicios estable. |
| **Humano vs. automático** | Automático: terminación por OOM y reinicio. Humano: decidir si es fuga y ajustar límites. |
| **Límites conocidos** | Elasticsearch y SQL Server ya usaban ~63 % de su límite en reposo (cerca del umbral del 85 %): riesgo de falso positivo. |

### 5.4 Sobrecarga de storage

**Estado:** Parcial, desalineación confirmada. El script escribe el archivo, pero la alerta mide el disco **del nodo** (< 15 %) y el nodo de prueba tenía ~92,6 % libre (933 GB de 1007 GB): 300 MB no la disparan. Falta alertar sobre uso por contenedor o fijar un límite de `ephemeral-storage`.

| Campo | Contenido |
| --- | --- |
| **Falla / inyección** | `chaos-engineering/volume-spike.sh [deployment] [MB]` escribe un archivo de MB en `/tmp` del contenedor. |
| **Síntoma** | Menos espacio en el filesystem del contenedor/nodo; con espacio agotado, errores de escritura y posible desalojo (eviction) del pod. |
| **Detección** | Alerta "Disco disponible bajo" (< 15 %, 30 s) sobre `node_filesystem_avail_bytes`. Métrica por contenedor: `container_fs_usage_bytes` (panel de storage del dashboard Infra). |
| **Qué hace el sistema solo** | Kubelet puede desalojar pods por presión de disco del nodo. Los manifiestos **no definen límite de `ephemeral-storage`**, así que no hay contención específica por pod. |
| **Diagnóstico** | 1) Panel de storage por pod y por nodo. 2) `kubectl describe node` (condición `DiskPressure`). 3) `kubectl exec <pod> -n pharmago -- df -h /tmp` para ver el uso. |
| **Contención** | Borrar el archivo generado o reemplazar el pod (`kubectl delete pod <pod> -n pharmago`, el filesystem del contenedor se recrea). Si el disco lleno es de Elasticsearch o Prometheus (volúmenes persistentes), reducir retención o ampliar el volumen. |
| **Recuperación** | Disco disponible > 15 %, alerta en `Normal`, sin condición `DiskPressure`, pod `READY`. |
| **Humano vs. automático** | Automático: eviction por presión de disco. Humano: limpiar o reemplazar, y definir límites de `ephemeral-storage` (mejora propuesta). |
| **Límites conocidos** | Sin límite por pod, un solo pod puede afectar a otros del mismo nodo. Falta alinear alerta y script (probar con un tamaño que llegue al umbral o alertar sobre `container_fs_usage_bytes`). |

### 5.5 Interrupción de tráfico de red

**Estado:** Parcial. Existe el script `network-cut` (rama `feature/chaos-scripts`) y se probó con **Calico**: `wget` al `/health` pasó de `Healthy` a `timed out` durante el corte y volvió al restaurar. Con el CNI por defecto de Minikube no se probó (puede no tener efecto). No existe alerta específica; no se midió la reacción del circuit breaker ante el corte.

| Campo | Contenido |
| --- | --- |
| **Falla / inyección** | `chaos-engineering/network-cut.sh [deployment] [segundos]` aplica una `NetworkPolicy` de denegación total (ingress y egress) sobre el servicio y la retira al terminar (`restore` la retira a mano). ⚠ Requiere que el CNI del clúster haga cumplir las políticas; en Minikube con CNI por defecto puede no hacerlo. Verificar antes de la defensa; alternativa: `kubectl exec ... iptables` o escalar a 0 el Service destino. |
| **Síntoma** | Timeouts o 502/503 en el gateway hacia el servicio aislado; el pod sigue `Running` y su `/health` local responde. |
| **Detección** | **Sin alerta directa.** Señales indirectas: "Tasa de errores 5xx alta"; "Servicio caído" si el scrape de Prometheus también queda bloqueado; caída de las métricas de red del pod (panel de red del dashboard Infra). |
| **Qué hace el sistema solo** | El circuit breaker del gateway (sondeo activo de `/health` cada 3 s, 2 fallos) corta con 503 tras ~10 s en vez de acumular conexiones. Las probes de Kubernetes no distinguen la partición si el chequeo se hace dentro del pod. |
| **Diagnóstico** | 1) `kubectl get networkpolicy -n pharmago`. 2) Probar conectividad desde otro pod: `kubectl exec <pod-gateway> -n pharmago -- wget -qO- --timeout=2 http://<servicio>/health`. 3) Correlacionar errores de conexión en Kibana con el trace id. |
| **Contención** | Retirar la política (`kubectl delete networkpolicy <nombre> -n pharmago`) o corregir la causa. Mientras tanto el circuit breaker protege al gateway. |
| **Recuperación** | El gateway vuelve a sondear con éxito `/health`; las solicitudes dejan de devolver 503; 5xx bajo 5 %. Se midió que tras volver un servicio caído, la recuperación del gateway fue inmediata (200 a los 43 s en total, incluyendo el arranque del pod). |
| **Humano vs. automático** | Automático: 503 rápido por circuit breaker. Humano: detectar la causa de red y restaurarla. |
| **Brecha a cubrir** | Agregar una alerta (por ejemplo, error de conexión upstream o caída brusca del tráfico de red por pod) y medir la reacción del circuit breaker con el corte aplicado. El script ya existe. |

### 5.6 Desconexión o caída de un componente interno

**Estado:** Probado en parte. Probado: 9/9 recuperaciones de proceso (5,22 a 10,05 s), circuit breaker con Pharmacy a 0 réplicas (502 durante ~10 s y luego 503; recuperación inmediata al volver), y alerta "Servicio caído" en `Firing` (captura "Firing for 40s"). Además, con `disconnect-component.sh` (escala a 0 por 30 s y restaura) el servicio volvió a `READY` **16 s** después de restaurar, 3 de 3 veces, con una réplica y un solo nodo (la primera corrida dio 3 min 32 s por un token vencido de Calico, falla del entorno y no del self healing; se conserva en las notas). ⚠ Circuit breaker y alerta dependen de `feature/rate-limiting`. No probado: caída de SQL Server o de Users.

| Campo | Contenido |
| --- | --- |
| **Falla / inyección** | Previsto: escalar a 0 (`kubectl scale deploy/<nombre> -n pharmago --replicas=0`), borrar el pod, o detener el contenedor desde CRI como en `k8s/measure-self-healing.ps1`. |
| **Síntoma** | 502 y luego 503 en el gateway para las rutas del servicio caído; el resto del sistema sigue respondiendo. |
| **Detección** | Alerta "Servicio caído (target down)" (`up < 1`, 15 s) y "Pod reiniciado". Dashboard Overview. |
| **Qué hace el sistema solo** | Kubernetes recrea el pod (self healing); readiness lo mantiene fuera del tráfico hasta estar listo; el circuit breaker YARP responde 503 inmediato mientras el servicio no está sano. El gateway tiene 2 réplicas (no es punto único de falla). |
| **Diagnóstico** | 1) `kubectl get pods -n pharmago` y `kubectl describe pod <pod> -n pharmago` (eventos, probes). 2) `kubectl logs <pod> -n pharmago --previous`. 3) `kubectl rollout status deploy/<nombre> -n pharmago`. 4) Si la caída es de SQL Server: revisar el pod de la base y su volumen persistente. |
| **Contención** | Si el pod no se recupera: `kubectl rollout restart deploy/<nombre> -n pharmago` (rolling update, sin corte para el gateway). Si el último despliegue causó la falla: `kubectl rollout undo deploy/<nombre> -n pharmago`. Si fue escalado a 0 por error: volver a `--replicas=1`. |
| **Recuperación** | Deployment `READY` (1/1 o 2/2), `/health` responde `Healthy`, alerta en `Normal`, solicitudes con 200. |
| **Humano vs. automático** | Automático: recreación del pod y circuit breaker. Humano: solo si el pod no vuelve (imagen rota, dependencia caída, escalado manual). |
| **Límites conocidos** | `/health` es superficial: no detecta que SQL Server esté caído. Con 1 réplica en users y pharmacy hay una ventana de 5 a 10 s sin servicio. Un servicio lento o que responde 500 con `/health` sano no activa el circuit breaker. |

## 6. Preparación (checklist previo)

Antes de ejecutar un caos o de la defensa, el observador confirma cada punto y guarda la salida como evidencia.

- [ ] Clúster arriba y pods `READY`: `kubectl get pods -n pharmago` (backends, UI, base de datos, Prometheus, Grafana, Elasticsearch, Kibana, collector).
- [ ] Réplicas esperadas: gateway 2/2 ⚠ (depende de `feature/rate-limiting`); users y pharmacy según el perfil desplegado.
- [ ] Perfil correcto aplicado (`local` o `multinode`) y, en `multinode`, servicios en nodos distintos: `kubectl get pods -n pharmago -o wide`.
- [ ] Accesos abiertos con `k8s/port-forward.sh`: Grafana (3000), Prometheus (9090), Kibana (5601), gateway (5000).
- [ ] Targets de Prometheus en `up` (Status → Targets).
- [ ] Las 7 reglas de Grafana cargadas, en `Normal` y con salud `ok` ⚠.
- [ ] Dashboards "PharmaGo - Overview" e "Infra" abiertos y mostrando datos.
- [ ] Logs visibles en Kibana, con un trace id de prueba que se pueda seguir entre servicios.
- [ ] Una solicitud normal responde 200 (por ejemplo, `/api/drug` por el gateway).
- [ ] Scripts de caos presentes y probados en seco; saber cómo revertir cada uno (borrar archivo, retirar `NetworkPolicy`, volver a `--replicas`).
- [ ] Roles asignados (sección 4) y reloj común para registrar T0–T4.
- [ ] Carpeta de evidencia creada en `docs/evidencias/` para la ejecución.

## 7. Postmortem

Se completa después de cada incidente real o ejercicio de caos, idealmente dentro de las 24 horas, sin buscar culpables.

```
# Postmortem — <título corto>
Fecha: __   Severidad: SEV_   Duración (T4 − T0): __
Responsables: comandante __ / operador __ / observador __

## Resumen
Qué pasó y qué impacto tuvo en una o dos frases.

## Línea de tiempo (UTC)
| Hora | Evento |
| T0 | inyección / inicio |
| T1 | detección (alerta o síntoma) |
| T2 | primera acción |
| T3 | contención |
| T4 | recuperación verificada |

## Métricas
MTTD (T1 − T0): __   MTTR (T4 − T0): __
Solicitudes fallidas durante el incidente: __ (fuente: Grafana / Kibana)

## Causa
Causa directa y causa raíz (separar lo medido de lo supuesto).

## Qué funcionó / qué falló
- Detección: ¿saltó la alerta esperada? ¿cuánto tardó?
- Mecanismos automáticos: ¿actuaron como se esperaba?
- Respuesta humana: ¿el playbook alcanzó?

## Acciones correctivas
| Acción | Responsable | Fecha | Estado |

## Evidencia
Enlaces a CSV, capturas y logs en `docs/evidencias/`.
```

Los postmortems de ejercicios de caos se guardan en `docs/evidencias/` junto con los datos de la corrida y se enlazan desde `docs/contexto-aiops.md`.

## 8. Limitaciones

Para el informe y la defensa. Este plan y sus mecanismos tienen estos límites; separar siempre lo medido de lo supuesto.

- **Validación incompleta.** De los seis playbooks solo el de caída de componente tiene evidencia sólida. CPU, memoria, storage y corte de red están por validar con los scripts de caos; sus comandos y umbrales son de diseño.
- **Minikube local ≠ nodos físicos.** Un clúster Minikube multinodo en una sola computadora demuestra separación entre nodos de Kubernetes, no entre máquinas físicas distintas.
- **`/health` es superficial.** No verifica SQL Server ni dependencias; un 200 no prueba que las operaciones funcionen. La caída de la base no se detecta por probes.
- **Circuit breaker acotado.** Cubre un servicio caído (falla el sondeo de `/health`), no uno lento o que devuelve 500 con `/health` sano. Detecta en ~10 s con los parámetros actuales ⚠.
- **Rate limiting aproximado.** Contador en memoria por réplica, con el límite dividido entre réplicas; un reinicio de pod pone los contadores en cero y, si cae una réplica, el cupo efectivo baja a la mitad ⚠.
- **Una sola réplica en users y pharmacy** (según el perfil): hay una ventana de recuperación de unos 5 a 10 s con corte para los clientes.
- **MTTR medido con `kubectl`.** Los 5,22 a 10,05 s aproximan por arriba el tiempo hasta `READY` y no miden continuidad de tráfico para clientes. Corresponden a fallas aisladas de proceso.
- **Sin notificaciones.** Las alertas de Grafana no tienen contact point: el plan supone que el observador está mirando el panel.
- **Brechas de cobertura.** No hay alerta ni script para el corte de red; la alerta de disco mide el nodo y no el pod; no hay límite de `ephemeral-storage`.
- **Umbrales y severidades** son propuestas del equipo, a ajustar con los resultados del caos para evitar falsos positivos (p. ej. Elasticsearch y SQL Server usan ~63 % de su límite de memoria en reposo).
- **Alcance excluido:** caída completa de un nodo, pérdida de datos de SQL Server y ataques más allá del volumen de solicitudes.

## 9. Uso de IA

Borrador redactado con Claude Code a partir de la letra, `docs/objetivo-obligatorio.md`, `docs/contexto-aiops.md`, los manifiestos de `k8s/`, los scripts de `chaos-engineering/` y las reglas de alerta de `feature/rate-limiting`. No se leyó código de negocio. Los umbrales y roles son propuestas a revisar y validar por el equipo con ejecuciones reales.
