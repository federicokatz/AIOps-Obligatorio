#!/usr/bin/env bash
# Despliega en el contexto actual de kubectl; local por defecto.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOYMENT_PROFILE=local
NODE_ARGUMENTS=()
RENDER_ONLY=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile) DEPLOYMENT_PROFILE="${2:?Falta el perfil}"; shift 2 ;;
        --backend-nodes|--frontend-node|--ops-node)
            NODE_ARGUMENTS+=("$1" "${2:?Falta el valor}"); shift 2 ;;
        --render-only) RENDER_ONLY=true; shift ;;
        *) echo "Argumento desconocido: $1" >&2; exit 1 ;;
    esac
done
case "$DEPLOYMENT_PROFILE" in local|multinode) ;; *) echo "Perfil desconocido: $DEPLOYMENT_PROFILE" >&2; exit 1 ;; esac
command -v kubectl >/dev/null || { echo 'kubectl no está disponible.' >&2; exit 1; }
cd -- "$SCRIPT_DIR"
OVERLAY="overlays/$DEPLOYMENT_PROFILE"
if "$RENDER_ONLY"; then kubectl kustomize "$OVERLAY"; exit 0; fi
# Comprobar los manifiestos antes de modificar nodos o recursos.
kubectl kustomize "$OVERLAY" >/dev/null
bash "$SCRIPT_DIR/configure-nodes.sh" --profile "$DEPLOYMENT_PROFILE" "${NODE_ARGUMENTS[@]}"

kubectl apply -f namespace.yaml
kubectl apply -f secrets/
kubectl apply -f configmaps/
# Conservar PVs y datos existentes. La limpieza es una operación separada.
kubectl apply -f persistent-volumes/
kubectl apply -f services/ops/db-service.yaml
kubectl apply -f deployments/ops/db-deployment.yaml
kubectl rollout status deployment/pharmago-db -n pharmago --timeout=300s

kubectl apply -f services/ops/elasticsearch-service.yaml
kubectl apply -f deployments/ops/elasticsearch-deployment.yaml
kubectl rollout status deployment/elasticsearch -n pharmago --timeout=300s
# Incluye RBAC y los DaemonSets Fluent Bit y Node Exporter.
kubectl apply -f services/ops/
kubectl apply -f deployments/ops/
kubectl apply -f services/backend/
kubectl apply -k "$OVERLAY"
kubectl apply -f services/frontend/
kubectl apply -f deployments/frontend/
echo "Manifiestos aplicados con el perfil $DEPLOYMENT_PROFILE. Verificar READY y ubicación:"
kubectl get pods -n pharmago -o wide
echo 'Acceso local: ./port-forward.sh.'
