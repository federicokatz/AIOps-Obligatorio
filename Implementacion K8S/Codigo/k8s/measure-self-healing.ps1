# Ejecutar desde PowerShell con Minikube y kubectl disponibles.
# Cada intento usa un pod nuevo para medir una falla aislada, sin arrastrar
# el backoff de CrashLoopBackOff de intentos anteriores.
param(
    [ValidateRange(1, 10)]
    [int]$Trials = 3,
    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$namespace = 'pharmago'
$services = @('pharmago-api-gateway', 'pharmago-users-service', 'pharmago-pharmacy-service')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$evidenceDir = Join-Path $repoRoot 'docs\evidencias'
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
$outputPath = Join-Path $evidenceDir ("self-healing-{0}.csv" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))

function Get-CurrentPod([string]$service) {
    $raw = & kubectl get pods -n $namespace -l "app=$service" -o json
    if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar $service" }
    $pods = @(((($raw -join "`n") | ConvertFrom-Json).items) | Where-Object { -not $_.metadata.deletionTimestamp })
    if ($pods.Count -ne 1) { throw "Se esperaba un pod activo de $service; encontrados: $($pods.Count)" }
    return $pods[0]
}

function Test-Ready($pod) {
    $ready = @($pod.status.conditions | Where-Object { $_.type -eq 'Ready' })
    return ($ready.Count -eq 1 -and $ready[0].status -eq 'True' -and $pod.status.containerStatuses[0].ready)
}

function Wait-NewReadyPod([string]$service, [string]$previousName) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 1000
        try { $pod = Get-CurrentPod $service } catch { continue }
        if ($pod.metadata.name -ne $previousName -and (Test-Ready $pod)) { return $pod }
    } while ((Get-Date) -lt $deadline)
    throw "El pod de reemplazo de $service no llegó a Ready en $TimeoutSeconds s"
}

foreach ($service in $services) {
    for ($trial = 1; $trial -le $Trials; $trial++) {
        $pod = Get-CurrentPod $service
        if (-not (Test-Ready $pod)) { throw "$service no está Ready antes del intento $trial" }
        $podName = $pod.metadata.name
        $container = $pod.status.containerStatuses[0]
        $beforeRestarts = [int]$container.restartCount
        $beforeId = [string]$container.containerID

        $processName = (& kubectl exec -n $namespace $podName -- sh -c 'cat /proc/1/comm').Trim()
        if ($LASTEXITCODE -ne 0 -or $processName -ne 'dotnet') {
            throw "PID 1 inesperado en ${podName}: $processName"
        }

        $runtimeId = $beforeId -replace '^containerd://', ''
        if ($runtimeId -notmatch '^[0-9a-f]{64}$') {
            throw "Container ID inesperado en ${podName}: $beforeId"
        }
        Write-Host "$service intento $trial/${Trials}: deteniendo contenedor $runtimeId de $podName"
        $startedAt = (Get-Date).ToUniversalTime()
        # PID 1 no recibe SIGKILL enviado desde su propio namespace. Detener el
        # contenedor desde CRI representa una caída del proceso sin borrar el pod.
        & minikube ssh -- sudo crictl stop --timeout 0 $runtimeId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "crictl no pudo detener $runtimeId" }

        $observedNotReady = $false
        $notReadyAt = $null
        $restartedAt = $null
        $recoveredAt = $null
        $lastPod = $null
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 1000
            $lastPod = Get-CurrentPod $service
            $sampleAt = (Get-Date).ToUniversalTime()
            if (-not (Test-Ready $lastPod)) {
                $observedNotReady = $true
                if (-not $notReadyAt) { $notReadyAt = $sampleAt }
            }
            $current = $lastPod.status.containerStatuses[0]
            $restarted = ([int]$current.restartCount -gt $beforeRestarts -and
                [string]$current.containerID -ne $beforeId)
            if ($restarted -and -not $restartedAt) { $restartedAt = $sampleAt }
            if ($restarted -and (Test-Ready $lastPod)) { $recoveredAt = $sampleAt; break }
        } while ((Get-Date) -lt $deadline)

        $result = [pscustomobject]@{
            service = $service
            trial = $trial
            pod = $podName
            injected_at_utc = $startedAt.ToString('o')
            observed_not_ready = $observedNotReady
            first_not_ready_at_utc = if ($notReadyAt) { $notReadyAt.ToString('o') } else { '' }
            restart_observed_at_utc = if ($restartedAt) { $restartedAt.ToString('o') } else { '' }
            ready_observed_at_utc = if ($recoveredAt) { $recoveredAt.ToString('o') } else { '' }
            recovery_seconds = if ($recoveredAt) { [math]::Round(($recoveredAt - $startedAt).TotalSeconds, 2) } else { '' }
            restart_count_before = $beforeRestarts
            restart_count_after = [int]$lastPod.status.containerStatuses[0].restartCount
            last_exit_code = $lastPod.status.containerStatuses[0].lastState.terminated.exitCode
            result = if ($recoveredAt) { 'recovered' } else { 'timeout' }
        }
        $result | Export-Csv -LiteralPath $outputPath -NoTypeInformation -Append -Encoding utf8
        $result | Format-Table service,trial,recovery_seconds,result -AutoSize

        if (-not $recoveredAt) { throw "Timeout en $service intento $trial. Evidencia: $outputPath" }
        if ($trial -lt $Trials) {
            Write-Host "Reemplazando $podName para aislar el siguiente intento"
            & kubectl delete pod -n $namespace $podName --wait=false | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "No se pudo reemplazar $podName" }
            Wait-NewReadyPod $service $podName | Out-Null
        }
    }
}

Write-Host "Evidencia: $outputPath"
