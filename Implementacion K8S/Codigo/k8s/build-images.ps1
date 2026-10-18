# Script para construir y cargar imágenes Docker en Minikube (multi-nodo)
# Funciona en Windows PowerShell
# Uso: .\build-images.ps1 [-Tag version] [-MinikubeProfile minikube]
param(
    [ValidatePattern('^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$')]
    [string]$Tag = 'latest',
    [Alias('Profile')]
    [string]$MinikubeProfile
)
$ErrorActionPreference = 'Stop'
$minikubeArgs = @()
if ($MinikubeProfile) { $minikubeArgs = @('-p', $MinikubeProfile) }
function Import-MinikubeImage([string]$Image) {
    # Una exportacion nueva evita importar una copia vieja de la cache por tag.
    $archive = Join-Path ([System.IO.Path]::GetTempPath()) ('pharmago-image-' + [Guid]::NewGuid().ToString('N') + '.tar')
    try {
        & docker save --output $archive $Image
        if ($LASTEXITCODE -ne 0) { throw "No se pudo exportar $Image" }
        & minikube @minikubeArgs image load $archive --overwrite=true
        if ($LASTEXITCODE -ne 0) { throw "No se pudo cargar $Image en Minikube" }
    } finally {
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    }
}

Write-Host "=== Construyendo y cargando imágenes Docker en Minikube ===" -ForegroundColor Green

# Verificar que docker está disponible
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "Error: Docker no está instalado o no está en el PATH" -ForegroundColor Red
    exit 1
}

# Verificar que minikube está corriendo
$minikubeStatus = & minikube @minikubeArgs status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Minikube no está corriendo. Ejecuta: minikube start --nodes 3" -ForegroundColor Red
    exit 1
}

# Obtener el directorio base (donde está este script)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$codeDir = Split-Path -Parent $scriptDir

Write-Host "`nConstruyendo imágenes de backend..." -ForegroundColor Yellow
Set-Location "$codeDir\Backend"

Write-Host "  - pharmago-users-service..." -ForegroundColor Cyan
docker build -f PharmaGo.UsersService/Dockerfile -t "pharmago-users-service:$Tag" .
if ($LASTEXITCODE -ne 0) { 
    Write-Host "Error construyendo pharmago-users-service" -ForegroundColor Red
    exit 1 
}
Import-MinikubeImage "pharmago-users-service:$Tag"

Write-Host "  - pharmago-pharmacy-service..." -ForegroundColor Cyan
docker build -f PharmaGo.PharmacyService/Dockerfile -t "pharmago-pharmacy-service:$Tag" .
if ($LASTEXITCODE -ne 0) { 
    Write-Host "Error construyendo pharmago-pharmacy-service" -ForegroundColor Red
    exit 1 
}
Import-MinikubeImage "pharmago-pharmacy-service:$Tag"

Write-Host "  - pharmago-api-gateway..." -ForegroundColor Cyan
docker build -f PharmaGo.ApiGateway/Dockerfile -t "pharmago-api-gateway:$Tag" .
if ($LASTEXITCODE -ne 0) { 
    Write-Host "Error construyendo pharmago-api-gateway" -ForegroundColor Red
    exit 1 
}
Import-MinikubeImage "pharmago-api-gateway:$Tag"

Write-Host "`nConstruyendo imagen de frontend..." -ForegroundColor Yellow
Set-Location "$codeDir\Frontend"

Write-Host "  - pharmago-ui..." -ForegroundColor Cyan
docker build -f Dockerfile -t "pharmago-ui:$Tag" .
if ($LASTEXITCODE -ne 0) { 
    Write-Host "Error construyendo pharmago-ui" -ForegroundColor Red
    exit 1 
}
Import-MinikubeImage "pharmago-ui:$Tag"

Write-Host "`n=== Imágenes construidas y cargadas exitosamente ===" -ForegroundColor Green
Write-Host "`nVerificando imágenes en Minikube..." -ForegroundColor Yellow
& minikube @minikubeArgs image ls | Select-String "pharmago"

Set-Location $scriptDir

