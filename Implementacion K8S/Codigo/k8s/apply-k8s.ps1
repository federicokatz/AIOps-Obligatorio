# Despliega en el contexto actual de kubectl; local por defecto.
[CmdletBinding()]
param(
    [ValidateSet('local', 'multinode')]
    [Alias('Profile')]
    [string]$DeploymentProfile = 'local',
    [string[]]$BackendNodes = @(),
    [string]$FrontendNode,
    [string]$OpsNode,
    [switch]$RenderOnly,
    [switch]$SeedData
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
    $seedFile = Join-Path $PSScriptRoot '../Backend/seed-data.sql'
    if ($SeedData -and -not (Test-Path -LiteralPath $seedFile -PathType Leaf)) {
        throw "No existe el archivo de datos de prueba: $seedFile"
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
    if ($SeedData) {
        # La clave se toma dentro del contenedor, sin argumentos con contrasenas.
        $sqlRunner = @'
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
'@
        $sqlRunner = $sqlRunner.Replace("`r`n", "`n")
        $readySql = @'
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
'@
        function Invoke-DatabaseSql {
            param([string]$Sql)
            # Windows PowerShell usa ASCII para stdin por defecto: preservar UTF-8.
            $previousEncoding = $OutputEncoding
            $previousPreference = $ErrorActionPreference
            try {
                $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
                $ErrorActionPreference = 'Continue'
                $output = $Sql | & kubectl exec -i -n pharmago deployment/pharmago-db -- sh -c $sqlRunner 2>&1
                $code = $LASTEXITCODE
                return [pscustomobject]@{ ExitCode = $code; Output = $output }
            } finally {
                $OutputEncoding = $previousEncoding
                $ErrorActionPreference = $previousPreference
            }
        }
        Write-Host 'Esperando PharmaDb y sus tablas para cargar datos de prueba (hasta 300 s)...'
        $seedWatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $check = Invoke-DatabaseSql -Sql $readySql
            if ($check.ExitCode -eq 0) { break }
            if ($check.ExitCode -eq 127 -or $seedWatch.Elapsed.TotalSeconds -ge 300) {
                $check.Output | Out-Host
                throw 'No se pudo preparar el seed. Se requiere PharmaDb con su esquema; este paso no crea tablas ni borra datos.'
            }
            Start-Sleep -Seconds 5
        }
        Write-Host 'Ejecutando Backend/seed-data.sql...'
        $seedResult = Invoke-DatabaseSql -Sql ([System.IO.File]::ReadAllText($seedFile, [System.Text.Encoding]::UTF8))
        $seedResult.Output | Out-Host
        if ($seedResult.ExitCode -ne 0) { throw 'Fallo seed-data.sql. Revisar el error SQL antes de repetir la carga.' }
        Write-Host 'Datos de prueba cargados.'
    }
    Write-Host "Manifiestos aplicados con el perfil $DeploymentProfile. Verificar READY y ubicación:"
    Invoke-Kube -Arguments @('get', 'pods', '-n', 'pharmago', '-o', 'wide')
    Write-Host 'Acceso local: ./port-forward.sh.'
} finally {
    Pop-Location
}
