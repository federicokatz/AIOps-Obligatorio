#!/usr/bin/env bash
# Smoke test de senales; no provoca fallas ni modifica Deployments.
set -euo pipefail
# Git Bash no debe convertir /dev/null ni rutas remotas enviadas a kubectl.exe.
export MSYS_NO_PATHCONV=1
usage() {
    cat <<'HELP'
Uso: bash validate-telemetry.sh [--context NOMBRE] [--namespace NOMBRE] [--output-dir CARPETA_NUEVA]
Requiere la plataforma y las nuevas imagenes ya desplegadas. Consulta GET /api/drug
y /api/roles, guarda logs/trazas y comprueba presencia de metricas en Prometheus.
No prueba alertas disparadas, consultas en Kibana ni disponibilidad bajo carga.
HELP
}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
CONTEXT= NAMESPACE=pharmago OUTPUT_DIR=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --context) CONTEXT="${2:?Falta contexto}"; shift 2 ;;
        --namespace) NAMESPACE="${2:?Falta namespace}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:?Falta carpeta}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Argumento desconocido: $1" >&2; exit 1 ;;
    esac
done
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#NAMESPACE} -le 63 ]] || { echo 'Namespace invalido.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'Falta kubectl.' >&2; exit 1; }
KUBECTL=(kubectl)
[ -z "$CONTEXT" ] || KUBECTL+=(--context "$CONTEXT")
KUBECTL+=(-n "$NAMESPACE")
STAMP=$(date -u +%Y%m%d-%H%M%S)-$$
OUTPUT_DIR=${OUTPUT_DIR:-"$REPO_DIR/docs/evidencias/telemetry-$STAMP"}
mkdir -p -- "$(dirname -- "$OUTPUT_DIR")"
mkdir -- "$OUTPUT_DIR" # No sobrescribir evidencias anteriores.
PROBE="telemetry-probe-$STAMP"
CREATED=false
cleanup() {
    if "$CREATED"; then "${KUBECTL[@]}" delete pod "$PROBE" --wait=false --ignore-not-found >/dev/null || true; fi
}
trap cleanup EXIT
FAILURES=0
result() { printf '%s\n' "$*" | tee -a "$OUTPUT_DIR/results.txt"; }
result "Contexto: ${CONTEXT:-actual}; namespace: $NAMESPACE; UTC: $STAMP"
"${KUBECTL[@]}" get pods -o wide > "$OUTPUT_DIR/pods.txt"
"${KUBECTL[@]}" get daemonsets > "$OUTPUT_DIR/daemonsets.txt"
# Pod temporal sin credenciales Kubernetes, con limite de vida aunque se cierre Bash.
cat <<YAML | "${KUBECTL[@]}" create -f -
apiVersion: v1
kind: Pod
metadata:
  name: $PROBE
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  activeDeadlineSeconds: 300
  tolerations:
  - key: pharmago.io/dedicated
    operator: Equal
    value: backend
    effect: NoSchedule
  containers:
  - name: curl
    image: curlimages/curl:8.12.1
    command: [sh, -c, "sleep 300"]
    resources:
      requests: {cpu: 10m, memory: 16Mi}
      limits: {cpu: 100m, memory: 64Mi}
YAML
CREATED=true
"${KUBECTL[@]}" wait --for=condition=Ready "pod/$PROBE" --timeout=120s
curl_from_cluster() { "${KUBECTL[@]}" exec "$PROBE" -- curl --silent --show-error --fail-with-body --max-time 10 "$@"; }
TRACE_ID=$(printf '%016x%016x' "$(date +%s)" "$RANDOM")
CORRELATION_ID="telemetry-$STAMP"
printf 'trace_id=%s\ncorrelation_id=%s\n' "$TRACE_ID" "$CORRELATION_ID" > "$OUTPUT_DIR/identifiers.txt"
for endpoint in drug roles; do
    if curl_from_cluster -D - -o /dev/null -H "X-Correlation-ID: $CORRELATION_ID" \
        -H "traceparent: 00-$TRACE_ID-0123456789abcdef-01" \
        "http://pharmago-api-gateway/api/$endpoint" > "$OUTPUT_DIR/request-$endpoint.txt" \
        && grep -Eq '^HTTP/[0-9.]+ 200' "$OUTPUT_DIR/request-$endpoint.txt" \
        && grep -iF "X-Correlation-ID: $CORRELATION_ID" "$OUTPUT_DIR/request-$endpoint.txt" >/dev/null; then
        result "PASS: GET /api/$endpoint"
    else
        result "FAIL: GET /api/$endpoint"; FAILURES=$((FAILURES + 1))
    fi
