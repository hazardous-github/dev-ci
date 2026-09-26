[CmdletBinding(DefaultParameterSetName = 'Direct')]
param(
    [Parameter(ParameterSetName = 'Request', Mandatory = $true)]
    [string]$RequestPath,

    [Parameter(ParameterSetName = 'Direct', Mandatory = $true)]
    [string]$Target,

    [Parameter(ParameterSetName = 'Direct', Mandatory = $true)]
    [string]$Revision,

    [Parameter(ParameterSetName = 'Direct', Mandatory = $true)]
    [string]$Suite,

    [Parameter(Mandatory = $true)]
    [string]$RunId,

    [string]$ControlRoot
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

if ($PSCmdlet.ParameterSetName -eq 'Request') {
    if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
        throw 'Request file was not found.'
    }

    $request = Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json
    $Target = [string]$request.target
    $Revision = [string]$request.revision
    $Suite = [string]$request.suite
}

Assert-OpaqueIdentifier -Value $Target -Name 'target'
Assert-OpaqueIdentifier -Value $Suite -Name 'suite'

if ($Revision -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'Invalid revision.'
}
if ($RunId -notmatch '^[0-9]+$') {
    throw 'Invalid run id.'
}

$controlRepository = [string]$env:DEV_CI_CONTROL_REPOSITORY
$token = [string]$env:DEV_CI_TOKEN

if ([string]::IsNullOrWhiteSpace($controlRepository) -or
    [string]::IsNullOrWhiteSpace($token)) {
    throw 'CI control credentials are not configured.'
}

$runnerTemp = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetTempPath()
}
else {
    $env:RUNNER_TEMP
}

$ownsControlRoot = [string]::IsNullOrWhiteSpace($ControlRoot)
if ($ownsControlRoot) {
    $ControlRoot = Join-Path $runnerTemp ('dev-ci-control-' + [guid]::NewGuid().ToString('N'))
    $authBytes = [System.Text.Encoding]::ASCII.GetBytes("x-access-token:$token")
    $authHeader = [Convert]::ToBase64String($authBytes)
    $controlUrl = "https://github.com/$controlRepository.git"

    $cloneOutput = & git -c "http.extraheader=AUTHORIZATION: basic $authHeader" clone --quiet --depth 1 $controlUrl $ControlRoot 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'Private control checkout failed.'
    }
}
elseif (-not (Test-Path -LiteralPath $ControlRoot -PathType Container)) {
    throw 'Prepared private control checkout was not found.'
}

try {
    $dispatcher = Join-Path $ControlRoot 'dev-ci\invoke.ps1'
    if (-not (Test-Path -LiteralPath $dispatcher -PathType Leaf)) {
        throw 'Private CI dispatcher was not found.'
    }

    # Deliberately capture private dispatcher output. Public logs receive only
    # the generic final status.
    $privateOutput = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $dispatcher -Target $Target -Revision $Revision -Suite $Suite -RunId $RunId *>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Host 'PASS'
        exit 0
    }

    Write-Host 'FAIL'
    exit $exitCode
}
finally {
    if ($ownsControlRoot -and (Test-Path -LiteralPath $ControlRoot)) {
        Remove-Item -LiteralPath $ControlRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
