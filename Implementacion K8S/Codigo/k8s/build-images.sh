#!/bin/bash
# Script para construir y cargar imágenes Docker en Minikube (multi-nodo)
# Funciona en Linux y Mac
# Uso: ./build-images.sh [--tag latest|version] [--profile nombre-minikube]

set -euo pipefail

IMAGE_TAG=latest
MINIKUBE_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag) IMAGE_TAG="${2:?Falta la etiqueta de imagen}"; shift 2 ;;
        --profile) MINIKUBE_ARGS=(-p "${2:?Falta el perfil de Minikube}"); shift 2 ;;
        *) echo "Argumento desconocido: $1" >&2; exit 1 ;;
    esac
done
[[ "$IMAGE_TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] || {
    echo 'Etiqueta de imagen invalida.' >&2; exit 1;
}

# Exportar la imagen recien construida: cargar por nombre puede reutilizar
# una copia vieja de la cache de Minikube cuando se repite la etiqueta.
IMAGE_ARCHIVE=
cleanup_archive() {
    if [ -n "$IMAGE_ARCHIVE" ]; then rm -f -- "$IMAGE_ARCHIVE"; fi
}
trap cleanup_archive EXIT
import_image() {
    IMAGE_ARCHIVE=$(mktemp "${TMPDIR:-/tmp}/pharmago-image.XXXXXX.tar")
    docker save --output "$IMAGE_ARCHIVE" "$1"
    minikube "${MINIKUBE_ARGS[@]}" image load "$IMAGE_ARCHIVE" --overwrite=true
    rm -f -- "$IMAGE_ARCHIVE"
    IMAGE_ARCHIVE=
}

echo "=== Construyendo y cargando imágenes Docker en Minikube ==="

# Verificar que docker está disponible
if ! command -v docker &> /dev/null; then
    echo "Error: Docker no está instalado o no está en el PATH"
    exit 1
fi

# Verificar que minikube está corriendo
if ! minikube "${MINIKUBE_ARGS[@]}" status &> /dev/null; then
    echo "Error: Minikube no está corriendo. Ejecuta: minikube start --nodes 3"
    exit 1
fi

# Obtener el directorio base (donde está este script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CODE_DIR="$(dirname "$SCRIPT_DIR")"

echo ""
echo "Construyendo imágenes de backend..."
cd "$CODE_DIR/Backend"

echo "  - pharmago-users-service..."
docker build -f PharmaGo.UsersService/Dockerfile -t "pharmago-users-service:$IMAGE_TAG" .
import_image "pharmago-users-service:$IMAGE_TAG"

echo "  - pharmago-pharmacy-service..."
docker build -f PharmaGo.PharmacyService/Dockerfile -t "pharmago-pharmacy-service:$IMAGE_TAG" .
import_image "pharmago-pharmacy-service:$IMAGE_TAG"

echo "  - pharmago-api-gateway..."
docker build -f PharmaGo.ApiGateway/Dockerfile -t "pharmago-api-gateway:$IMAGE_TAG" .
import_image "pharmago-api-gateway:$IMAGE_TAG"

echo ""
echo "Construyendo imagen de frontend..."
cd "$CODE_DIR/Frontend"

echo "  - pharmago-ui..."
docker build -f Dockerfile -t "pharmago-ui:$IMAGE_TAG" .
import_image "pharmago-ui:$IMAGE_TAG"

echo ""
echo "=== Imágenes construidas y cargadas exitosamente ==="
echo ""
echo "Verificando imágenes en Minikube..."
minikube "${MINIKUBE_ARGS[@]}" image ls | grep pharmago

cd "$SCRIPT_DIR"

