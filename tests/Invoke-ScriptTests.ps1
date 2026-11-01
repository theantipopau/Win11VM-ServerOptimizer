#Requires -Version 5.1
<#
.SYNOPSIS
    Contract tests for the Win11VM Server Optimizer scripts.

.DESCRIPTION
    Checks the things that are easy to let drift and expensive to get wrong when the scripts are
    only ever run on a real machine: that every script parses, that comment-based help matches the
    real parameter list, that the version in each script matches its newest CHANGELOG entry and the
    README, that the two scripts that share a change-record format agree on the schema version, that
    anything counting errors also exits nonzero, and that each .bat launcher points at a script that
    exists and propagates its exit code.

    Deliberately has no dependencies (no Pester, no PSScriptAnalyzer) so it runs anywhere PowerShell
    runs, including the GitHub Actions workflow in .github/workflows/ci.yml.

.PARAMETER ProjectRoot
    Repository root to test. Defaults to the parent of this script's folder.

.EXAMPLE
    .\tests\Invoke-ScriptTests.ps1
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = ''
)

$ErrorActionPreference = 'Stop'

# Resolved in the body rather than as a parameter default: PowerShell 5.1 does not populate
# $PSScriptRoot while evaluating parameter defaults for a script.
if (-not $ProjectRoot) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
if (-not $ProjectRoot) {
    $ProjectRoot = (Get-Location).Path
}
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

function Write-Section {
    param([string]$Name)
    Write-Host ''
    Write-Host ('== {0} ==' -f $Name) -ForegroundColor Cyan
}

function Get-ParsedScript {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    return [pscustomobject]@{
        Path   = $Path
        Name   = Split-Path -Leaf $Path
        Text   = (Get-Content -LiteralPath $Path -Raw)
        Ast    = $ast
        Errors = @($parseErrors)
    }
}

