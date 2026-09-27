[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Request,
    [Parameter(Mandatory = $true)][string]$Slot
)

$ErrorActionPreference = 'Stop'
$apiRoot = 'https://api.github.com'

function New-GitHubHeaders {
    param([Parameter(Mandatory = $true)][string]$Token)

    return @{
        Authorization = "Bearer $Token"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Get-PrivateControlFile {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)]$Headers
    )

    $escapedPath = ($RelativePath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $uri = "$apiRoot/repos/$Repository/contents/${escapedPath}?ref=$Revision"
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
    if ([string]$response.type -ne 'file' -or
        [string]$response.encoding -ne 'base64' -or
        [string]::IsNullOrWhiteSpace([string]$response.content)) {
        throw 'Private control bundle contained an invalid file response.'
    }

    $bytes = [Convert]::FromBase64String(([string]$response.content -replace '\s', ''))
    [System.IO.File]::WriteAllBytes($Destination, $bytes)
}

if ($Request -notmatch '^[1-9][0-9]*$' -or $Slot -notmatch '^[0-9]+$') {
    throw 'Invalid public CI request reference.'
}

$requestId = [int]$Request
$slotNumber = [int]$Slot
$controlRepository = [string]$env:DEV_CI_CONTROL_REPOSITORY
$token = [string]$env:DEV_CI_TOKEN
$outputPath = [string]$env:GITHUB_OUTPUT

if ([string]::IsNullOrWhiteSpace($controlRepository) -or
    [string]::IsNullOrWhiteSpace($token) -or
    [string]::IsNullOrWhiteSpace($outputPath)) {
    throw 'CI control credentials are not configured.'
}

$headers = New-GitHubHeaders -Token $token
$issue = Invoke-RestMethod `
    -Method Get `
    -Uri "$apiRoot/repos/$controlRepository/issues/$requestId" `
    -Headers $headers
if ($null -ne $issue.pull_request -or [string]::IsNullOrWhiteSpace([string]$issue.body)) {
    throw 'Validation request record was invalid.'
}

$requestBody = [string]$issue.body | ConvertFrom-Json
$targetName = [string]$requestBody.target
$revision = [string]$requestBody.revision
$controlRevision = [string]$requestBody.control_revision
$validations = @($requestBody.validations | ForEach-Object { [string]$_ })

if ([int]$requestBody.schema -ne 1 -or
    [string]$requestBody.state -ne 'accepted' -or
    $targetName -notmatch '^[A-Za-z0-9._-]{1,64}$' -or
    $revision -notmatch '^[0-9a-fA-F]{40}$' -or
    $controlRevision -notmatch '^[0-9a-fA-F]{40}$' -or
    $slotNumber -lt 0 -or
    $slotNumber -ge $validations.Count) {
    throw 'Validation request record was invalid.'
}

$suiteName = $validations[$slotNumber]
if ($suiteName -notmatch '^[A-Za-z0-9._-]{1,64}$') {
    throw 'Validation request record was invalid.'
}

foreach ($value in @($targetName, $revision, $controlRevision, $suiteName)) {
    Write-Host "::add-mask::$value"
}

$runnerTemp = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetTempPath()
}
else {
    $env:RUNNER_TEMP
}

$controlRoot = Join-Path $runnerTemp 'dev-ci-control'
$controlDirectory = Join-Path $controlRoot 'dev-ci'
$stateRoot = Join-Path $runnerTemp 'dev-ci-state'
$statePath = Join-Path $stateRoot 'request.json'

Remove-Item -LiteralPath $controlRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $controlDirectory, $stateRoot | Out-Null

foreach ($fileName in @('config.psd1', 'cache-common.ps1', 'invoke.ps1', 'run-request.ps1')) {
    Get-PrivateControlFile `
        -Repository $controlRepository `
        -Revision $controlRevision `
        -RelativePath "dev-ci/$fileName" `
        -Destination (Join-Path $controlDirectory $fileName) `
        -Headers $headers
}

