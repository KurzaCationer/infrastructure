<#
.SYNOPSIS
Creates namespace-scoped workload access and retrieves its reusable kubeconfig.
.DESCRIPTION
Run with an administrator kubeconfig. Requires kubectl and cluster connectivity.
Uses a persistent ServiceAccount token Secret so subsequent runs reuse credentials.
#>
[CmdletBinding()]
param(
    [string] $AdminKubeconfig = (Join-Path $HOME '.kube/kurza-infrastructure.yaml'),
    [string] $OutputPath = (Join-Path $HOME '.kube/showcase-portfolio.yaml')
)

$ErrorActionPreference = 'Stop'
$namespace = 'showcase-portfolio'
$identity = 'showcase-portfolio-deployer'
$secretName = "$identity-token"
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Invoke-Kubectl {
    param([string[]] $Arguments, [string] $InputJson)
    $cliArguments = @("--kubeconfig=$AdminKubeconfig", '--request-timeout=30s') + $Arguments
    if ($InputJson) {
        $result = $InputJson | & kubectl @cliArguments
    } else {
        $result = & kubectl @cliArguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl failed (exit $LASTEXITCODE): $($Arguments -join ' ')"
    }
    return ($result -join "`n")
}

function Apply-Resource {
    param($Resource)
    $null = Invoke-Kubectl -Arguments @('apply', '-f', '-') -InputJson ($Resource | ConvertTo-Json -Depth 20 -Compress)
}

Get-Command kubectl -ErrorAction Stop | Out-Null
$AdminKubeconfig = (Resolve-Path -LiteralPath $AdminKubeconfig).Path
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ($AdminKubeconfig -eq $OutputPath) {
    throw 'OutputPath must differ from AdminKubeconfig.'
}
if (Test-Path -LiteralPath $OutputPath) {
    $existing = Get-Item -LiteralPath $OutputPath -Force
    if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'OutputPath must be a regular file, not a directory or link.'
    }
}

# Copy only cluster connection details, never administrator user credentials.
$source = Invoke-Kubectl -Arguments @('config', 'view', '--minify', '--flatten', '--raw', '-o', 'json') | ConvertFrom-Json
$cluster = $source.clusters[0].cluster
if (-not $cluster.server -or -not $cluster.'certificate-authority-data' -or $cluster.'insecure-skip-tls-verify') {
    throw 'The administrator kubeconfig must contain a server and a verified certificate authority.'
}

$existingNamespace = Invoke-Kubectl -Arguments @('get', 'namespace', $namespace, '--ignore-not-found', '-o', 'name')
if (-not $existingNamespace) {
    $null = Invoke-Kubectl -Arguments @('create', 'namespace', $namespace)
}

Apply-Resource @{
    apiVersion = 'v1'; kind = 'ServiceAccount'
    metadata = @{ name = $identity; namespace = $namespace }
    automountServiceAccountToken = $false
}

$verbs = @('get', 'list', 'watch', 'create', 'update', 'patch', 'delete', 'deletecollection')
Apply-Resource @{
    apiVersion = 'rbac.authorization.k8s.io/v1'; kind = 'Role'
    metadata = @{ name = $identity; namespace = $namespace }
    rules = @(
        @{ apiGroups = @(''); resources = @('pods', 'pods/exec', 'pods/attach', 'pods/portforward', 'services', 'configmaps', 'secrets', 'persistentvolumeclaims', 'serviceaccounts'); verbs = $verbs },
        @{ apiGroups = @(''); resources = @('pods/log', 'events'); verbs = @('get', 'list', 'watch') },
        @{ apiGroups = @('apps'); resources = @('deployments', 'deployments/scale', 'statefulsets', 'statefulsets/scale', 'daemonsets', 'replicasets', 'replicasets/scale'); verbs = $verbs },
        @{ apiGroups = @('batch'); resources = @('jobs', 'cronjobs'); verbs = $verbs },
        @{ apiGroups = @('autoscaling'); resources = @('horizontalpodautoscalers'); verbs = $verbs },
        @{ apiGroups = @('policy'); resources = @('poddisruptionbudgets'); verbs = $verbs },
        @{ apiGroups = @('networking.k8s.io'); resources = @('ingresses', 'networkpolicies'); verbs = $verbs },
        @{ apiGroups = @('gateway.networking.k8s.io'); resources = @('httproutes', 'grpcroutes'); verbs = $verbs }
    )
}
Apply-Resource @{
    apiVersion = 'rbac.authorization.k8s.io/v1'; kind = 'RoleBinding'
    metadata = @{ name = $identity; namespace = $namespace }
    subjects = @(@{ kind = 'ServiceAccount'; name = $identity; namespace = $namespace })
    roleRef = @{ apiGroup = 'rbac.authorization.k8s.io'; kind = 'Role'; name = $identity }
}