done
# Exportacion y batch son asincronos; no reintentar solicitudes fallidas.
sleep 20
for app in pharmago-api-gateway pharmago-users-service pharmago-pharmacy-service; do
    "${KUBECTL[@]}" logs -l "app=$app" --all-containers=true --since=5m --tail=-1 > "$OUTPUT_DIR/$app.log"
    if grep -F "$CORRELATION_ID" "$OUTPUT_DIR/$app.log" | grep -F "$TRACE_ID" > "$OUTPUT_DIR/$app-correlated.jsonl"; then
        result "PASS: $app registra correlation_id y trace_id de ensayo"
    else
        result "FAIL: sin log correlacionado en $app"; FAILURES=$((FAILURES + 1))
    fi
done
"${KUBECTL[@]}" logs -l app=otlp-collector --all-containers=true --since=5m --tail=-1 > "$OUTPUT_DIR/collector.log"
if grep -F "$TRACE_ID" "$OUTPUT_DIR/collector.log" >/dev/null; then
    result 'PASS: el Collector recibio el Trace ID (revisar spans/parentesco en collector.log)'
else
    result 'FAIL: traza no encontrada en el Collector'; FAILURES=$((FAILURES + 1))
fi
for metric in http_server_duration_ms_count pharmago_http_requests_total \
    pharmago_http_request_duration_milliseconds_count container_cpu_usage_seconds_total \
    container_memory_working_set_bytes pod_network_receive_bytes pod_network_transmit_bytes \
    container_filesystem_usage node_cpu_seconds_total node_memory_MemAvailable_bytes \
    node_filesystem_avail_bytes node_network_receive_bytes_total; do
    response="$OUTPUT_DIR/$metric.json"
    query="$metric"
    case "$metric" in
        container_cpu_usage_seconds_total|container_memory_working_set_bytes)
            query="$metric{namespace=\"$NAMESPACE\",pod!=\"\",container!=\"\",container!=\"POD\"}" ;;
        pod_network_receive_bytes|pod_network_transmit_bytes)
            direction=receive
            [ "$metric" != pod_network_transmit_bytes ] || direction=transmit
            # Nombres de comprobacion, no instrumentos nuevos: aceptar la
            # fuente Kubelet o cAdvisor Docker por pod, sin sumar ambas.
            query="sum by (k8s_node_name,k8s_pod_name) (k8s_pod_network_io{k8s_namespace_name=\"$NAMESPACE\",k8s_node_name!=\"\",k8s_pod_name!=\"\",direction=\"$direction\"}) or sum by (k8s_node_name,k8s_pod_name) (container_network_${direction}_bytes_total{k8s_namespace_name=\"$NAMESPACE\",k8s_node_name!=\"\",k8s_pod_name!=\"\",interface!=\"lo\"})" ;;
        container_filesystem_usage)
            query="$metric{k8s_namespace_name=\"$NAMESPACE\",k8s_pod_name!=\"\",k8s_container_name!=\"\"}" ;;
    esac
    if curl_from_cluster --get --data-urlencode "query=$query" http://prometheus:9090/api/v1/query > "$response" \
        && grep -Eq '"status"[[:space:]]*:[[:space:]]*"success"' "$response" \
        && ! grep -Eq '"result"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$response"; then
        result "PASS: consulta $metric tiene series (revisar etiquetas nodo/pod en JSON)"
    else
        result "FAIL: $metric sin series o consulta fallida"; FAILURES=$((FAILURES + 1))
    fi
done
# Conservar up permite reutilizar la alerta de servicio caido del PR #5.
curl_from_cluster --get --data-urlencode 'query=up{job=~"api-gateway|users-service|pharmacy-service"}' \
    http://prometheus:9090/api/v1/query > "$OUTPUT_DIR/targets-up.json"
if "${KUBECTL[@]}" get configmap grafana-alert-rules -o yaml > "$OUTPUT_DIR/alert-rules.yaml" 2> "$OUTPUT_DIR/alert-rules-status.txt"; then
    result 'PENDIENTE: reglas presentes; comprobar evaluacion, disparo y recuperacion en Grafana'
else
    result 'PENDIENTE: integrar reglas Grafana del PR #5'
fi
result 'PENDIENTE: verificar campos JSON en Kibana y paneles de Grafana'
result "Fallas de comprobacion: $FAILURES. Evidencia: $OUTPUT_DIR"
[ "$FAILURES" -eq 0 ]
