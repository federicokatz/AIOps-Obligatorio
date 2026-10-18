#!/usr/bin/env bash
# Mide solicitudes desde un pod independiente, a traves de un Service.
# No usa port-forward, no reintenta requests y no hace rollback automatico.
set -euo pipefail

usage() {
    cat <<'HELP'
Uso: bash measure-rolling-update.sh --deployment NOMBRE --image IMAGEN:VERSION --url URL [opciones]

  --context NOMBRE          Contexto kubectl (predeterminado: contexto actual)
  --namespace NOMBRE        Namespace (predeterminado: pharmago)
  --expected-status CODIGO  Respuesta HTTP esperada (predeterminado: 200)
  --interval SEGUNDOS       Pausa entre solicitudes, de 1 a 10 (predeterminado: 2)
  --request-timeout N       Timeout de cada solicitud, de 1 a 30 s (predeterminado: 5)
  --baseline-seconds N      Medicion previa, minimo 5 (predeterminado: 20)
  --after-seconds N         Medicion posterior, minimo 5 (predeterminado: 20)
  --timeout-seconds N       Espera maxima del rollout (predeterminado: 300)
  --header TEXTO            Cabecera opcional, por ejemplo Authorization: Bearer ...
  --output-dir DIRECTORIO   Carpeta nueva para evidencia (predeterminado: docs/evidencias/rolling-update-...)

Ejemplo (desde k8s, con la imagen ya cargada en Minikube):
  bash measure-rolling-update.sh --context minikube \
    --deployment pharmago-pharmacy-service --image pharmago-pharmacy-service:prueba-v2 \
    --url http://pharmago-api-gateway/api/drug

Exige una linea base sin errores antes de actualizar. Al finalizar deja la imagen
nueva desplegada, guarda CSV/snapshots/eventos y borra solamente su pod de prueba.
Un resultado exitoso acredita las solicitudes observadas; no una garantia universal.
HELP
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
CONTEXT= NAMESPACE=pharmago DEPLOYMENT= IMAGE= URL= HEADER= OUTPUT_DIR=
EXPECTED_STATUS=200 INTERVAL=2 REQUEST_TIMEOUT=5 BASELINE_SECONDS=20 AFTER_SECONDS=20 TIMEOUT_SECONDS=300
while [ "$#" -gt 0 ]; do
    case "$1" in
        --context) CONTEXT="${2:?Falta contexto}"; shift 2 ;;
        --namespace) NAMESPACE="${2:?Falta namespace}"; shift 2 ;;
        --deployment) DEPLOYMENT="${2:?Falta deployment}"; shift 2 ;;
        --image) IMAGE="${2:?Falta imagen}"; shift 2 ;;
        --url) URL="${2:?Falta URL}"; shift 2 ;;
        --header) HEADER="${2:?Falta cabecera}"; shift 2 ;;
        --expected-status) EXPECTED_STATUS="${2:?Falta codigo}"; shift 2 ;;
        --interval) INTERVAL="${2:?Falta intervalo}"; shift 2 ;;
        --request-timeout) REQUEST_TIMEOUT="${2:?Falta timeout HTTP}"; shift 2 ;;
        --baseline-seconds) BASELINE_SECONDS="${2:?Falta duracion}"; shift 2 ;;
        --after-seconds) AFTER_SECONDS="${2:?Falta duracion}"; shift 2 ;;
        --timeout-seconds) TIMEOUT_SECONDS="${2:?Falta timeout}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:?Falta directorio}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Argumento desconocido: $1" >&2; exit 2 ;;
    esac
done
case "$DEPLOYMENT" in
    pharmago-api-gateway|pharmago-users-service|pharmago-pharmacy-service|pharmago-ui) ;;
    *) echo 'Indicar uno de los cuatro Deployments de aplicacion con --deployment.' >&2; exit 2 ;;
