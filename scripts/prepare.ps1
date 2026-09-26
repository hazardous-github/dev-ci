[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Revision,
    [Parameter(Mandatory = $true)][string]$Suite
)

$ErrorActionPreference = 'Stop'

function Assert-OpaqueIdentifier {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -notmatch '^[A-Za-z0-9._-]{1,64}$') {
        throw "Invalid $Name."
    }
}

function Get-PrivateControlFile {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$ControlRevision,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)]$Headers
    )

    $escapedPath = ($RelativePath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $uri = "https://api.github.com/repos/$Repository/contents/$escapedPath?ref=$ControlRevision"
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers

    if ([string]$response.type -ne 'file' -or
        [string]$response.encoding -ne 'base64' -or
        [string]::IsNullOrWhiteSpace([string]$response.content)) {
        throw 'Private control bundle contained an invalid file response.'
    }

    $bytes = [Convert]::FromBase64String(([string]$response.content -replace '\s', ''))
    [System.IO.File]::WriteAllBytes($Destination, $bytes)
}

Assert-OpaqueIdentifier -Value $Target -Name 'target'
Assert-OpaqueIdentifier -Value $Suite -Name 'suite'

if ($Revision -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'Invalid revision.'
}

$controlRepository = [string]$env:DEV_CI_CONTROL_REPOSITORY
$token = [string]$env:DEV_CI_TOKEN
$outputPath = [string]$env:GITHUB_OUTPUT

if ([string]::IsNullOrWhiteSpace($controlRepository) -or
    [string]::IsNullOrWhiteSpace($token)) {
    throw 'CI control credentials are not configured.'
}
if ([string]::IsNullOrWhiteSpace($outputPath)) {
    throw 'GitHub Actions output channel is unavailable.'
}

$runnerTemp = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetTempPath()
}
else {
    $env:RUNNER_TEMP
}

$controlRoot = Join-Path $runnerTemp ('dev-ci-control-' + [guid]::NewGuid().ToString('N'))
$controlDirectory = Join-Path $controlRoot 'dev-ci'
$headers = @{
    Authorization = "Bearer $token"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$authBytes = [System.Text.Encoding]::ASCII.GetBytes("x-access-token:$token")
$authHeader = [Convert]::ToBase64String($authBytes)

try {
    New-Item -ItemType Directory -Force -Path $controlDirectory | Out-Null

    $revisionResponse = Invoke-RestMethod `
        -Method Get `
        -Uri "https://api.github.com/repos/$controlRepository/commits/main" `
        -Headers $headers
    $controlRevision = [string]$revisionResponse.sha
    if ($controlRevision -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Private control revision could not be resolved.'
    }

    foreach ($fileName in @('config.psd1', 'cache-common.ps1', 'invoke.ps1')) {
        Get-PrivateControlFile `
            -Repository $controlRepository `
            -ControlRevision $controlRevision `
            -RelativePath "dev-ci/$fileName" `
            -Destination (Join-Path $controlDirectory $fileName) `
            -Headers $headers
    }

    $config = Import-PowerShellDataFile -LiteralPath (Join-Path $controlDirectory 'config.psd1')
    $targetConfig = $config.Targets[$Target]
    if ($null -eq $targetConfig) {
        throw 'Unknown CI target.'
    }

    $suiteConfig = $null
    foreach ($entry in $targetConfig.Suites.GetEnumerator()) {
        if ([string]::Equals(
            [string]$entry.Value.PublicId,
            $Suite,
            [System.StringComparison]::Ordinal
        )) {
            if ($null -ne $suiteConfig) {
                throw 'Duplicate public CI suite identifier.'
            }
            $suiteConfig = $entry.Value
        }
    }
    if ($null -eq $suiteConfig) {
        throw 'Unknown CI suite.'
    }

    "control-root=$controlRoot" | Out-File -FilePath $outputPath -Encoding utf8 -Append
    "use-runner-dotnet=$(([bool]$suiteConfig.UseRunnerDotNet).ToString().ToLowerInvariant())" | Out-File -FilePath $outputPath -Encoding utf8 -Append

    $pluginCompileCache = [bool]$suiteConfig.PluginCompileCache
    "plugin-cache-enabled=$($pluginCompileCache.ToString().ToLowerInvariant())" | Out-File -FilePath $outputPath -Encoding utf8 -Append

    if ($pluginCompileCache) {
        . (Join-Path $controlDirectory 'cache-common.ps1')

        $managedDependency = @(
            $suiteConfig.Dependencies |
                Where-Object { [string]$_.EnvironmentVariable -eq 'EL2_CI_MANAGED_RUNTIME' }
        )
        if ($managedDependency.Count -ne 1) {
            throw 'Plugin compile cache requires exactly one EL2 managed-runtime dependency.'
        }

        $managedRuntimeRevision = Resolve-CiDependencyRevision `
            -Definition $managedDependency[0] `
            -AuthHeader $authHeader

        if ($managedRuntimeRevision -notmatch '^[0-9a-f]{40}$') {
            throw 'Managed-runtime dependency did not resolve to a commit.'
        }

        "managed-runtime-revision=$managedRuntimeRevision" | Out-File -FilePath $outputPath -Encoding utf8 -Append
    }
}
catch {
    if (Test-Path -LiteralPath $controlRoot) {
        Remove-Item -LiteralPath $controlRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
