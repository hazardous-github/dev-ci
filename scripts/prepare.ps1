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

$planner = Join-Path $controlRoot 'dev-ci\cache-plan.ps1'
if (-not (Test-Path -LiteralPath $planner -PathType Leaf)) {
    throw 'Private CI cache planner was not found.'
}

$planOutput = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $planner -Target $Target -Suite $Suite *>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw 'Private CI cache planning failed.'
}

$cacheKey = $planOutput.Trim()
if (-not [string]::IsNullOrWhiteSpace($cacheKey) -and
    $cacheKey -notmatch '^[A-Za-z0-9._-]{1,512}$') {
    throw 'Private CI cache planner returned an invalid key.'
}

"control-root=$controlRoot" | Out-File -FilePath $outputPath -Encoding utf8 -Append
"use-runner-dotnet=$(([bool]$suiteConfig.UseRunnerDotNet).ToString().ToLowerInvariant())" | Out-File -FilePath $outputPath -Encoding utf8 -Append

if ([string]::IsNullOrWhiteSpace($cacheKey)) {
    'cache-enabled=false' | Out-File -FilePath $outputPath -Encoding utf8 -Append
}
else {
    'cache-enabled=true' | Out-File -FilePath $outputPath -Encoding utf8 -Append
    "cache-key=$cacheKey" | Out-File -FilePath $outputPath -Encoding utf8 -Append
}
