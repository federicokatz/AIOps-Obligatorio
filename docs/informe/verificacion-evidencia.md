# Verificación de la evidencia contra el informe

Las cifras de las secciones nuevas del informe se recalcularon desde los registros crudos de `docs/evidencias` y los manifiestos de `k8s/`, con el script [`verificar_evidencia.py`](verificar_evidencia.py) (`python docs/informe/verificar_evidencia.py`). No se confió en lo escrito en los documentos: cada cifra se recalcula.

**Resultado: 42 de 42 comprobaciones coinciden.**

## Hallazgos de la verificación

1. **Una discrepancia real, ya corregida.** Las ventanas de error del camino A (crash de contenedor de Pharmacy) se habían calculado sumando 0,12 s a cada una, y las del camino B no. Se unificó el criterio (tiempo entre la primera y la última solicitud fallida) y se corrigieron las cifras: con 2 réplicas, 0,69 / 0,52 / 0,69 s (antes 0,81 / 0,64 / 0,81) y con 1 réplica 12,7 / 27,5 / 31,9 s (antes 12,8 / 27,6 / 32,0). No cambia ninguna conclusión. El documento afectado (`docs/evidencias/ensayo-multinode-20261110.md`) quedó corregido y publicado.
2. **Tres afirmaciones sin registro crudo.** Solo están escritas en `validacion-alertas-caos-20261110.md`, sin un log que las respalde: el primer `429` en la solicitud 51, la alerta de pod reiniciado a los 21 s y la alerta de 5xx a los 99 s. Son ciertas según lo observado en su momento, pero no se pueden recalcular. Conviene repetirlas guardando el registro si se quieren citar como evidencia firme.
3. **Una falla del propio verificador**, corregida: en una primera versión incluía `kustomization.yaml` al revisar los parámetros del rolling update y marcaba una discrepancia que no era tal.

## Comprobaciones