esac
[[ "$IMAGE" == *@sha256:* || ( "${IMAGE##*/}" == *:* && "${IMAGE##*:}" != latest ) ]] || {
    echo 'Usar --image con una etiqueta de version distinta de latest, o un digest.' >&2; exit 2;
}
[[ "$URL" == http://* || "$URL" == https://* ]] || { echo 'Falta una URL HTTP valida.' >&2; exit 2; }
[[ "$EXPECTED_STATUS" =~ ^[1-5][0-9][0-9]$ ]] || { echo 'Codigo HTTP invalido.' >&2; exit 2; }
for value in "$INTERVAL" "$REQUEST_TIMEOUT" "$BASELINE_SECONDS" "$AFTER_SECONDS" "$TIMEOUT_SECONDS"; do
    [[ "$value" =~ ^[1-9][0-9]{0,3}$ ]] || { echo 'Los tiempos deben ser enteros positivos, sin ceros iniciales.' >&2; exit 2; }
done
(( INTERVAL <= 10 && REQUEST_TIMEOUT <= 30 && BASELINE_SECONDS >= 5 && AFTER_SECONDS >= 5 && TIMEOUT_SECONDS >= 30 )) || {
    echo 'Intervalo: 1-10 s; timeout HTTP: 1-30 s; linea base y posterior: >=5 s; timeout rollout: >=30 s.' >&2; exit 2;
}
command -v kubectl >/dev/null || { echo 'kubectl no esta disponible.' >&2; exit 2; }
if [ -z "$CONTEXT" ]; then CONTEXT=$(kubectl config current-context | tr -d '\r'); fi
# Evitar que Git Bash convierta /bin/sh y /tmp/... en rutas de Windows.
k() { MSYS_NO_PATHCONV=1 kubectl --context "$CONTEXT" --namespace "$NAMESPACE" "$@"; }
OLD_IMAGE=$(k get deployment "$DEPLOYMENT" -o 'jsonpath={.spec.template.spec.containers[0].image}' | tr -d '\r')
CONTAINER=$(k get deployment "$DEPLOYMENT" -o 'jsonpath={.spec.template.spec.containers[0].name}' | tr -d '\r')
[ "$CONTAINER" = "$DEPLOYMENT" ] || { echo 'Contenedor inesperado; no se modifico el Deployment.' >&2; exit 2; }
[ "$IMAGE" != "$OLD_IMAGE" ] || { echo 'La imagen ya esta desplegada; usar otra version.' >&2; exit 2; }
POLICY=$(k get deployment "$DEPLOYMENT" -o 'jsonpath={.spec.strategy.type}|{.spec.strategy.rollingUpdate.maxUnavailable}|{.spec.strategy.rollingUpdate.maxSurge}|{.spec.minReadySeconds}' | tr -d '\r')
[[ "$POLICY" == RollingUpdate\|0\|1\|* && "${POLICY##*|}" =~ ^[1-9][0-9]*$ ]] || {
    echo 'Aplicar primero RollingUpdate con maxUnavailable=0, maxSurge=1 y minReadySeconds>0.' >&2; exit 2;
}
k rollout status "deployment/$DEPLOYMENT" --timeout="${TIMEOUT_SECONDS}s"

RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$$"
PROBE="rolling-update-probe-$RUN_ID"
OUTPUT_DIR=${OUTPUT_DIR:-"$REPO_DIR/docs/evidencias/rolling-update-$DEPLOYMENT-$RUN_ID"}
mkdir -- "$OUTPUT_DIR" 2>/dev/null || {
    # El directorio de evidencias puede no existir en una copia nueva.
    [ ! -e "$OUTPUT_DIR" ] || { echo 'La carpeta de salida ya existe; no se sobrescribe evidencia.' >&2; exit 2; }
    mkdir -p -- "$(dirname -- "$OUTPUT_DIR")"
    mkdir -- "$OUTPUT_DIR"
}
CREATED=false COLLECTED=false COMPLETE=false
snapshot() {
    k get deployment "$DEPLOYMENT" -o 'custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,UPDATED:.status.updatedReplicas,AVAILABLE:.status.availableReplicas,IMAGE:.spec.template.spec.containers[0].image'
    k get pods -l "app=$DEPLOYMENT" -o wide
    k get pods -l "app=$DEPLOYMENT" -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,IMAGE_ID:.status.containerStatuses[0].imageID'
}
summarize() {
    awk -F, -v expected="$EXPECTED_STATUS" '
        NR == 1 { next }
        NF != 5 || $2 !~ /^(baseline|update|after)$/ { malformed++; next }
        { n[$2]++; total++; ok=($3 == expected && $5+0 == 0);
          good[$2]+=ok; successful+=ok; if ($4+0 > max[$2]) max[$2]=$4+0 }
        END {
          print "phase,requests,successful,failed,availability_percent,max_seconds";
          split("baseline update after", phases, " ");
          for (i=1; i<=3; i++) { p=phases[i];
            printf "%s,%d,%d,%d,%.2f,%.6f\n",p,n[p],good[p],n[p]-good[p],n[p] ? 100*good[p]/n[p] : 0,max[p] }
          printf "all,%d,%d,%d,%.2f,\n",total,successful,total-successful,total ? 100*successful/total : 0;
          if (malformed || !n["baseline"] || !n["update"] || !n["after"] || total != successful) exit 1;
        }' "$OUTPUT_DIR/requests.csv" > "$OUTPUT_DIR/summary.csv"
}
collect() {
    local finished=false
    k exec "$PROBE" -- touch /tmp/stop >/dev/null 2>&1 || true
    for ((i=0; i<REQUEST_TIMEOUT+INTERVAL+5; i++)); do
        if k exec "$PROBE" -- test -f /tmp/finished >/dev/null 2>&1; then finished=true; break; fi
        sleep 1
    done
    if ! k logs "$PROBE" > "$OUTPUT_DIR/requests.csv"; then return 1; fi
    COLLECTED=true
    "$finished"
}
cleanup() {
    local code=$?
    trap - EXIT INT TERM
    set +e
    if "$CREATED"; then
        if ! "$COLLECTED"; then collect; fi
        # No exportar env del pod: --header puede contener un token de acceso.
        k get pod "$PROBE" -o 'jsonpath={.status}' > "$OUTPUT_DIR/probe-status.txt" 2>&1
        k delete pod "$PROBE" --wait=false > /dev/null 2>&1
    fi
    snapshot > "$OUTPUT_DIR/after.txt" 2>&1
    k get events --sort-by=.metadata.creationTimestamp > "$OUTPUT_DIR/events.txt" 2>&1
    if [ -f "$OUTPUT_DIR/requests.csv" ]; then summarize; fi
    printf 'exit_code=%s\ncompleted=%s\n' "$code" "$COMPLETE" >> "$OUTPUT_DIR/run.txt"
    echo "Evidencia: $OUTPUT_DIR"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'context=%s\nnamespace=%s\ndeployment=%s\nold_image=%s\nnew_image=%s\nurl=%s\nexpected_status=%s\ninterval_seconds=%s\nrequest_timeout_seconds=%s\n' \
    "$CONTEXT" "$NAMESPACE" "$DEPLOYMENT" "$OLD_IMAGE" "$IMAGE" "$URL" "$EXPECTED_STATUS" "$INTERVAL" "$REQUEST_TIMEOUT" > "$OUTPUT_DIR/run.txt"
snapshot > "$OUTPUT_DIR/before.txt"

read -r -d '' PROBE_PROGRAM <<'PROBE_SCRIPT' || true
printf baseline > /tmp/phase
printf 'timestamp_utc,phase,http_status,seconds,curl_exit\n'
while [ ! -f /tmp/stop ]; do
    phase=$(cat /tmp/phase)
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    set -- --silent --output /dev/null --retry 0 --connect-timeout 2 --max-time "$PROBE_TIMEOUT" --write-out '%{http_code},%{time_total}'
    if [ -n "$PROBE_HEADER" ]; then set -- "$@" --header "$PROBE_HEADER"; fi
    result=$(curl "$@" "$PROBE_URL")
    code=$?
    printf '%s,%s,%s,%s\n' "$timestamp" "$phase" "$result" "$code"
    sleep "$PROBE_INTERVAL"
done
touch /tmp/finished
# Mantener el pod vivo para recoger evidencia; activeDeadlineSeconds lo acota.
sleep 3600
PROBE_SCRIPT
DEADLINE=$((BASELINE_SECONDS + TIMEOUT_SECONDS + AFTER_SECONDS + 180))
PATCH="{\"spec\":{\"automountServiceAccountToken\":false,\"activeDeadlineSeconds\":$DEADLINE,\"terminationGracePeriodSeconds\":5,\"tolerations\":[{\"key\":\"pharmago.io/dedicated\",\"operator\":\"Equal\",\"value\":\"backend\",\"effect\":\"NoSchedule\"}],\"containers\":[{\"name\":\"$PROBE\",\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"cpu\":\"100m\",\"memory\":\"64Mi\"}}}]}}"
echo "Contexto: $CONTEXT; actualizacion: $DEPLOYMENT; $OLD_IMAGE -> $IMAGE"
k run "$PROBE" --image=curlimages/curl:8.12.1 --restart=Never --labels=app=rolling-update-probe \
    --env="PROBE_URL=$URL" --env="PROBE_HEADER=$HEADER" --env="PROBE_INTERVAL=$INTERVAL" --env="PROBE_TIMEOUT=$REQUEST_TIMEOUT" \
    --dry-run=client -o json --command -- /bin/sh -c "$PROBE_PROGRAM" |
    k patch --local -f - --type=strategic -p "$PATCH" -o json |
    k create -f -
CREATED=true
k wait --for=condition=Ready "pod/$PROBE" --timeout=120s
sleep "$BASELINE_SECONDS"
k logs "$PROBE" > "$OUTPUT_DIR/baseline.csv"
awk -F, -v expected="$EXPECTED_STATUS" '
    NR > 1 { n++; if (NF != 5 || $3 != expected || $5+0 != 0) failed++ }
    END { if (!n || failed) exit 1 }' "$OUTPUT_DIR/baseline.csv" || {
    echo 'La linea base tiene errores; no se actualizo la aplicacion. Revisar baseline.csv.' >&2; exit 1;
}

k exec "$PROBE" -- sh -c 'printf update > /tmp/phase.next && mv /tmp/phase.next /tmp/phase'
k set image "deployment/$DEPLOYMENT" "$CONTAINER=$IMAGE" | tee "$OUTPUT_DIR/update.txt"
if ! k rollout status "deployment/$DEPLOYMENT" --timeout="${TIMEOUT_SECONDS}s" > "$OUTPUT_DIR/rollout.txt" 2>&1; then
    cat "$OUTPUT_DIR/rollout.txt" >&2
    echo 'El rollout fallo. Se conserva el estado para diagnosticarlo; no se oculta con rollback automatico.' >&2
    exit 1
fi
cat "$OUTPUT_DIR/rollout.txt"
k exec "$PROBE" -- sh -c 'printf after > /tmp/phase.next && mv /tmp/phase.next /tmp/phase'
sleep "$AFTER_SECONDS"
collect || { echo 'La sonda no termino correctamente; la medicion no es valida.' >&2; exit 1; }
CURRENT_IMAGE=$(k get deployment "$DEPLOYMENT" -o 'jsonpath={.spec.template.spec.containers[0].image}' | tr -d '\r')
[ "$CURRENT_IMAGE" = "$IMAGE" ] || { echo 'Cambio la imagen durante la prueba; revisar actualizaciones concurrentes.' >&2; exit 1; }
if ! summarize; then
    cat "$OUTPUT_DIR/summary.csv"
    echo 'Hubo errores o faltaron muestras en alguna fase. Revisar requests.csv antes de ajustar.' >&2
    exit 1
fi
COMPLETE=true
cat "$OUTPUT_DIR/summary.csv"
echo 'Sin fallas en las solicitudes observadas antes, durante y despues del reemplazo.'
