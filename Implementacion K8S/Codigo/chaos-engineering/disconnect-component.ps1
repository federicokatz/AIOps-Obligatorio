# Chaos: desconecta un componente interno de la aplicacion.
# Uso:
#   .\disconnect-component.ps1 [-Deployment pharmago-pharmacy-service] [-Mode scale|pod] [-Seconds 30]
#   scale: escala a 0 durante N segundos y devuelve las replicas originales.
#   pod:   borra los pods; Kubernetes los recrea (mide el self healing).
param(
  [string]$Deployment = 'pharmago-pharmacy-service',
  [ValidateSet('scale','pod')][string]$Mode = 'scale',
  [int]$Seconds = 30
)
$ns = 'pharmago'

kubectl get deploy $Deployment -n $ns *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Error: no existe el deployment $Deployment en el namespace $ns."
  exit 1
}

function Get-Now { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

if ($Mode -eq 'pod') {
  Write-Host "Desconexion (borrar pods): $Deployment T0=$(Get-Now)"
  kubectl delete pod -n $ns -l app=$Deployment --wait=false
  Write-Host "Kubernetes recrea el pod. Seguir con: kubectl get pods -n $ns -l app=$Deployment -w"
  exit 0
}

$orig = kubectl get deploy $Deployment -n $ns -o jsonpath='{.spec.replicas}'
if (-not $orig -or $orig -eq '0') { $orig = 1 }

try {
  Write-Host "Desconexion (escalar a 0): $Deployment por ${Seconds}s, replicas originales: $orig, T0=$(Get-Now)"
  kubectl scale deploy $Deployment -n $ns --replicas=0
  Start-Sleep -Seconds $Seconds
}
finally {
  kubectl scale deploy $Deployment -n $ns --replicas=$orig
  Write-Host "Restaurado: $Deployment a $orig replica(s) T_fin=$(Get-Now)"
}
kubectl rollout status deploy/$Deployment -n $ns --timeout=180s
if ($LASTEXITCODE -ne 0) {
  Write-Host "NO recuperado en 180 s: $(Get-Now). Revisar: kubectl describe pod -n $ns -l app=$Deployment"
  exit 1
}
Write-Host "Recuperado (READY): $(Get-Now)"
