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
$authBytes = [System.Text.Encoding]::ASCII.GetBytes("x-access-token:$token")
$authHeader = [Convert]::ToBase64String($authBytes)
$controlUrl = "https://github.com/$controlRepository.git"

$cloneOutput = & git -c "http.extraheader=AUTHORIZATION: basic $authHeader" clone --quiet --depth 1 $controlUrl $controlRoot 2>&1
if ($LASTEXITCODE -ne 0) {
    throw 'Private control checkout failed.'
}

$config = Import-PowerShellDataFile -LiteralPath (Join-Path $controlRoot 'dev-ci\config.psd1')
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
    . (Join-Path $controlRoot 'dev-ci\cache-common.ps1')

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
