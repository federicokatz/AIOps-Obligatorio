#!/usr/bin/env bash
# Valida toda la topología antes de etiquetar o reservar nodos.
set -euo pipefail
DEPLOYMENT_PROFILE=local
BACKEND_NODES=''
FRONTEND_NODE=''
OPS_NODE=''
DRY_RUN=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile) DEPLOYMENT_PROFILE="${2:?Falta el perfil}"; shift 2 ;;
        --backend-nodes) BACKEND_NODES="${2:?Falta la lista de nodos}"; shift 2 ;;
        --frontend-node) FRONTEND_NODE="${2:?Falta el nodo frontend}"; shift 2 ;;
        --ops-node) OPS_NODE="${2:?Falta el nodo ops}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Argumento desconocido: $1" >&2; exit 1 ;;
    esac
done
fail() { echo "$*" >&2; exit 1; }
NODE_NAMES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
read -r -a AVAILABLE <<< "$NODE_NAMES"
[ "${#AVAILABLE[@]}" -gt 0 ] || fail 'El clúster no tiene nodos.'
NAMES=()
ROLES=()
case "$DEPLOYMENT_PROFILE" in
    local)
        [ "${#AVAILABLE[@]}" -eq 1 ] && [ -z "$BACKEND_NODES$FRONTEND_NODE$OPS_NODE" ] ||
            fail 'El perfil local requiere un único nodo y no recibe asignaciones de roles.'
        NAMES=("${AVAILABLE[0]}"); ROLES=(all)
        ;;
    multinode)
        [ -n "$BACKEND_NODES" ] && [ -n "$FRONTEND_NODE" ] && [ -n "$OPS_NODE" ] ||
            fail 'Multinode requiere backend, frontend y ops explícitos.'
        [[ "$BACKEND_NODES" != ,* && "$BACKEND_NODES" != *, && "$BACKEND_NODES" != *,,* ]] ||
            fail 'La lista de nodos backend contiene elementos vacíos.'
        IFS=',' read -r -a BACKENDS <<< "$BACKEND_NODES"
        [ "${#BACKENDS[@]}" -ge 3 ] || fail 'Se requieren al menos tres nodos backend.'
        for name in "${BACKENDS[@]}"; do NAMES+=("$name"); ROLES+=(backend); done
        NAMES+=("$FRONTEND_NODE" "$OPS_NODE"); ROLES+=(frontend ops)
        SEEN_NAMES=' '
        SEEN_HOSTNAMES=' '
        for name in "${NAMES[@]}"; do
            [[ " $NODE_NAMES " == *" $name "* ]] || fail "Nodo inexistente: $name"
            [[ "$SEEN_NAMES" != *" $name "* ]] || fail "Nodo repetido: $name"
            SEEN_NAMES+="$name "
            hostname=$(kubectl get node "$name" -o 'jsonpath={.metadata.labels.kubernetes\.io/hostname}')
            [ -n "$hostname" ] || fail "Falta kubernetes.io/hostname en $name."
            [[ "$SEEN_HOSTNAMES" != *" $hostname "* ]] || fail 'Los hostnames de los nodos deben ser distintos.'
            SEEN_HOSTNAMES+="$hostname "
        done
        ;;
    *) fail "Perfil desconocido: $DEPLOYMENT_PROFILE" ;;
esac
run() {
    if "$DRY_RUN"; then printf '%q ' kubectl "$@"; printf '\n';
    else kubectl "$@"; fi
}
for index in "${!NAMES[@]}"; do
    run label node "${NAMES[$index]}" "node-type=${ROLES[$index]}" --overwrite
    if [ "${ROLES[$index]}" = backend ]; then
        run taint node "${NAMES[$index]}" pharmago.io/dedicated=backend:NoSchedule --overwrite
    fi
done
