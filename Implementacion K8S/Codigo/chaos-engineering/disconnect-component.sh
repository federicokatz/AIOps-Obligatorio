#!/bin/sh
# Chaos: desconecta un componente interno de la aplicacion.
# Uso: ./disconnect-component.sh [deployment] [modo] [segundos]
#   modo scale (por defecto): escala el deployment a 0 durante N segundos y lo
#                             devuelve a sus replicas originales.
#   modo pod:                 borra los pods del deployment; Kubernetes los recrea
#                             (mide el self healing; no hace falta restaurar).
# Por defecto: pharmago-pharmacy-service, scale, 30 s.
# Ejemplos:
#   ./disconnect-component.sh pharmago-users-service scale 45
#   ./disconnect-component.sh pharmago-db pod
DEPLOY="${1:-pharmago-pharmacy-service}"
MODE="${2:-scale}"
SECS="${3:-30}"
NS=pharmago

if ! kubectl get deploy "$DEPLOY" -n "$NS" >/dev/null 2>&1; then
  echo "Error: no existe el deployment $DEPLOY en el namespace $NS."
  exit 1
fi

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

case "$MODE" in
  pod)
    echo "Desconexion (borrar pods): $DEPLOY T0=$(now)"
    kubectl delete pod -n "$NS" -l app="$DEPLOY" --wait=false
    echo "Kubernetes recrea el pod. Seguir con: kubectl get pods -n $NS -l app=$DEPLOY -w"
    ;;
  scale)
    ORIG=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.replicas}')
    [ -z "$ORIG" ] || [ "$ORIG" = "0" ] && ORIG=1
    restore() {
      kubectl scale deploy "$DEPLOY" -n "$NS" --replicas="$ORIG"
      echo "Restaurado: $DEPLOY a $ORIG replica(s) T_fin=$(now)"
    }
    trap restore INT TERM
    echo "Desconexion (escalar a 0): $DEPLOY por ${SECS}s, replicas originales: $ORIG, T0=$(now)"
    kubectl scale deploy "$DEPLOY" -n "$NS" --replicas=0
    sleep "$SECS"
    restore
    kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout=180s
    echo "Recuperado (READY): $(now)"
    ;;
  *)
    echo "Modo invalido: $MODE (usar scale o pod)"
    exit 1
    ;;
esac