function Get-DeclaredParameter {
    param($Ast)
    if (-not $Ast.ParamBlock) { return @() }
    return @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

function Get-DocumentedParameter {
    param([string]$Text)
    return @([regex]::Matches($Text, '(?m)^\.PARAMETER\s+(\S+)') | ForEach-Object { $_.Groups[1].Value })
}

$scriptsDir = Join-Path $ProjectRoot 'scripts'
if (-not (Test-Path -LiteralPath $scriptsDir)) {
    Write-Host ("Could not find a scripts folder at '{0}'." -f $scriptsDir) -ForegroundColor Red
    exit 1
}

$scriptFiles = @(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1' -File | Sort-Object Name)
$batFiles = @(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.bat' -File | Sort-Object Name)
$readmePath = Join-Path $ProjectRoot 'README.md'
$changelogPath = Join-Path $ProjectRoot 'CHANGELOG.md'

Write-Host ('Win11VM Server Optimizer - script contract tests' ) -ForegroundColor Cyan
Write-Host ('Project root: {0}' -f $ProjectRoot)

Test-Case -Name 'scripts folder contains at least one script' -Condition ($scriptFiles.Count -gt 0)
Test-Case -Name 'README.md exists' -Condition (Test-Path -LiteralPath $readmePath)
Test-Case -Name 'CHANGELOG.md exists' -Condition (Test-Path -LiteralPath $changelogPath)

$readme = if (Test-Path -LiteralPath $readmePath) { Get-Content -LiteralPath $readmePath -Raw } else { '' }
$changelog = if (Test-Path -LiteralPath $changelogPath) { Get-Content -LiteralPath $changelogPath -Raw } else { '' }

$parsed = @{}
foreach ($file in $scriptFiles) {
    $parsed[$file.Name] = Get-ParsedScript -Path $file.FullName
}

# ---------------------------------------------------------------------------
Write-Section 'Parsing'
# ---------------------------------------------------------------------------
foreach ($name in $parsed.Keys) {
    $entry = $parsed[$name]
    $detail = ($entry.Errors | ForEach-Object { 'line ' + $_.Extent.StartLineNumber + ': ' + $_.Message }) -join '; '
    Test-Case -Name ("{0} parses without errors" -f $name) -Condition ($entry.Errors.Count -eq 0) -Detail $detail
    Test-Case -Name ("{0} is ASCII-only (no BOM means PowerShell 5.1 would misread non-ASCII)" -f $name) `
        -Condition (@([System.IO.File]::ReadAllBytes($entry.Path) | Where-Object { $_ -gt 127 }).Count -eq 0)
}

# ---------------------------------------------------------------------------
Write-Section 'Requires statements'
# ---------------------------------------------------------------------------
foreach ($name in $parsed.Keys) {
    $text = $parsed[$name].Text
    Test-Case -Name ("{0} requires PowerShell 5.1" -f $name) -Condition ($text -match '(?m)^#Requires -Version 5\.1\s*$')
    Test-Case -Name ("{0} requires an elevated session" -f $name) -Condition ($text -match '(?m)^#Requires -RunAsAdministrator\s*$')
}

# ---------------------------------------------------------------------------
Write-Section 'Comment-based help'
# ---------------------------------------------------------------------------
foreach ($name in $parsed.Keys) {
    $text = $parsed[$name].Text
    foreach ($section in @('.SYNOPSIS', '.DESCRIPTION', '.EXAMPLE')) {
        Test-Case -Name ("{0} documents {1}" -f $name, $section) -Condition ($text -match ('(?m)^' + [regex]::Escape($section) + '\s*$'))
    }
}

# ---------------------------------------------------------------------------
Write-Section 'Parameters match documented help'
# ---------------------------------------------------------------------------
foreach ($name in $parsed.Keys) {
    $declared = @(Get-DeclaredParameter -Ast $parsed[$name].Ast)
    $documented = @(Get-DocumentedParameter -Text $parsed[$name].Text)

    $undocumented = @($declared | Where-Object { $documented -notcontains $_ })
    $orphaned = @($documented | Where-Object { $declared -notcontains $_ })

    Test-Case -Name ("{0} has at least one parameter" -f $name) -Condition ($declared.Count -gt 0)
    Test-Case -Name ("{0} documents every parameter" -f $name) -Condition ($undocumented.Count -eq 0) -Detail ('undocumented: ' + ($undocumented -join ', '))
    Test-Case -Name ("{0} has no help for parameters that no longer exist" -f $name) -Condition ($orphaned.Count -eq 0) -Detail ('stale: ' + ($orphaned -join ', '))

    $missingFromReadme = @($declared | Where-Object { $readme -notmatch ('-' + [regex]::Escape($_) + '\b') })
    Test-Case -Name ("{0} parameters are all described in README.md" -f $name) -Condition ($missingFromReadme.Count -eq 0) -Detail ('missing from README: ' + ($missingFromReadme -join ', '))
}

# ---------------------------------------------------------------------------
Write-Section 'Version consistency'
# ---------------------------------------------------------------------------
$scriptVersion = @{}
foreach ($name in $parsed.Keys) {
    $match = [regex]::Match($parsed[$name].Text, "\`$script:ScriptVersion\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'")
    Test-Case -Name ("{0} declares a version" -f $name) -Condition $match.Success
    if ($match.Success) { $scriptVersion[$name] = $match.Groups[1].Value }
}

$latestChangelog = @{}
foreach ($entry in [regex]::Matches($changelog, '(?m)^##\s+\[(?<version>[0-9]+\.[0-9]+\.[0-9]+)\][^\r\n]*\((?<script>[^)\r\n]+)\)')) {
    $scriptName = $entry.Groups['script'].Value.Trim()
    if (-not $latestChangelog.ContainsKey($scriptName)) {
        $latestChangelog[$scriptName] = $entry.Groups['version'].Value
    }
}

foreach ($name in $scriptVersion.Keys) {
    Test-Case -Name ("{0} has a CHANGELOG entry" -f $name) -Condition $latestChangelog.ContainsKey($name)
    if ($latestChangelog.ContainsKey($name)) {
        Test-Case -Name ("{0} version {1} matches its newest CHANGELOG entry" -f $name, $scriptVersion[$name]) `
            -Condition ($latestChangelog[$name] -eq $scriptVersion[$name]) `
            -Detail ('CHANGELOG has ' + $latestChangelog[$name])
    }
}

$readmeVersion = [regex]::Match($readme, '\*\*Current version:\s*v([0-9]+\.[0-9]+\.[0-9]+)\*\*')
Test-Case -Name 'README states the current version' -Condition $readmeVersion.Success
if ($readmeVersion.Success -and $scriptVersion.ContainsKey('Win11VM-ServerOptimizer.ps1')) {
    Test-Case -Name 'README version matches the optimizer version' `
        -Condition ($readmeVersion.Groups[1].Value -eq $scriptVersion['Win11VM-ServerOptimizer.ps1']) `
        -Detail ('README has ' + $readmeVersion.Groups[1].Value + ', script has ' + $scriptVersion['Win11VM-ServerOptimizer.ps1'])
}

# ---------------------------------------------------------------------------
Write-Section 'Shared change-record schema'
# ---------------------------------------------------------------------------
$optimizerName = 'Win11VM-ServerOptimizer.ps1'
$restoreName = 'Restore-ServerDefaults.ps1'
foreach ($name in @($optimizerName, $restoreName)) {
    Test-Case -Name ("{0} exists" -f $name) -Condition $parsed.ContainsKey($name)
}
if ($parsed.ContainsKey($optimizerName) -and $parsed.ContainsKey($restoreName)) {
    $optimizerSchema = [regex]::Match($parsed[$optimizerName].Text, '\$script:StateSchemaVersion\s*=\s*(\d+)')
    $restoreSchema = [regex]::Match($parsed[$restoreName].Text, '\$script:StateSchemaVersion\s*=\s*(\d+)')
    Test-Case -Name 'optimizer declares a change-record schema version' -Condition $optimizerSchema.Success
    Test-Case -Name 'restore script declares a change-record schema version' -Condition $restoreSchema.Success
    if ($optimizerSchema.Success -and $restoreSchema.Success) {
        Test-Case -Name 'optimizer and restore script agree on the change-record schema version' `
            -Condition ($optimizerSchema.Groups[1].Value -eq $restoreSchema.Groups[1].Value) `
            -Detail ('optimizer ' + $optimizerSchema.Groups[1].Value + ', restore ' + $restoreSchema.Groups[1].Value)
    }
}

# ---------------------------------------------------------------------------
Write-Section 'Failure reporting contract'
# ---------------------------------------------------------------------------
foreach ($name in $parsed.Keys) {
    $text = $parsed[$name].Text
    if ($text -match '\$script:errors\+\+') {
        Test-Case -Name ("{0} exits nonzero when actions failed" -f $name) -Condition ($text -match '(?m)^if \(\$script:errors -gt 0\) \{') 
        Test-Case -Name ("{0} exits 0 on success" -f $name) -Condition ($text -match '(?m)^exit 0\s*$')
    }
    Test-Case -Name ("{0} writes a summary including the error count" -f $name) -Condition ($text -match 'error\(s\)')
}

# ---------------------------------------------------------------------------
Write-Section 'Launchers'
# ---------------------------------------------------------------------------
Test-Case -Name 'scripts folder contains a launcher for every script' -Condition ($batFiles.Count -ge $scriptFiles.Count)
foreach ($bat in $batFiles) {
    $batText = Get-Content -LiteralPath $bat.FullName -Raw
    $reference = [regex]::Match($batText, '-File\s+"%SCRIPT_DIR%([^"%]+\.ps1)"')
    Test-Case -Name ("{0} invokes a PowerShell script" -f $bat.Name) -Condition $reference.Success
    if ($reference.Success) {
        $target = Join-Path $scriptsDir $reference.Groups[1].Value
        Test-Case -Name ("{0} points at an existing script ({1})" -f $bat.Name, $reference.Groups[1].Value) -Condition (Test-Path -LiteralPath $target)
    }
    Test-Case -Name ("{0} propagates the script exit code" -f $bat.Name) -Condition ($batText -match '(?m)^exit /b %RC%')
    # cmd.exe mis-handles goto/labels in a batch file that uses bare LF line endings.
    Test-Case -Name ("{0} uses CRLF line endings" -f $bat.Name) -Condition ($batText -notmatch '(?<!\r)\n')
}

# ---------------------------------------------------------------------------
Write-Section 'Summary'
# ---------------------------------------------------------------------------
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
