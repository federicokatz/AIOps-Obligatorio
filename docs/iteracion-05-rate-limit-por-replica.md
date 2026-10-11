# Iteración 05 — Rate limiting con varias réplicas (límite dividido)

Resuelve la conclusión 1 de la [iteración 02](iteracion-02-rate-limiting.md): los contadores del gateway son por réplica, así que con N réplicas el límite efectivo se multiplicaba por N (medido: 100 → ~200 solicitudes/min con 2 réplicas).

## Decisión

Alternativas descartadas por el equipo: ingress NGINX con límite compartido (obliga a cambiar el flujo de acceso y el port-forward, considerado excesivo para el obligatorio). Se eligió la opción simple: **límite por réplica = límite total / N**, aceptando que es una aproximación.

## Qué se cambió

- `k8s/configmaps/gateway-resilience.yaml`: se agrega `IpRateLimiting.GeneralRules` con la mitad de los valores originales (login 5/min, general 50/min y 500/h por réplica). Se superpone al `appsettings.json` de la imagen, sin tocar código.
- `k8s/deployments/backend/api-gateway-deployment.yaml`: `replicas: 1` → `2`. Además de repartir el límite, las 2 réplicas dejan de ser un punto único de falla del gateway y preparan los despliegues sin corte. Los perfiles `local` y `multinode` renderizan correctamente.

## Resultados medidos

Evidencia en [`evidencias/rate-limit-dividido-20261011.txt`](evidencias/rate-limit-dividido-20261011.txt). Solicitudes desde un pod del clúster al Service del gateway.

| Corrida | Solicitudes | 200 | 429 |
| --- | ---: | ---: | ---: |
| 1 | 250 | 100 | 150 |
| 2 | 250 | 100 | 150 |
| 3 | 120 | 100 | 20 |
| 4 | 120 | 100 | 20 |

El total efectivo vuelve a ser 100/min, igual que la línea base con 1 réplica (100 y 20) y distinto de la medición sin dividir (200 de 250).

## Limitaciones (explicitar en el informe)

- **Aproximado:** kube-proxy reparte al azar. Con tráfico cercano al límite, una réplica puede rechazar (429) mientras la otra aún tiene cupo, o a la inversa. Las pruebas usaron 120 y 250 solicitudes, muy por encima del límite, donde ambas réplicas se saturan.
- **Si cae una réplica**, el cupo efectivo baja a la mitad hasta que se recupera; y un reinicio de pod reinicia sus contadores (puede dejar pasar hasta un ciclo extra).
- **Acoplado a N:** si se cambia el número de réplicas hay que recalcular el límite en el ConfigMap.
- Las pruebas parten de una sola IP de origen, no de clientes distintos.
- Un límite verdaderamente compartido requeriría un contador externo (p. ej. Redis) o un proxy delante; queda como mejora futura.

## Uso de IA

Configuración y pruebas realizadas con Claude Code; los resultados salen de 4 ejecuciones reales.