$secretJson = Invoke-Kubectl -Arguments @('-n', $namespace, 'get', 'secret', $secretName, '--ignore-not-found', '-o', 'json')
if (-not $secretJson) {
    # Create only when missing: never replace or rotate an existing token.
    $null = Invoke-Kubectl -Arguments @('create', '-f', '-') -InputJson (@{
        apiVersion = 'v1'; kind = 'Secret'; type = 'kubernetes.io/service-account-token'
        metadata = @{
            name = $secretName; namespace = $namespace
            annotations = @{ 'kubernetes.io/service-account.name' = $identity }
        }
    } | ConvertTo-Json -Depth 10 -Compress)
}

$serviceAccount = Invoke-Kubectl -Arguments @('-n', $namespace, 'get', 'serviceaccount', $identity, '-o', 'json') | ConvertFrom-Json
$token = $null
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $secret = Invoke-Kubectl -Arguments @('-n', $namespace, 'get', 'secret', $secretName, '-o', 'json') | ConvertFrom-Json
    if ($secret.type -ne 'kubernetes.io/service-account-token' -or
        $secret.metadata.annotations.'kubernetes.io/service-account.name' -ne $identity) {
        throw "Existing Secret $secretName is not a token for $identity."
    }
    $boundUid = $secret.metadata.annotations.'kubernetes.io/service-account.uid'
    if ($boundUid -and $boundUid -ne $serviceAccount.metadata.uid) {
        throw "Existing Secret $secretName belongs to a different ServiceAccount UID."
    }
    if ($secret.data.token -and $boundUid -eq $serviceAccount.metadata.uid) {
        $token = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.data.token))
        break
    }
    Start-Sleep -Seconds 1
}
if (-not $token) { throw "Timed out waiting for the cluster to populate Secret $secretName." }

$config = @{
    apiVersion = 'v1'; kind = 'Config'
    clusters = @(@{ name = 'infrastructure'; cluster = $cluster })
    users = @(@{ name = $identity; user = @{ token = $token } })
    contexts = @(@{ name = $namespace; context = @{ cluster = 'infrastructure'; user = $identity; namespace = $namespace } })
    'current-context' = $namespace
}
$directory = Split-Path -Parent $OutputPath
$null = [IO.Directory]::CreateDirectory($directory)
$temporaryPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
try {
    # Restrict access before writing credentials. JSON is also valid kubeconfig YAML.
    [IO.File]::WriteAllText($temporaryPath, '', $utf8)
    if ($env:OS -eq 'Windows_NT') {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $null = & icacls $temporaryPath /inheritance:r /grant:r "*$($sid):(F)"
        if ($LASTEXITCODE -ne 0) { throw 'Could not restrict kubeconfig file permissions.' }
    } else {
        & chmod 600 $temporaryPath
        if ($LASTEXITCODE -ne 0) { throw 'Could not restrict kubeconfig file permissions.' }
    }
    [IO.File]::WriteAllText($temporaryPath, ($config | ConvertTo-Json -Depth 20), $utf8)
    Move-Item -LiteralPath $temporaryPath -Destination $OutputPath -Force
} finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}
Write-Host "Kubeconfig saved to $OutputPath (namespace: $namespace)."
