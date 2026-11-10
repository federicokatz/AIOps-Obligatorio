# Chaos: corta el trafico de red de un servicio con una NetworkPolicy de denegacion total.
# Uso:
#   .\network-cut.ps1 [-Deployment pharmago-pharmacy-service] [-Seconds 30]
#   .\network-cut.ps1 -Deployment pharmago-pharmacy-service -Restore
# ATENCION: la NetworkPolicy solo tiene efecto si el CNI del cluster la aplica
# (Calico, Cilium, etc.). Con el CNI por defecto de Minikube puede NO hacer nada.
# Alternativa: minikube start --cni=calico
param(
  [string]$Deployment = 'pharmago-pharmacy-service',
  [int]$Seconds = 30,
  [switch]$Restore
)
$ns = 'pharmago'
$policy = "chaos-cut-$Deployment"

function Remove-Cut {
  kubectl delete networkpolicy $policy -n $ns --ignore-not-found
  Write-Host "Red restaurada: $Deployment"
}

if ($Restore) { Remove-Cut; exit 0 }

kubectl get deploy $Deployment -n $ns *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Error: no existe el deployment $Deployment en el namespace $ns."
  exit 1
}

$cni = kubectl get pods -n kube-system 2>$null | Select-String -Pattern 'calico|cilium|weave|antrea'
if (-not $cni) {
  Write-Host 'AVISO: no se detecto un CNI que aplique NetworkPolicy (calico/cilium/weave/antrea).'
  Write-Host '       El corte podria no tener efecto. Seguimos igual.'
}

$yaml = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $policy
  labels:
    chaos: network-cut
spec:
  podSelector:
    matchLabels:
      app: $Deployment
  policyTypes: [Ingress, Egress]
"@

try {
  Write-Host ("Corte de red: {0} ({1}s) T0={2:yyyy-MM-ddTHH:mm:ssZ}" -f $Deployment, $Seconds, (Get-Date).ToUniversalTime())
  $yaml | kubectl apply -n $ns -f -
  Start-Sleep -Seconds $Seconds
}
finally {
  Remove-Cut
  Write-Host ("Fin del corte: {0:yyyy-MM-ddTHH:mm:ssZ}" -f (Get-Date).ToUniversalTime())
}
