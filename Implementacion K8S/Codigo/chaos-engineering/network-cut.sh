#!/bin/sh
# Chaos: corta el trafico de red de un servicio con una NetworkPolicy de denegacion total.
# Uso: ./network-cut.sh [deployment] [segundos|restore]
#   ./network-cut.sh pharmago-users-service 30   -> corta 30 s y restaura solo
#   ./network-cut.sh pharmago-users-service restore -> retira la politica
# Por defecto: pharmago-pharmacy-service, 30 s.
#
# ATENCION: una NetworkPolicy solo tiene efecto si el CNI del cluster la aplica
# (Calico, Cilium, etc.). Con el CNI por defecto de Minikube puede NO hacer nada.
# Verificar el efecto con el paso de comprobacion (ver README) o iniciar Minikube
# con: minikube start --cni=calico
DEPLOY="${1:-pharmago-pharmacy-service}"
ARG="${2:-30}"
NS=pharmago
POLICY="chaos-cut-$DEPLOY"

restore() {
  kubectl delete networkpolicy "$POLICY" -n "$NS" --ignore-not-found
  echo "Red restaurada: $DEPLOY"
}

if [ "$ARG" = "restore" ]; then
  restore
  exit 0
fi

if ! kubectl get deploy "$DEPLOY" -n "$NS" >/dev/null 2>&1; then
  echo "Error: no existe el deployment $DEPLOY en el namespace $NS."
  exit 1
fi

if ! kubectl get pods -n kube-system 2>/dev/null | grep -q -i -E 'calico|cilium|weave|antrea'; then
  echo "AVISO: no se detecto un CNI que aplique NetworkPolicy (calico/cilium/weave/antrea)."
  echo "       El corte podria no tener efecto. Seguimos igual."
fi

# Si se interrumpe (Ctrl+C) se restaura la red.
trap restore INT TERM

echo "Corte de red: $DEPLOY (${ARG}s) T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kubectl apply -n "$NS" -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $POLICY
  labels:
    chaos: network-cut
spec:
  podSelector:
    matchLabels:
      app: $DEPLOY
  policyTypes: [Ingress, Egress]
EOF

sleep "$ARG"
restore
echo "Fin del corte: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
