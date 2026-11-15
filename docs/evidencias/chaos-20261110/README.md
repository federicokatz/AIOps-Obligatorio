# Registros del 10-11-2026

Son datos crudos de las pruebas de alertas y caos de ese día. No hace falta leerlos. Las cifras ya resumidas están en [`../validacion-alertas-caos-20261110.md`](../validacion-alertas-caos-20261110.md).

| Archivo | Qué es | ¿Sirve? |
| --- | --- | --- |
| `estado-alertas-cada-10s.txt` | Estado de las 8 alertas cada 10 s durante la corrida completa de `chaos-all` | Sí, salvo la alerta de rate limiting de las 19:41:46, que viene de un tráfico de fondo mal detenido |
| `trafico-fondo-invalido-resumen.txt` | Resumen del tráfico de fondo de esa corrida | No. Es una medición inválida y ahí se explica por qué |
| `trafico-controlado-red-y-desconexion.txt` | Sonda por el gateway durante el corte de red y una desconexión | Solo en parte. Había otros loops de tráfico a la vez y casi todo fue 429. Los 200 durante el corte de red sí sirven |
| `sonda-limpia-desconexion-1-replica.txt` | Sonda con una sola fuente de tráfico durante una desconexión de 40 s con 1 réplica | Sí |
| `soak-30min-estado-alertas.txt` | Estado de las alertas durante 30 minutos sin caos | Sí, salvo los primeros minutos, donde "Pod reiniciado" venía de reinicios anteriores |
| `soak-30min-trafico.txt` | Tráfico suave de esos 30 minutos (180 de 180 respuestas 200) | Sí |

Las líneas de tráfico tienen la forma `hora código`. El `200` es una respuesta normal y el `000` es que no hubo respuesta. Las de alertas tienen la forma `hora Alerta=estado`.
