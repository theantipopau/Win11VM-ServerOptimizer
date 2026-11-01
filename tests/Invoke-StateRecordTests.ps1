#Requires -Version 5.1
<#
.SYNOPSIS
    Behavioural tests for the optimizer's change-record (undo) logic.

.DESCRIPTION
    The change record is what makes Restore-ServerDefaults.ps1 trustworthy, and it's the one part of
    this project where a bug is silent: a record that loses an original value, or that overwrites it
    on a later run, only shows up when someone actually needs to undo something.

    These tests pull the real Initialize-State / Save-State / Get-StateRecord / Add-StateRecord
    functions out of the optimizer's AST (so they are the shipped code, not a copy) and exercise them
    against a throwaway file in the temp directory. Nothing on the system is touched and no
    administrator rights are needed.

.PARAMETER ProjectRoot
    Repository root to test. Defaults to the parent of this script's folder.

.EXAMPLE
    .\tests\Invoke-StateRecordTests.ps1
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = ''
)

$ErrorActionPreference = 'Stop'

if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

$script:checks = 0
$script:failures = @()

function Test-Case {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )
    $script:checks++
    if ($Condition) {
        Write-Host ('  PASS  {0}' -f $Name) -ForegroundColor DarkGreen
    } else {
        Write-Host ('  FAIL  {0}' -f $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ('        {0}' -f $Detail) -ForegroundColor Red }
        $script:failures += $Name
    }
}

$optimizerPath = Join-Path $ProjectRoot 'scripts/Win11VM-ServerOptimizer.ps1'
if (-not (Test-Path -LiteralPath $optimizerPath)) {
    Write-Host ("Could not find the optimizer at '{0}'." -f $optimizerPath) -ForegroundColor Red
    exit 1
}

Write-Host 'Win11VM Server Optimizer - change-record behaviour tests' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Pull the real functions out of the script rather than reimplementing them.
# ---------------------------------------------------------------------------
$wanted = @('Initialize-State', 'Save-State', 'Get-StateRecord', 'Add-StateRecord')
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($optimizerPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors) {
    Write-Host 'Optimizer does not parse - aborting.' -ForegroundColor Red
    exit 1
}

$definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $node.Name }, $false))
Test-Case -Name 'change-record functions are present in the optimizer' -Condition ($definitions.Count -eq $wanted.Count) -Detail ("found: " + (($definitions | ForEach-Object { $_.Name }) -join ', '))
if ($definitions.Count -ne $wanted.Count) {
    Write-Host 'Cannot continue without all change-record functions.' -ForegroundColor Red
    exit 1
}

# Dot-sourced rather than Invoke-Expression so the definitions land in this script's scope and
# avoid the analyzer's legitimate warning about Invoke-Expression.
. ([scriptblock]::Create((($definitions | ForEach-Object { $_.Extent.Text }) -join "`r`n")))

