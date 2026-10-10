# Valida toda la topología antes de etiquetar o reservar nodos.
[CmdletBinding()]
param(
    [ValidateSet('local', 'multinode')]
    [Alias('Profile')]
    [string]$DeploymentProfile = 'local',
    [string[]]$BackendNodes = @(),
    [string]$FrontendNode,
    [string]$OpsNode,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$nodeJson = & kubectl get nodes -o json
if ($LASTEXITCODE -ne 0) { throw 'No se pudo consultar el clúster seleccionado en kubectl.' }
$nodes = @((($nodeJson -join "`n") | ConvertFrom-Json).items)
if ($nodes.Count -eq 0) { throw 'El clúster no tiene nodos.' }
$assignments = @()
if ($DeploymentProfile -eq 'local') {
    if ($nodes.Count -ne 1 -or $BackendNodes.Count -gt 0 -or $FrontendNode -or $OpsNode) {
        throw 'El perfil local requiere un único nodo y no recibe asignaciones de roles.'
    }
    $assignments += @{ Name = $nodes[0].metadata.name; Role = 'all' }
} else {
    if ($BackendNodes.Count -lt 3 -or -not $FrontendNode -or -not $OpsNode) {
        throw 'Multinode requiere al menos tres BackendNodes, un FrontendNode y un OpsNode distintos.'
    }
    foreach ($name in $BackendNodes) { $assignments += @{ Name = $name; Role = 'backend' } }
    $assignments += @{ Name = $FrontendNode; Role = 'frontend' }
    $assignments += @{ Name = $OpsNode; Role = 'ops' }
    $names = @($assignments | ForEach-Object { $_.Name })
    if (@($names | Select-Object -Unique).Count -ne $names.Count) {
        throw 'No se puede asignar un nodo a varios roles ni repetir nodos backend.'
    }
    $hostnames = @()
    foreach ($assignment in $assignments) {
        $matches = @($nodes | Where-Object { $_.metadata.name -eq $assignment.Name })
        if ($matches.Count -ne 1) { throw "Nodo inexistente: $($assignment.Name)" }
        $hostname = $matches[0].metadata.labels.'kubernetes.io/hostname'
        if (-not $hostname) { throw "Falta kubernetes.io/hostname en $($assignment.Name)." }
        $hostnames += $hostname
    }
    if (@($hostnames | Select-Object -Unique).Count -ne $hostnames.Count) {
        throw 'Los nodos seleccionados deben tener valores kubernetes.io/hostname diferentes.'
    }
}
foreach ($assignment in $assignments) {
    $arguments = @('label', 'node', $assignment.Name, "node-type=$($assignment.Role)", '--overwrite')
    if ($DryRun) { Write-Output "kubectl $($arguments -join ' ')" }
    else {
        & kubectl @arguments
        if ($LASTEXITCODE -ne 0) { throw "No se pudo etiquetar $($assignment.Name)." }
    }
    if ($assignment.Role -eq 'backend') {
        $arguments = @('taint', 'node', $assignment.Name, 'pharmago.io/dedicated=backend:NoSchedule', '--overwrite')
        if ($DryRun) { Write-Output "kubectl $($arguments -join ' ')" }
        else {
            & kubectl @arguments
            if ($LASTEXITCODE -ne 0) { throw "No se pudo reservar $($assignment.Name)." }
        }
    }
}
