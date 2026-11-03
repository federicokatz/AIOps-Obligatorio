#!/usr/bin/env bash
# Despliega en el contexto actual de kubectl; local por defecto.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOYMENT_PROFILE=local
NODE_ARGUMENTS=()
RENDER_ONLY=false
SEED_DATA=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile) DEPLOYMENT_PROFILE="${2:?Falta el perfil}"; shift 2 ;;
        --backend-nodes|--frontend-node|--ops-node)
            NODE_ARGUMENTS+=("$1" "${2:?Falta el valor}"); shift 2 ;;
        --render-only) RENDER_ONLY=true; shift ;;
        --seed-data) SEED_DATA=true; shift ;;
        *) echo "Argumento desconocido: $1" >&2; exit 1 ;;
    esac
done
case "$DEPLOYMENT_PROFILE" in local|multinode) ;; *) echo "Perfil desconocido: $DEPLOYMENT_PROFILE" >&2; exit 1 ;; esac
command -v kubectl >/dev/null || { echo 'kubectl no está disponible.' >&2; exit 1; }
cd -- "$SCRIPT_DIR"
OVERLAY="overlays/$DEPLOYMENT_PROFILE"
if "$RENDER_ONLY"; then kubectl kustomize "$OVERLAY"; exit 0; fi
SEED_FILE="$SCRIPT_DIR/../Backend/seed-data.sql"
if "$SEED_DATA" && [ ! -f "$SEED_FILE" ]; then
    echo "No existe el archivo de datos de prueba: $SEED_FILE" >&2; exit 1
fi
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
if "$SEED_DATA"; then
    # La clave se toma dentro del contenedor; no pasa por argumentos ni por el host.
    SQLCMD_RUNNER=$(cat <<'SHELL'
export SQLCMDPASSWORD=${SA_PASSWORD:-${MSSQL_SA_PASSWORD:-}}
if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
    sqlcmd_binary=/opt/mssql-tools18/bin/sqlcmd
elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
    sqlcmd_binary=/opt/mssql-tools/bin/sqlcmd
else
    echo 'No se encontro sqlcmd en el contenedor de SQL Server.' >&2
    exit 127
fi
exec $sqlcmd_binary -S localhost -U sa -C -b -l 5 -t 30 -f 65001
SHELL
)
    READY_SQL=$(cat <<'SQL'
SET NOCOUNT ON;
IF DB_ID(N'PharmaDb') IS NULL THROW 51000, 'PharmaDb todavia no existe.', 1;
GO
USE PharmaDb;
GO
IF OBJECT_ID(N'dbo.Roles', N'U') IS NULL
OR OBJECT_ID(N'dbo.UnitMeasures', N'U') IS NULL
OR OBJECT_ID(N'dbo.Presentations', N'U') IS NULL
OR OBJECT_ID(N'dbo.Pharmacys', N'U') IS NULL
OR OBJECT_ID(N'dbo.Users', N'U') IS NULL
OR OBJECT_ID(N'dbo.Invitations', N'U') IS NULL
OR OBJECT_ID(N'dbo.Drugs', N'U') IS NULL
    THROW 51001, 'Faltan tablas requeridas por seed-data.sql.', 1;
GO
SQL
)
    SQL_LOG=$(mktemp)
    trap 'rm -f -- "$SQL_LOG"' EXIT
    echo 'Esperando PharmaDb y sus tablas para cargar datos de prueba (hasta 300 s)...'
    SEED_DEADLINE=$((SECONDS + 300))
    while true; do
        if printf '%s\n' "$READY_SQL" | MSYS_NO_PATHCONV=1 kubectl exec -i -n pharmago deployment/pharmago-db \
            -- sh -c "$SQLCMD_RUNNER" > "$SQL_LOG" 2>&1; then
            break
        else
            SQL_STATUS=$?
        fi
        if [ "$SQL_STATUS" -eq 127 ] || [ "$SECONDS" -ge "$SEED_DEADLINE" ]; then
            cat "$SQL_LOG" >&2
            echo 'No se pudo preparar el seed. Se requiere PharmaDb con su esquema; este paso no crea tablas ni borra datos.' >&2
            exit 1
        fi
        sleep 5
    done
    echo 'Ejecutando Backend/seed-data.sql...'
    # Un error SQL detiene el despliegue; no repetir automaticamente una carga parcial.
    MSYS_NO_PATHCONV=1 kubectl exec -i -n pharmago deployment/pharmago-db \
        -- sh -c "$SQLCMD_RUNNER" < "$SEED_FILE"
    echo 'Datos de prueba cargados.'
fi
echo "Manifiestos aplicados con el perfil $DEPLOYMENT_PROFILE. Verificar READY y ubicación:"
kubectl get pods -n pharmago -o wide
echo 'Acceso local: ./port-forward.sh.'
