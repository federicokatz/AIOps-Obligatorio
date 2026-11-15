#!/bin/sh
# Chaos: ejecuta en orden las 6 fallas pedidas por la letra y registra T0/T_fin de cada una.
# Uso: ./chaos-all.sh
# Variables opcionales:
#   TARGET=pharmago-pharmacy-service  deployment que recibe CPU/RAM/storage/red/desconexion
#   PAUSE=60                          segundos de pausa entre fallas (observar recuperacion)
#   REQUESTS=500                      cantidad de requests del flood
#   CPU_SECS=30  RAM_MB=320  RAM_SECS=30  DISK_MB=300  NET_SECS=30  DOWN_SECS=30
# Requiere: kubectl con acceso al cluster y port-forward del gateway activo (puerto 5000).
# Salida: docs/evidencias/chaos-run-<fecha>.csv (fase, T0, T_fin, codigo de salida).
DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${TARGET:-pharmago-pharmacy-service}"
PAUSE="${PAUSE:-60}"
REQUESTS="${REQUESTS:-500}"
CPU_SECS="${CPU_SECS:-30}"
RAM_MB="${RAM_MB:-320}"
RAM_SECS="${RAM_SECS:-30}"
DISK_MB="${DISK_MB:-300}"
NET_SECS="${NET_SECS:-30}"
DOWN_SECS="${DOWN_SECS:-30}"
NS=pharmago

OUT_DIR="$DIR/../../../docs/evidencias"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/chaos-run-$(date -u +%Y%m%d-%H%M%S).csv"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "fase,target,t0_utc,t_fin_utc,codigo_salida" > "$OUT"

if ! kubectl get deploy "$TARGET" -n "$NS" >/dev/null 2>&1; then
  echo "Error: no existe el deployment $TARGET en el namespace $NS (o no hay acceso al cluster)."
  exit 1
fi

run_phase() {
  NAME="$1"; shift
  T0=$(now)
  echo "=== [$NAME] T0=$T0 ==="
  "$@"
  RC=$?
  TF=$(now)
  echo "$NAME,$TARGET,$T0,$TF,$RC" >> "$OUT"
  echo "=== [$NAME] fin $TF (codigo $RC). Pausa ${PAUSE}s para observar la recuperacion ==="
  sleep "$PAUSE"
}

cleanup_pod_files() {
  POD=$(kubectl get pod -n "$NS" -l app="$TARGET" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$POD" ] && return 0
  # sh -c evita que Git Bash (Windows) convierta /tmp/... en una ruta de Windows y no borre nada.
  kubectl exec -n "$NS" "$POD" -- sh -c 'rm -f /dev/shm/fill /tmp/fill /tmp/chaos_fill' 2>/dev/null
  # Red de seguridad: cpu-spike.sh ya detiene sus bucles (trap); esto cubre una interrupcion a mitad de fase.
  # (el patron do[n]e evita que el propio comando se mate a si mismo)
  kubectl exec -n "$NS" "$POD" -- sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline 2>/dev/null | grep -q "while :;do :;do[n]e" && kill -9 ${p#/proc/} 2>/dev/null; done; true' 2>/dev/null
}
trap 'echo "Interrumpido; limpiando"; cleanup_pod_files; "$DIR/network-cut.sh" "$TARGET" restore' INT TERM

echo "Registro: $OUT"
run_phase "requests"   sh "$DIR/load-requests.sh" "$REQUESTS"
run_phase "cpu"        sh "$DIR/cpu-spike.sh" "$TARGET" "$CPU_SECS"
run_phase "memoria"    sh "$DIR/ram-spike.sh" "$TARGET" "$RAM_MB" "$RAM_SECS"
cleanup_pod_files
run_phase "storage"    sh "$DIR/volume-spike.sh" "$TARGET" "$DISK_MB"
cleanup_pod_files
run_phase "red"        sh "$DIR/network-cut.sh" "$TARGET" "$NET_SECS"
run_phase "desconexion" sh "$DIR/disconnect-component.sh" "$TARGET" scale "$DOWN_SECS"

echo "Terminado. Resultados en $OUT"
