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

    # Drift guard: a collection added to the change record but never read by the restore script would
    # be recorded and silently ignored - the exact failure mode the record exists to prevent.
    $written = @()
    $written += @([regex]::Matches($parsed[$optimizerName].Text, "Add-StateRecord\s+-Collection\s+'([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value })
    $written += @([regex]::Matches($parsed[$optimizerName].Text, '\$script:state\.([A-Za-z]+)\s*=') | ForEach-Object { $_.Groups[1].Value })
    $written = @($written | Sort-Object -Unique)
    $read = @([regex]::Matches($parsed[$restoreName].Text, '\$state\.([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $unhandled = @($written | Where-Object { $read -notcontains $_ })

    Test-Case -Name 'change-record collections are found in both scripts' -Condition ($written.Count -gt 0 -and $read.Count -gt 0) -Detail ("optimizer writes: " + ($written -join ', '))
    Test-Case -Name 'restore reads every change-record collection the optimizer writes' -Condition ($unhandled.Count -eq 0) -Detail ('not read by restore: ' + ($unhandled -join ', '))
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

# Windows only creates HibernateEnabled once hibernation has been toggled, so reading it alone
# reports "off" on a machine where hibernation is on - and the record would then say it was never
# enabled. Both scripts have to resolve the default the key actually carries.
foreach ($name in @('Win11VM-ServerOptimizer.ps1', 'Restore-ServerDefaults.ps1')) {
    if (-not $parsed.ContainsKey($name)) { continue }
    Test-Case -Name ("{0} falls back to HibernateEnabledDefault when reading hibernation" -f $name) `
        -Condition ($parsed[$name].Text -match 'HibernateEnabledDefault')
}

# ---------------------------------------------------------------------------
Write-Section 'Profiles'
# ---------------------------------------------------------------------------
# A profile named in the ValidateSet but missing from the $Profiles table would be a silent no-op at
# runtime (the script exits 1, but only when someone actually passes it), so check the two together.
$optimizerName = 'Win11VM-ServerOptimizer.ps1'
if ($parsed.ContainsKey($optimizerName)) {
    $optimizerText = $parsed[$optimizerName].Text
    $profileSet = [regex]::Match($optimizerText, "ValidateSet\((?<set>[^)]*)\)")
    Test-Case -Name 'optimizer declares a profile set' -Condition $profileSet.Success
    if ($profileSet.Success) {
        $profileNames = @([regex]::Matches($profileSet.Groups['set'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        Test-Case -Name 'optimizer offers the documented profiles' `
            -Condition (($profileNames -join ',') -eq 'GameServer,MediaServer,FileShare') `
            -Detail ($profileNames -join ', ')
        foreach ($profileName in $profileNames) {
            Test-Case -Name ("profile {0} has a configuration entry" -f $profileName) `
                -Condition ($optimizerText -match ('(?m)^\s*' + [regex]::Escape($profileName) + '\s*=\s*@\{'))
        }
        Test-Case -Name 'a profile is applied to the service pass' -Condition ($optimizerText -match 'SkipServices')
        Test-Case -Name 'a profile is applied to the feature pass' -Condition ($optimizerText -match 'SkipFeatures')
    }
}

# ---------------------------------------------------------------------------
Write-Section 'Audit mode'
# ---------------------------------------------------------------------------
# The audit is only meaningful if the record says what the script set each registry value to, and the
# audit reads that same field. Check both halves so a rename cannot silently turn the comparison into
# "everything is fine".
if ($parsed.ContainsKey($optimizerName)) {
    $optimizerText = $parsed[$optimizerName].Text
    Test-Case -Name 'optimizer records the target value it writes' -Condition ($optimizerText -match 'targetValue\s*=\s*\$Value')
    Test-Case -Name 'audit compares against the recorded target' -Condition ($optimizerText -match '\$entry\.targetValue')
    Test-Case -Name 'audit exits nonzero when anything drifted' -Condition ($optimizerText -match 'if \(\$auditResult -ne 0\) \{ exit 1 \}')
    Test-Case -Name 'audit runs before any phase' -Condition ($optimizerText -match '(?s)if \(\$Audit\) \{.*?Invoke-Audit.*?exit 0\s*\}')
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
