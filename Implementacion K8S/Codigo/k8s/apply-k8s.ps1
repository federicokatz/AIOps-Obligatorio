# Despliega en el contexto actual de kubectl; local por defecto.
[CmdletBinding()]
param(
    [ValidateSet('local', 'multinode')]
    [Alias('Profile')]
    [string]$DeploymentProfile = 'local',
    [string[]]$BackendNodes = @(),
    [string]$FrontendNode,
    [string]$OpsNode,
    [switch]$RenderOnly
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { throw 'kubectl no está disponible.' }
function Invoke-Kube {
    param([string[]]$Arguments)
    & kubectl @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Falló kubectl $($Arguments -join ' ')" }
}
Push-Location $PSScriptRoot
try {
    $overlay = "overlays/$DeploymentProfile"
    if ($RenderOnly) {
        Invoke-Kube -Arguments @('kustomize', $overlay)
        return
    }
    # Comprobar los manifiestos antes de modificar nodos o recursos.
    Invoke-Kube -Arguments @('kustomize', $overlay) | Out-Null
    Write-Host "Configurando nodos para el perfil $DeploymentProfile..."
    & "$PSScriptRoot/configure-nodes.ps1" -Profile $DeploymentProfile -BackendNodes $BackendNodes -FrontendNode $FrontendNode -OpsNode $OpsNode

    Invoke-Kube -Arguments @('apply', '-f', 'namespace.yaml')
    Invoke-Kube -Arguments @('apply', '-f', 'secrets/')
    Invoke-Kube -Arguments @('apply', '-f', 'configmaps/')
    # Conservar PVs y datos existentes. La limpieza es una operación separada.
    Invoke-Kube -Arguments @('apply', '-f', 'persistent-volumes/')
    Invoke-Kube -Arguments @('apply', '-f', 'services/ops/db-service.yaml')
    Invoke-Kube -Arguments @('apply', '-f', 'deployments/ops/db-deployment.yaml')
    Invoke-Kube -Arguments @('rollout', 'status', 'deployment/pharmago-db', '-n', 'pharmago', '--timeout=300s')

    Invoke-Kube -Arguments @('apply', '-f', 'services/ops/elasticsearch-service.yaml')
    Invoke-Kube -Arguments @('apply', '-f', 'deployments/ops/elasticsearch-deployment.yaml')
    Invoke-Kube -Arguments @('rollout', 'status', 'deployment/elasticsearch', '-n', 'pharmago', '--timeout=300s')
    # Incluye RBAC y los DaemonSets Fluent Bit y Node Exporter.
    Invoke-Kube -Arguments @('apply', '-f', 'services/ops/')
    Invoke-Kube -Arguments @('apply', '-f', 'deployments/ops/')

    Invoke-Kube -Arguments @('apply', '-f', 'services/backend/')
    Invoke-Kube -Arguments @('apply', '-k', $overlay)
    Invoke-Kube -Arguments @('apply', '-f', 'services/frontend/')
    Invoke-Kube -Arguments @('apply', '-f', 'deployments/frontend/')
    Write-Host "Manifiestos aplicados con el perfil $DeploymentProfile. Verificar READY y ubicación:"
    Invoke-Kube -Arguments @('get', 'pods', '-n', 'pharmago', '-o', 'wide')
    Write-Host 'Acceso local: ./port-forward.sh.'
} finally {
    Pop-Location
}