# Stand-ins for the pieces the functions expect from the script they normally live in.
$script:StateSchemaVersion = 1
$script:ScriptVersion = '0.0.0-test'
$script:DryRun = $false
$script:errors = 0
$script:logLines = @()

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $script:logLines += ('[{0}] {1}' -f $Level, $Message)
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('w11vm-state-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$StatePath = Join-Path $tempDir 'state.json'

function Read-Record {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

try {
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '== Fresh record ==' -ForegroundColor Cyan
    # -----------------------------------------------------------------------
    Initialize-State
    Test-Case -Name 'creates an in-memory record when no file exists' -Condition ($null -ne $script:state)
    Test-Case -Name 'starts at the current schema version' -Condition ($script:state.schemaVersion -eq $script:StateSchemaVersion)
    Test-Case -Name 'starts with empty collections' -Condition (@($script:state.services).Count -eq 0 -and @($script:state.registry).Count -eq 0)
    Test-Case -Name 'does not write a file just by initialising' -Condition (-not (Test-Path -LiteralPath $StatePath))

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '== Recording and persisting ==' -ForegroundColor Cyan
    # -----------------------------------------------------------------------
    Add-StateRecord -Collection 'services' -Record ([pscustomobject]@{
            name              = 'WSearch'
            originalStartType = 'Automatic'
            originalStatus    = 'Running'
        })

    Test-Case -Name 'writes the record to disk as soon as a change is recorded' -Condition (Test-Path -LiteralPath $StatePath)

    $onDisk = Read-Record -Path $StatePath
    Test-Case -Name 'persists the recorded service' -Condition (@($onDisk.services).Count -eq 1)
    Test-Case -Name 'persists the original start type' -Condition ($onDisk.services[0].originalStartType -eq 'Automatic') -Detail ("got '" + $onDisk.services[0].originalStartType + "'")

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '== Re-run merge behaviour ==' -ForegroundColor Cyan
    # -----------------------------------------------------------------------
    $script:state = $null
    Initialize-State
    Test-Case -Name 'reloads an existing record instead of starting over' -Condition (@($script:state.services).Count -eq 1)
    Test-Case -Name 'keeps the original start type across a reload' -Condition ($script:state.services[0].originalStartType -eq 'Automatic')

    Add-StateRecord -Collection 'services' -Record ([pscustomobject]@{
            name              = 'SysMain'
            originalStartType = 'Automatic'
            originalStatus    = 'Running'
        })
    Add-StateRecord -Collection 'registry' -Record ([pscustomobject]@{
            path          = 'HKLM:\SYSTEM\Test'
            name          = 'NetworkThrottlingIndex'
            existed       = $true
            originalValue = -1
            type          = 'DWord'
        })
    Add-StateRecord -Collection 'registry' -Record ([pscustomobject]@{
            path          = 'HKLM:\SYSTEM\Test'
            name          = 'NewValue'
            existed       = $false
            originalValue = $null
            type          = 'DWord'
        })

    $script:state = $null
    Initialize-State
    Test-Case -Name 'accumulates services across re-runs' -Condition (@($script:state.services).Count -eq 2)
    Test-Case -Name 'accumulates registry values across re-runs' -Condition (@($script:state.registry).Count -eq 2)
    Test-Case -Name 'round-trips a negative DWORD unchanged' -Condition ($script:state.registry[0].originalValue -eq -1) -Detail ("got '" + $script:state.registry[0].originalValue + "'")
    Test-Case -Name 'round-trips a "did not exist" flag as a boolean' -Condition ($script:state.registry[1].existed -eq $false)
    Test-Case -Name 'round-trips a null original value' -Condition ($null -eq $script:state.registry[1].originalValue)
    Test-Case -Name 'records the schema version' -Condition ($script:state.schemaVersion -eq $script:StateSchemaVersion)

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '== Lookup ==' -ForegroundColor Cyan
    # -----------------------------------------------------------------------
    $found = Get-StateRecord -Collection 'services' -Match @{ name = 'WSearch' }
    Test-Case -Name 'finds a record by a single key' -Condition ($null -ne $found -and $found.name -eq 'WSearch')

    $found = Get-StateRecord -Collection 'registry' -Match @{ path = 'HKLM:\SYSTEM\Test'; name = 'NewValue' }
    Test-Case -Name 'finds a record by multiple keys' -Condition ($null -ne $found -and $found.name -eq 'NewValue')

    $missing = Get-StateRecord -Collection 'services' -Match @{ name = 'NotAService' }
    Test-Case -Name 'returns nothing for an unknown key' -Condition ($null -eq $missing)

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '== Corrupt record handling ==' -ForegroundColor Cyan
    # -----------------------------------------------------------------------
    Set-Content -LiteralPath $StatePath -Value '{ this is not json' -Encoding UTF8
    $script:state = $null
    $script:logLines = @()
    Initialize-State

    Test-Case -Name 'starts a fresh record when the file is unreadable' -Condition ($null -ne $script:state -and @($script:state.services).Count -eq 0)
    Test-Case -Name 'moves the unreadable file aside instead of silently overwriting it' -Condition (@(Get-ChildItem -LiteralPath $tempDir -Filter 'state.json.corrupt-*' -File).Count -eq 1)
    Test-Case -Name 'warns that earlier original values are no longer available' -Condition (@($script:logLines | Where-Object { $_ -match 'no longer available' }).Count -gt 0)

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '== Dry run ==' -ForegroundColor Cyan
    # -----------------------------------------------------------------------
    Remove-Item -LiteralPath (Join-Path $tempDir 'state.json') -Force -ErrorAction SilentlyContinue
    $script:DryRun = $true
    $script:state = $null
    Initialize-State
    Add-StateRecord -Collection 'services' -Record ([pscustomobject]@{ name = 'WSearch'; originalStartType = 'Automatic'; originalStatus = 'Running' })
    Test-Case -Name 'dry run never writes a change record' -Condition (-not (Test-Path -LiteralPath $StatePath))
    Test-Case -Name 'dry run still tracks what it would have recorded' -Condition (@($script:state.services).Count -eq 1)
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Summary ==' -ForegroundColor Cyan
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host ('All {0} checks passed.' -f $script:checks) -ForegroundColor Green
    exit 0
}

Write-Host ('{0} of {1} checks failed:' -f $script:failures.Count, $script:checks) -ForegroundColor Red
foreach ($failure in $script:failures) {
    Write-Host ('  - {0}' -f $failure) -ForegroundColor Red
}
exit 1
