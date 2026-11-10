#!/bin/sh
# Chaos: RAM spike en pod. Uso: ./ram-spike.sh [deployment] [MB] [segundos]
# Reserva memoria RESIDENTE dentro del contenedor (bash, por bloques de 1 MB), no en /dev/shm
# (que mide 64 MB) ni en disco. Cuenta contra el limite de memoria del pod (384Mi = ~402 MB en los
# servicios backend). Se construye por bloques porque una unica asignacion grande (p. ej.
# x=$(head -c N /dev/zero | tr ...)) duplica la memoria de forma transitoria y el kernel mata el
# proceso inyectado (exit 137) antes de sostener el pico; el pod NO se reinicia.
# El 'echo liberando' final es necesario: si 'sleep' fuera el ultimo comando, bash lo reemplazaria
# con exec y liberaria la memoria al instante.
# Calibrado en Pharmacy (base ~65 MB): 280 MB -> ~343 MB (85 % del limite, dispara la alerta).
# Con ~340 MB o mas se supera el limite y el kernel mata el proceso inyectado; que el contenedor del
# servicio se reinicie (OOMKilled) NO esta probado: con 300 MB (version anterior) el pod siguio READY.
DEPLOY="${1:-pharmago-api-gateway}"
MB="${2:-200}"
SECS="${3:-30}"
POD=$(kubectl get pod -n pharmago -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "Error: no hay pods con app=$DEPLOY en el namespace pharmago."
  exit 1
fi
echo "RAM spike: $POD (${MB}MB durante ${SECS}s)"
kubectl exec -n pharmago "$POD" -- bash -c "
chunk=\$(head -c 1000000 /dev/zero | tr '\\000' a)
x=''
for i in \$(seq 1 $MB); do x+=\$chunk; done
echo \"reservados \${#x} bytes\"
sleep $SECS
echo liberando
"
RC=$?
echo "RAM spike terminado: memoria liberada en $POD (exit $RC; 137 = proceso inyectado muerto por OOM)"
exit $RC