$configPath = Join-Path $controlDirectory 'config.psd1'
$configText = Get-Content -Raw -LiteralPath $configPath
$diagnosticsPattern = '(?m)^\s*DiagnosticsIssue\s*=\s*[0-9]+\s*$'
$diagnosticsMatches = [regex]::Matches($configText, $diagnosticsPattern)
if ($diagnosticsMatches.Count -ne 1) {
    throw 'Private diagnostics routing configuration was invalid.'
}
$configText = [regex]::Replace(
    $configText,
    $diagnosticsPattern,
    "    DiagnosticsIssue = $requestId",
    1
)
Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8

$config = Import-PowerShellDataFile -LiteralPath $configPath
$targetMatches = @(
    $config.Targets.GetEnumerator() |
        Where-Object { [string]$_.Value.Name -eq $targetName }
)
if ($targetMatches.Count -ne 1) {
    throw 'Unknown CI target.'
}

$targetEntry = $targetMatches[0]
$targetKey = [string]$targetEntry.Key
$targetConfig = $targetEntry.Value
$suiteConfig = $targetConfig.Suites[$suiteName]
if ($null -eq $suiteConfig) {
    throw 'Unknown CI validation.'
}

$sourceRepository = [string]$targetConfig.Repository
$publicSuiteId = [string]$suiteConfig.PublicId
if ($targetKey -notmatch '^[A-Za-z0-9._-]{1,64}$' -or
    $publicSuiteId -notmatch '^[A-Za-z0-9._-]{1,64}$' -or
    [string]::IsNullOrWhiteSpace($sourceRepository)) {
    throw 'Private CI mapping was invalid.'
}

foreach ($value in @($targetKey, $publicSuiteId, $sourceRepository)) {
    Write-Host "::add-mask::$value"
}

$state = [ordered]@{
    schema = 1
    request_id = $requestId
    slot = $slotNumber
    request_url = [string]$issue.html_url
    target_key = $targetKey
    source_repository = $sourceRepository
    revision = $revision.ToLowerInvariant()
    suite_name = $suiteName
    suite_transport_id = $publicSuiteId
    control_revision = $controlRevision.ToLowerInvariant()
    dependency_revisions = [ordered]@{}
}

"use-runner-dotnet=$(([bool]$suiteConfig.UseRunnerDotNet).ToString().ToLowerInvariant())" |
    Out-File -FilePath $outputPath -Encoding utf8 -Append

$pluginCompileCache = [bool]$suiteConfig.PluginCompileCache
"plugin-cache-enabled=$($pluginCompileCache.ToString().ToLowerInvariant())" |
    Out-File -FilePath $outputPath -Encoding utf8 -Append

if ($pluginCompileCache) {
    . (Join-Path $controlDirectory 'cache-common.ps1')

    $authBytes = [System.Text.Encoding]::ASCII.GetBytes("x-access-token:$token")
    $authHeader = [Convert]::ToBase64String($authBytes)
    $managedDependency = @(
        $suiteConfig.Dependencies |
            Where-Object { [string]$_.EnvironmentVariable -eq 'EL2_CI_MANAGED_RUNTIME' }
    )
    if ($managedDependency.Count -ne 1) {
        throw 'Plugin compile cache requires exactly one managed-runtime dependency.'
    }

    $managedRuntimeRevision = Resolve-CiDependencyRevision `
        -Definition $managedDependency[0] `
        -AuthHeader $authHeader
    if ($managedRuntimeRevision -notmatch '^[0-9a-f]{40}$') {
        throw 'Managed-runtime dependency did not resolve to a commit.'
    }

    Write-Host "::add-mask::$managedRuntimeRevision"
    $dependencyEnvironment = [string]$managedDependency[0].ResolvedRevisionEnvironmentVariable
    if ($dependencyEnvironment -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw 'Managed-runtime dependency revision environment mapping was invalid.'
    }

    $state.dependency_revisions[$dependencyEnvironment] = $managedRuntimeRevision
    $fingerprint = Get-CiDependencyCacheFingerprint `
        -Definition $managedDependency[0] `
        -ResolvedRevision $managedRuntimeRevision
    "managed-runtime-cache-key=$fingerprint" |
        Out-File -FilePath $outputPath -Encoding utf8 -Append
}

$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
