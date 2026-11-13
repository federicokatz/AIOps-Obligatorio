# Registros del ensayo multinodo (10-11-2026)

Son datos crudos. No hace falta leerlos. El resumen y las tablas están en [`../ensayo-multinode-20261110.md`](../ensayo-multinode-20261110.md) y las cifras se pueden recalcular con `python docs/informe/verificar_evidencia.py`.

Las líneas de las sondas tienen la forma `epoch código`. El `200` es una respuesta normal y el `000` es que no hubo respuesta.

| Archivos | Qué son |
| --- | --- |
| `ubicacion-pods.txt` | En qué nodo quedó cada pod |
| `ens-s1` a `ens-s6` | Primera sonda, desde fuera del clúster (una solicitud cada ~1,3 s). Prueban reemplazos y crash de contenedor con 2 y con 1 réplica. Tienen poca resolución |
| `ens-INVALIDO-nodo-saturado-*` | Primera corrida de s1 a s4. Es inválida porque el nodo de operaciones estaba saturado. Se conserva por transparencia y no se usa |
| `camino-A-*` | Crash del contenedor de Pharmacy con 2 y con 1 réplica, 3 corridas cada una, con una sonda interna de ~10 solicitudes por segundo. Empiezan con `T0` (el momento del crash) y terminan con `restarts:` |
| `camino-B-*` | Lo mismo para el gateway (`gw`) y para Users (`us`), 2 corridas por caso |
| `camino-C-*` | Caída de un nodo completo, en 4 casos (con y sin nodo de repuesto, con tolerancia de 30 y de 300 s) |
| `camino-D-sonda-continua-pharmacy.txt` | Sonda continua (~7.800 solicitudes) durante `chaos-all` en multinodo |
| `camino-D-alertas-*.txt` | Estado de las alertas cada 10 s, durante `chaos-all` y en la verificación de CPU y memoria |
