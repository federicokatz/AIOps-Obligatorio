# Registros del ensayo de defensa (12-11-2026)

Son datos crudos. No hace falta leerlos. Las cifras ya resumidas están en [`../ensayo-defensa-local-20261112.md`](../ensayo-defensa-local-20261112.md) y se pueden recalcular con `python docs/informe/verificar_evidencia.py`.

| Archivo | Qué es |
| --- | --- |
| `alertas-cada-10s.txt` | Estado de las 8 alertas de Grafana cada 10 s, con una línea por muestra (`hora Alerta=estado`) |
| `sonda-continua-pharmacy.txt` | Una solicitud a Pharmacy `/health` cada ~0,15 s desde un pod dentro del clúster (`epoch código`) |

En la sonda, casi todas las líneas son `200`. Las que tienen `000` (sin respuesta) son los 28,9 s del corte de red y los 40,1 s de la desconexión. Por eso el archivo es largo pero tiene solo dos tramos con información.

Los tiempos del caos están en [`../chaos-run-20261112-131641.csv`](../chaos-run-20261112-131641.csv).