| Estado | Afirmación | Valor recalculado | Fuente |
| --- | --- | --- | --- |
| OK | 9 fallas, 9 recuperaciones, 5,2 a 10,1 s | 9 filas, min 5.22 s, max 10.05 s | `self-healing-20260926-230325.csv` |
| OK | readiness cada 3 s/1 fallo; liveness cada 5 s/3 fallos (3 servicios) | coincide | `k8s/deployments/backend/*.yaml` |
| OK | RollingUpdate maxUnavailable 0, maxSurge 1, minReadySeconds 10, grace 45 s, preStop 5 s (4 componentes) | coincide | `k8s/deployments/**` |
| OK | rate limit por replica: 5/min login, 50/min general, 500/h | coincide | `configmaps/gateway-resilience.yaml` |
| OK | health check activo cada 3 s, timeout 2 s, 2 fallos | coincide | `configmaps/gateway-resilience.yaml` |
| OK | breaker: 502 hasta ~10 s, 503 inmediato, 200 a los 43 s (incluye ~14 s de arranque) | coincide | `circuit-breaker-yarp-20261011.txt` |
| OK | con 2 replicas el total efectivo es 100/min (ok200=100) | 4 corridas con ok200=100 de 4 | `rate-limit-dividido-20261011.txt` |
| OK | crash Pharmacy, 2 replicas: ventana 0,69 / 0,52 / 0,69 s (ultimo menos primer fallo) | 0.69 s (5 fallidas), 0.52 s (6 fallidas), 0.69 s (7 fallidas) | `camino-A-2rep-*.txt` |
| OK | crash Pharmacy, 1 replica: 12,7 / 27,5 / 31,9 s (crece) | 12.7 s (25 fallidas), 27.5 s (31 fallidas), 31.9 s (36 fallidas) | `camino-A-1rep-*.txt` |
| OK | gateway: 2 replicas 0 y 0 fallidas; 1 replica 2 (1,0 s) y 6 (10,1 s) | 2rep [0, 0]; 1rep [(2, 1.0), (6, 10.1)] | `camino-B-gw-*.txt` |
| OK | Users: 2 replicas 4 (0,17 s) y 5 (0,52 s); 1 replica 9 (2,5 s) y 22 (17,7 s) | 2rep [(4, 0.17), (5, 0.52)]; 1rep [(9, 2.5), (22, 17.7)] | `camino-B-us-*.txt` |
| OK | caida de nodo -sin-repuesto: corte de ~130 s | servicio vuelve a +132.6 s; tramo de fallos 130.0 s | `camino-C-sin-repuesto.txt` |
| OK | caida de nodo -con-repuesto-tol300: corte de ~473 s | servicio vuelve a +475.8 s; tramo de fallos 473.4 s | `camino-C-con-repuesto-tol300.txt` |
| OK | caida de nodo -preferida-tol30: corte de ~87 s | servicio vuelve a +89.5 s; tramo de fallos 86.9 s | `camino-C-preferida-tol30.txt` |
| OK | caida de nodo -preferida-tol300: corte de ~347 s | servicio vuelve a +349.9 s; tramo de fallos 347.3 s | `camino-C-preferida-tol300.txt` |
| OK | ensayo 1 nodo: alerta Rate a `firing` a +56 s | +56 s | `ensayo-defensa-local-20261112/alertas-cada-10s.txt` |
| OK | ensayo 1 nodo: alerta CPU a `firing` a +91 s | +91 s | `ensayo-defensa-local-20261112/alertas-cada-10s.txt` |
| OK | ensayo 1 nodo: alerta Memoria a `firing` a +44 s | +44 s | `ensayo-defensa-local-20261112/alertas-cada-10s.txt` |
| OK | ensayo 1 nodo: alerta Storage a `firing` a +92 s | +92 s | `ensayo-defensa-local-20261112/alertas-cada-10s.txt` |
| OK | ensayo 1 nodo: alerta Servicio a `firing` a +43 s | +43 s | `ensayo-defensa-local-20261112/alertas-cada-10s.txt` |
| OK | fase de red: ninguna alerta de servicio/pod/5xx | ninguna | `alertas-cada-10s.txt` |
| OK | sonda 1 nodo: 0 fallos salvo red 28,9 s (26) y desconexion 40,1 s (40) | 6105 solicitudes; 13:27:35-13:28:04 (28.9 s, 26 fallidas); 13:30:00-13:30:40 (40.1 s, 40 fallidas) | `sonda-continua-pharmacy.txt` |
| OK | chaos-all: 6 fases, todas con codigo 0 | 6 fases, codigos ['0', '0', '0', '0', '0', '0'] | `chaos-run-20261112-131641.csv` |
| OK | plan de contencion: SEV1: 5xx > 5 % sostenido | presente | `docs/plan-contencion-incidentes.md` |
| OK | plan de contencion: rol comandante | presente | `docs/plan-contencion-incidentes.md` |
| OK | plan de contencion: rol operador | presente | `docs/plan-contencion-incidentes.md` |
| OK | plan de contencion: rol observador | presente | `docs/plan-contencion-incidentes.md` |
| OK | plan de contencion: playbook 5.1 | presente | `docs/plan-contencion-incidentes.md` |
| OK | plan de contencion: playbook 5.6 | presente | `docs/plan-contencion-incidentes.md` |
| OK | plan de contencion: plantilla de postmortem | presente | `docs/plan-contencion-incidentes.md` |
| OK | plan de contencion: checklist previo | presente | `docs/plan-contencion-incidentes.md` |
| OK | script load-requests.sh existe y contiene `500` | ok | `chaos-engineering/load-requests.sh` |
| OK | script cpu-spike.sh existe y contiene `for i in 1 2 3 4` | ok | `chaos-engineering/cpu-spike.sh` |
| OK | script ram-spike.sh existe y contiene `bloques de 1 MB` | ok | `chaos-engineering/ram-spike.sh` |
| OK | script volume-spike.sh existe y contiene `300` | ok | `chaos-engineering/volume-spike.sh` |
| OK | script network-cut.sh existe y contiene `NetworkPolicy` | ok | `chaos-engineering/network-cut.sh` |
| OK | script disconnect-component.sh existe y contiene `scale` | ok | `chaos-engineering/disconnect-component.sh` |
| OK | script chaos-all.sh existe y contiene `RAM_SECS` | ok | `chaos-engineering/chaos-all.sh` |
| OK | script chaos-all.ps1 existe y contiene `RamSecs` | ok | `chaos-engineering/chaos-all.ps1` |
| OK | primer 429 en la solicitud 51 (75 solicitudes: 67 ok, 8 429) | solo en validacion-alertas-caos-20261110.md (sin log crudo) | `documento` |
| OK | Pod reiniciado a +21 s y 5xx a +99 s | solo en validacion-alertas-caos-20261110.md (sin log crudo) | `documento` |
| OK | alerta de disco del nodo a +59 s (sintetica) y su captura | captura 20261110-alerta-disco-nodo-firing.png existe: True | `documento + captura` |

## Alcance y límites

- Verifica cifras contra registros y archivos del repositorio. No verifica las capturas de pantalla (por ejemplo, los anexos A a C del informe original) ni afirmaciones sobre el código de negocio, que no se leyó.
- Los registros crudos son los de una ejecución por caso: confirmar que una cifra es consistente con su registro no prueba que se repita.
