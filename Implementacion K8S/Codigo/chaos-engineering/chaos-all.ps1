# Chaos: ejecuta en orden las 6 fallas pedidas por la letra y registra T0/T_fin de cada una.
# Uso: .\chaos-all.ps1 [-Target pharmago-pharmacy-service] [-Pause 60] [-Requests 500]
# Requiere: kubectl con acceso al cluster, Git Bash/WSL con `sh` en el PATH para los
# scripts base (cpu/ram/volume/load) y port-forward del gateway activo (puerto 5000).
# Salida: docs/evidencias/chaos-run-<fecha>.csv (fase, T0, T_fin, codigo de salida).
param(
  [string]$Target = 'pharmago-pharmacy-service',
  [int]$Pause = 60,
  [int]$Requests = 500,
  [int]$CpuSecs = 30,
  [int]$RamMb = 320,
  [int]$RamSecs = 30,
  [int]$DiskMb = 300,
  [int]$NetSecs = 30,
  [int]$DownSecs = 30
)
$ns = 'pharmago'
$dir = $PSScriptRoot
$outDir = Join-Path $dir '..\..\..\docs\evidencias'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir ("chaos-run-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date).ToUniversalTime())
'fase,target,t0_utc,t_fin_utc,codigo_salida' | Set-Content -Path $out -Encoding utf8

kubectl get deploy $Target -n $ns *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Error: no existe el deployment $Target en el namespace $ns (o no hay acceso al cluster)."
  exit 1
}
if (-not (Get-Command sh -ErrorAction SilentlyContinue)) {
  Write-Host 'Error: hace falta `sh` (Git Bash o WSL) para los scripts base de CPU/RAM/volumen/requests.'
  exit 1
}

function Get-Now { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Clear-PodFiles {
  $pod = kubectl get pod -n $ns -l app=$Target -o jsonpath='{.items[0].metadata.name}' 2>$null
  if ($pod) {
    kubectl exec -n $ns $pod -- rm -f /dev/shm/fill /tmp/fill /tmp/chaos_fill 2>$null
    # Red de seguridad: cpu-spike.sh ya detiene sus bucles (trap); esto cubre una interrupcion a mitad de fase.
    # (el patron do[n]e evita que el propio comando se mate a si mismo)
    $kill = 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline 2>/dev/null | grep -q "while :;do :;do[n]e" && kill -9 ${p#/proc/} 2>/dev/null; done; true'
    kubectl exec -n $ns $pod -- sh -c $kill 2>$null
  }
}

function Invoke-Phase([string]$Name, [scriptblock]$Action) {
  $t0 = Get-Now
  Write-Host "=== [$Name] T0=$t0 ==="
  & $Action
  $rc = $LASTEXITCODE
  $tf = Get-Now
  "$Name,$Target,$t0,$tf,$rc" | Add-Content -Path $out -Encoding utf8
  Write-Host "=== [$Name] fin $tf (codigo $rc). Pausa ${Pause}s para observar la recuperacion ==="
  Start-Sleep -Seconds $Pause
}

Write-Host "Registro: $out"
try {
  Invoke-Phase 'requests'    { sh "$dir/load-requests.sh" $Requests }
  Invoke-Phase 'cpu'         { sh "$dir/cpu-spike.sh" $Target $CpuSecs }
  Invoke-Phase 'memoria'     { sh "$dir/ram-spike.sh" $Target $RamMb $RamSecs }
  Clear-PodFiles
  Invoke-Phase 'storage'     { sh "$dir/volume-spike.sh" $Target $DiskMb }
  Clear-PodFiles
  Invoke-Phase 'red'         { & "$dir\network-cut.ps1" -Deployment $Target -Seconds $NetSecs }
  Invoke-Phase 'desconexion' { & "$dir\disconnect-component.ps1" -Deployment $Target -Mode scale -Seconds $DownSecs }
}
finally {
  Clear-PodFiles
  & "$dir\network-cut.ps1" -Deployment $Target -Restore
}
Write-Host "Terminado. Resultados en $out"
