#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end round-trip test: optimise a throwaway Windows box, prove the change record matches
    reality, then prove Restore-ServerDefaults.ps1 puts everything back.

.DESCRIPTION
    Run this INSIDE a disposable Windows 11 VM or a Windows Sandbox - it deliberately applies the
    optimizer's real changes to the machine it runs on, which is why the caller must pass
    -IAmInAThrowawayMachine. Applying the optimizer to a machine you care about is the one thing
    this project keeps telling people not to do.

    The test is built around claims rather than around "the script said OK":

      1. Baseline snapshot, taken from the same catalogs the optimizer targets (pulled out of the
         optimizer's AST, so the test follows the script rather than a copy of its lists).
      2. Optimizer -DryRun. Nothing may change (service start types, features, tasks, registry,
         power, NIC power management), no change record may be written, and the log may not contain
         a single [OK] line - a dry run that claims to have done something is a bug.
      3. Optimizer for real. Then every item in the change record is checked against the live
         machine: it either really is in the new state, or the log has an [ERROR] naming it (a
         Windows-version limitation, reported as such rather than as a test failure).
      4. Optimizer again, immediately. This is the "re-run after Windows Update" case: the original
         values in the record must survive untouched, and the second run must do less work.
      5. Restore -DryRun. Nothing may change, and no [OK] lines.
      6. Restore for real. The machine must match the baseline again for everything reversible:
         service start types, features, capabilities, scheduled tasks, registry values, power scheme,
         hibernation, reserved storage and NIC power management. AppX packages are reported, not
         failed, because Windows has no supported way to re-add them.
      7. A Markdown report plus the raw JSON evidence, written to -OutputDir.

    Each step reports before/after values so a failure is actionable, and errors the run hit are
    listed separately so an environment limitation is not mistaken for a code bug.

.PARAMETER RepoRoot
    Repository root. Defaults to two levels above this script (tests\vm -> repository root).

.PARAMETER OutputDir
    Where to write the report, evidence and logs. Defaults to <repo>\artifacts\roundtrip-<timestamp>.

.PARAMETER IAmInAThrowawayMachine
    Required. Confirms the machine can be destroyed afterwards - the optimizer really does remove
    AppX packages, disable services and change the registry.

.PARAMETER SkipAppX
    Skip AppX capture and checks. Much faster, and useful when AppX enumeration is broken on a
    particular build, at the cost of no longer covering Phase 1 of the optimizer.

.PARAMETER Profile
    Optimizer profile to exercise. Defaults to GameServer, which is also the optimizer's default.
    Run the harness once per profile on separate fresh machines if you want all three covered.

.PARAMETER IncludeRestorePoint
    Also exercise -CreateRestorePoint. Off by default because System Restore is slow, is capped at
    one checkpoint per 24 hours, and is unavailable in Windows Sandbox.

.PARAMETER SelfTest
    Validate this harness without changing anything: extract the optimizer catalog, exercise the
    snapshot/diff logic with synthetic data, and exit. No admin required.

.EXAMPLE
    .\Invoke-RoundTripTest.ps1 -IAmInAThrowawayMachine

.EXAMPLE
    # Check the harness itself on any machine, including the host
    .\Invoke-RoundTripTest.ps1 -SelfTest
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Passing the optimizer''s -Profile through is the point; it shadows $PROFILE, which this harness never reads.')]
param(
    [string]$RepoRoot = '',
    [string]$OutputDir = '',
    [switch]$IAmInAThrowawayMachine,
    [switch]$SkipAppX,
    [switch]$IncludeRestorePoint,
    [ValidateSet('GameServer', 'MediaServer', 'FileShare')]
    [string]$Profile = 'GameServer',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if (-not $OutputDir) {
    $OutputDir = Join-Path $RepoRoot ('artifacts\roundtrip-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$optimizerPath = Join-Path $RepoRoot 'scripts\Win11VM-ServerOptimizer.ps1'
$restorePath = Join-Path $RepoRoot 'scripts\Restore-ServerDefaults.ps1'
$statePath = Join-Path $OutputDir 'state.json'
$scratchDir = Join-Path $OutputDir 'defender-scratch'

# ---------------------------------------------------------------------------
# Results and reporting
# ---------------------------------------------------------------------------
$script:results = New-Object System.Collections.ArrayList
$script:limitations = New-Object System.Collections.ArrayList

function Get-Verdict {
    param([bool]$Condition, [string]$WhenTrue = 'PASS', [string]$WhenFalse = 'FAIL')
    if ($Condition) { return $WhenTrue }
    return $WhenFalse
}

function Add-Result {
    param(
        [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')]
        [string]$Result,
        [string]$Name,
        [string]$Detail = ''
    )
    $null = $script:results.Add([pscustomobject]@{ result = $Result; name = $Name; detail = $Detail })
    $colour = switch ($Result) {
        'PASS' { 'DarkGreen' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    $line = '{0,-4} {1}' -f $Result, $Name
    if ($Detail) { $line += ' - ' + $Detail }
    Write-Host $line -ForegroundColor $colour
}

function Write-Section {
    param([string]$Name)
    Write-Host ''
    Write-Host ('== ' + $Name + ' ==') -ForegroundColor Cyan
}

function Get-ResultCount {
    param([string]$Result)
    return @($script:results | Where-Object { $_.result -eq $Result }).Count
}

# ---------------------------------------------------------------------------
# Reading the optimizer's own catalogs, so the test cannot drift from the script
# ---------------------------------------------------------------------------
function Get-ConstantValue {
    param($Ast)
    try {
        return $Ast.SafeGetValue()
    } catch {
        return $Ast.Extent.Text
    }
}

function Get-LiteralArray {
    param($Ast, [string]$VariableName)

    if (-not $VariableName) { return @() }

    # These catalogs are written as newline-separated @( ... ) entries, so each element parses as its
    # own statement inside an ArrayExpressionAst - there is no ArrayLiteralAst unless the list uses
    # commas. Collect the string constants from the array expression instead. The first assignment
    # that yields values wins, which skips later re-assignments like `$x = $x | Where-Object ...`.
    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq $VariableName
            }, $true))

    foreach ($assignment in $assignments) {
        $arrays = @($assignment.Right.FindAll({ param($node) $node -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true))
        if ($arrays.Count -eq 0) { continue }
        $values = @($arrays[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
        if ($values.Count -gt 0) { return $values }
    }
    return @()
}

function Get-OptimizerCatalog {
    param([string]$Path)

    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        throw ("Optimizer does not parse: " + (($parseErrors | ForEach-Object { $_.Message }) -join '; '))
    }

    # Registry values: every literal Set-RegValue call.
    $registry = @()
    $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-RegValue' }, $true))
    foreach ($call in $calls) {
        $path = $null
        $name = $null
        $hasValue = $false
        $value = $null

        for ($i = 0; $i -lt $call.CommandElements.Count; $i++) {
            $element = $call.CommandElements[$i]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }

            $argument = $element.Argument
            if (-not $argument) {
                if ($i + 1 -lt $call.CommandElements.Count) {
                    $argument = $call.CommandElements[$i + 1]
                } else {
                    continue
                }
            }

            switch ($element.ParameterName) {
                'Path' { $path = Get-ConstantValue -Ast $argument }
                'Name' { $name = Get-ConstantValue -Ast $argument }
                'Value' { $value = Get-ConstantValue -Ast $argument; $hasValue = $true }
            }
        }

        if ($path -and $name -and $hasValue) {
            $registry += [pscustomobject]@{ path = $path; name = $name; target = $value }
        }
    }

    # Capability families are matched with -like in the optimizer; pick up the literal patterns.
    $likePatterns = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Ilike -and
                $node.Right -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object { $_.Right.Value } | Where-Object { $_ -and $_ -notmatch '\$' })

    return [pscustomobject]@{
        services     = @(Get-LiteralArray -Ast $ast -VariableName '$servicesToDisable')
        features     = @(Get-LiteralArray -Ast $ast -VariableName '$featuresToDisable')
        tasks        = @(Get-LiteralArray -Ast $ast -VariableName '$tasksToDisable')
        appx         = @(Get-LiteralArray -Ast $ast -VariableName '$appxToRemove')
        registry     = @($registry)
        likePatterns = @($likePatterns)
    }
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------
function ConvertTo-StableState {
    param([string]$State)
    switch ($State) {
        'EnablePending' { return 'Enabled' }
        'DisablePending' { return 'Disabled' }
        'InstallPending' { return 'Installed' }
        'UninstallPending' { return 'NotPresent' }
        default { return $State }
    }
}

function New-EmptySnapshot {
    return [pscustomobject]@{
        takenAt         = $null
        services        = @()
        features        = @()
        capabilities    = @()
        tasks           = @()
        registry        = @()
        appx            = @()
        power           = [pscustomobject]@{ activeScheme = $null }
        hibernation     = $null
        reservedStorage = $null
        nic             = @()
    }
}

function Get-PowerScheme {
    try {
        $output = (& powercfg /getactivescheme) -join ' '
        if ($output -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            return $Matches[1].ToLowerInvariant()
        }
    } catch {
        Write-Verbose "Could not read the active power scheme: $($_.Exception.Message)"
    }
    return $null
}

function Get-ReservedStorageState {
    try {
        $text = ((& dism.exe /Online /Get-ReservedStorageState) -join ' ') -replace "`0", ' '
        if ($text -match 'Enabled') { return 'Enabled' }
        if ($text -match 'Disabled') { return 'Disabled' }
    } catch {
        Write-Verbose "Could not read reserved storage state: $($_.Exception.Message)"
    }
    return $null
}

function Get-Snapshot {
    param($Catalog, [switch]$SkipAppXCapture)

    $snapshot = New-EmptySnapshot
    $snapshot.takenAt = (Get-Date).ToString('o')

    $services = @{}
    foreach ($pattern in $Catalog.services) {
        foreach ($service in @(Get-Service -Name $pattern -ErrorAction SilentlyContinue)) {
            if ($services.ContainsKey($service.Name)) { continue }
            $services[$service.Name] = [pscustomobject]@{
                name      = $service.Name
                startType = $service.StartType.ToString()
                status    = $service.Status.ToString()
            }
        }
    }
    $snapshot.services = @($services.Values | Sort-Object name)

    $features = @()
    foreach ($feature in $Catalog.features) {
        $featureState = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
        if ($featureState) {
            $features += [pscustomobject]@{ name = $feature; state = (ConvertTo-StableState $featureState.State.ToString()) }
        }
    }
    $snapshot.features = @($features)

    $capabilities = @()
    if (@($Catalog.likePatterns).Count -gt 0) {
        $allCapabilities = @(Get-WindowsCapability -Online -ErrorAction SilentlyContinue)
        foreach ($pattern in $Catalog.likePatterns) {
            foreach ($capability in @($allCapabilities | Where-Object { $_.Name -like $pattern })) {
                $capabilities += [pscustomobject]@{ name = $capability.Name; state = (ConvertTo-StableState $capability.State.ToString()) }
            }
        }
    }
    $snapshot.capabilities = @($capabilities | Sort-Object name -Unique)

    $tasks = @()
    foreach ($task in $Catalog.tasks) {
        $taskName = Split-Path $task -Leaf
        $taskPath = (Split-Path $task -Parent) + '\'
        $taskObject = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
        if ($taskObject) {
            $tasks += [pscustomobject]@{ path = $taskPath; name = $taskName; state = $taskObject.State.ToString() }
        }
    }
    $snapshot.tasks = @($tasks | Sort-Object path, name)

    $registry = @()
    foreach ($target in $Catalog.registry) {
        $exists = $false
        $current = $null
        try {
            $key = Get-Item -LiteralPath $target.path -ErrorAction Stop
            if ($key.GetValueNames() -contains $target.name) {
                $exists = $true
                $current = $key.GetValue($target.name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        } catch [System.Management.Automation.ItemNotFoundException] {
            $exists = $false
        } catch [System.Security.SecurityException] {
            $exists = $false
        }
        $registry += [pscustomobject]@{ path = $target.path; name = $target.name; exists = $exists; value = $current }
    }
    $snapshot.registry = @($registry)

    if (-not $SkipAppXCapture) {
        $installedPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
        $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
        $appx = @()
        foreach ($app in $Catalog.appx) {
            $installed = @($installedPackages | Where-Object { $_.Name -eq $app }).Count -gt 0
            $provisioned = @($provisionedPackages | Where-Object { $_.DisplayName -like "$app*" }).Count -gt 0
            $appx += [pscustomobject]@{ name = $app; installed = ($installed -or $provisioned) }
        }
        $snapshot.appx = @($appx | Sort-Object name)
    }

    $snapshot.power = [pscustomobject]@{ activeScheme = (Get-PowerScheme) }
    # HibernateEnabled only exists once hibernation has been toggled, so a fresh VM has no value while
    # hibernation is on. Read the effective state the same way the scripts do, or the baseline records
    # $null, the restored machine records 1, and the diff reports a failure that never happened.
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    $hibernate = (Get-ItemProperty -LiteralPath $powerKey -Name 'HibernateEnabled' -ErrorAction SilentlyContinue).HibernateEnabled
    if ($null -eq $hibernate) {
        $hibernate = (Get-ItemProperty -LiteralPath $powerKey -Name 'HibernateEnabledDefault' -ErrorAction SilentlyContinue).HibernateEnabledDefault
    }
    if ($null -eq $hibernate) { $hibernate = 1 }
    $snapshot.hibernation = [int]$hibernate
    $snapshot.reservedStorage = Get-ReservedStorageState

    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PnPDeviceID })
    $powerDevices = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue)
    $nic = @()
    foreach ($adapter in $adapters) {
        foreach ($device in @($powerDevices | Where-Object { $_.InstanceName -like "$($adapter.PnPDeviceID)*" })) {
            $nic += [pscustomobject]@{ instanceName = $device.InstanceName; enable = [bool]$device.Enable }
        }
    }
    $snapshot.nic = @($nic | Sort-Object instanceName -Unique)

    return $snapshot
}

function Test-ValueEqual {
    param($A, $B)
    if ($null -eq $A -and $null -eq $B) { return $true }
    if ($null -eq $A -or $null -eq $B) { return $false }
    return ($A -eq $B)
}

function Compare-Snapshot {
    param($Baseline, $Current)

    $differences = New-Object System.Collections.ArrayList

    $names = @(@($Baseline.services.name) + @($Current.services.name) | Sort-Object -Unique)
    foreach ($name in $names) {
        $before = $Baseline.services | Where-Object { $_.name -eq $name } | Select-Object -First 1
        $after = $Current.services | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if (-not $before -or -not $after) {
            $null = $differences.Add([pscustomobject]@{ area = 'service'; item = $name; before = 'present'; after = 'absent' })
            continue
        }
        if ($before.startType -ne $after.startType) {
            $null = $differences.Add([pscustomobject]@{ area = 'service'; item = $name; before = $before.startType; after = $after.startType })
        }
        if ($before.status -ne $after.status) {
            $null = $differences.Add([pscustomobject]@{ area = 'service-status'; item = $name; before = $before.status; after = $after.status })
        }
    }

    foreach ($spec in @(@{ collection = 'features'; area = 'feature' }, @{ collection = 'capabilities'; area = 'capability' })) {
        foreach ($before in @($Baseline.($spec.collection))) {
            $after = $Current.($spec.collection) | Where-Object { $_.name -eq $before.name } | Select-Object -First 1
            if (-not $after) {
                $null = $differences.Add([pscustomobject]@{ area = $spec.area; item = $before.name; before = $before.state; after = 'absent' })
                continue
            }
            if ($before.state -ne $after.state) {
                $null = $differences.Add([pscustomobject]@{ area = $spec.area; item = $before.name; before = $before.state; after = $after.state })
            }
        }
    }

    foreach ($before in @($Baseline.tasks)) {
        $after = $Current.tasks | Where-Object { $_.path -eq $before.path -and $_.name -eq $before.name } | Select-Object -First 1
        if (-not $after) {
            $null = $differences.Add([pscustomobject]@{ area = 'task'; item = $before.name; before = $before.state; after = 'absent' })
            continue
        }
        if ($before.state -ne $after.state) {
            $null = $differences.Add([pscustomobject]@{ area = 'task'; item = $before.name; before = $before.state; after = $after.state })
        }
    }

    foreach ($before in @($Baseline.registry)) {
        $after = $Current.registry | Where-Object { $_.path -eq $before.path -and $_.name -eq $before.name } | Select-Object -First 1
        if (-not $after) {
            $null = $differences.Add([pscustomobject]@{ area = 'registry'; item = $before.name; before = $before.value; after = 'absent' })
            continue
        }
        if ($before.exists -ne $after.exists -or ($before.exists -and -not (Test-ValueEqual $before.value $after.value))) {
            $valueBefore = '<absent>'
            if ($before.exists) { $valueBefore = $before.value }
            $valueAfter = '<absent>'
            if ($after.exists) { $valueAfter = $after.value }
            $null = $differences.Add([pscustomobject]@{ area = 'registry'; item = ($before.path + '\' + $before.name); before = $valueBefore; after = $valueAfter })
        }
    }

    foreach ($before in @($Baseline.appx)) {
        $after = $Current.appx | Where-Object { $_.name -eq $before.name } | Select-Object -First 1
        if ($after -and $before.installed -ne $after.installed) {
            $null = $differences.Add([pscustomobject]@{ area = 'appx'; item = $before.name; before = $before.installed; after = $after.installed })
        }
    }

    if ($Baseline.power.activeScheme -ne $Current.power.activeScheme) {
        $null = $differences.Add([pscustomobject]@{ area = 'power'; item = 'active scheme'; before = $Baseline.power.activeScheme; after = $Current.power.activeScheme })
    }
    if ($Baseline.hibernation -ne $Current.hibernation) {
        $null = $differences.Add([pscustomobject]@{ area = 'hibernation'; item = 'HibernateEnabled'; before = $Baseline.hibernation; after = $Current.hibernation })
    }
    if ($Baseline.reservedStorage -ne $Current.reservedStorage) {
        $null = $differences.Add([pscustomobject]@{ area = 'reserved-storage'; item = 'reserved storage'; before = $Baseline.reservedStorage; after = $Current.reservedStorage })
    }

    foreach ($before in @($Baseline.nic)) {
        $after = $Current.nic | Where-Object { $_.instanceName -eq $before.instanceName } | Select-Object -First 1
        if ($after -and $before.enable -ne $after.enable) {
            $null = $differences.Add([pscustomobject]@{ area = 'nic'; item = $before.instanceName; before = $before.enable; after = $after.enable })
        }
    }

    return @($differences)
}

function Format-Difference {
    param($Difference)
    return ('{0}: {1} ({2} -> {3})' -f $Difference.area, $Difference.item, $Difference.before, $Difference.after)
}

function Format-DifferenceList {
    param($Differences)
    if (@($Differences).Count -eq 0) { return 'none' }
    return (@($Differences) | ForEach-Object { Format-Difference $_ }) -join '; '
}

# ---------------------------------------------------------------------------
# Running the scripts under test
# ---------------------------------------------------------------------------
function Invoke-TestScript {
    param(
        [string]$Path,
        [string[]]$Arguments,
        [string]$Label
    )

    $outputFile = Join-Path $OutputDir ("$Label.output.txt")
    Write-Host ("Running {0} {1}" -f (Split-Path -Leaf $Path), ($Arguments -join ' ')) -ForegroundColor DarkGray

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String)
    $text | Set-Content -LiteralPath $outputFile -Encoding UTF8

    return [pscustomobject]@{
        exitCode = $exitCode
        logPath  = $outputFile
        text     = $text
    }
}

function Read-LogText {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return (Get-Content -LiteralPath $Path -Raw)
    }
    return ''
}

function Get-LogCount {
    param([string]$Text, [string]$Level)
    return @([regex]::Matches($Text, '\[{0}\]' -f [regex]::Escape($Level))).Count
}

function Test-LogHasError {
    param([string]$Text, [string]$Identifier)
    if (-not $Identifier) { return $false }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '\[ERROR\]' -and $line.IndexOf($Identifier, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Test-Crashed {
    param([string]$Text)
    # A terminating PowerShell error prints a stack frame; ordinary script failures are [ERROR]
    # lines and do not look like this.
    return ($Text -match 'At line:\d+ char:' -or $Text -match 'ParserError')
}

function Test-CleanRun {
    param([pscustomobject]$Run, [string]$Label)

    Add-Result (Get-Verdict (-not (Test-Crashed -Text $Run.text))) ("$Label did not crash") -Detail 'output contains a PowerShell stack trace'
    if ($Run.exitCode -eq 0) {
        Add-Result PASS ("$Label exited 0")
    } elseif ($Run.exitCode -eq 1) {
        $errorCount = Get-LogCount -Text $Run.text -Level 'ERROR'
        Add-Result WARN ("$Label exited 1") -Detail "$errorCount logged error(s) - see $(Split-Path -Leaf $Run.logPath)"
    } else {
        Add-Result FAIL ("$Label exited with an unexpected code") -Detail "exit code $($Run.exitCode)"
    }
}

function Test-Catalog {
    param($Catalog)

    Add-Result (Get-Verdict ($Catalog.services.Count -gt 0)) 'catalog: services extracted' -Detail "$($Catalog.services.Count) patterns"
    Add-Result (Get-Verdict ($Catalog.features.Count -gt 0)) 'catalog: optional features extracted' -Detail "$($Catalog.features.Count) features"
    Add-Result (Get-Verdict ($Catalog.tasks.Count -gt 0)) 'catalog: scheduled tasks extracted' -Detail "$($Catalog.tasks.Count) tasks"
    Add-Result (Get-Verdict ($Catalog.appx.Count -gt 0)) 'catalog: AppX packages extracted' -Detail "$($Catalog.appx.Count) packages"
    Add-Result (Get-Verdict ($Catalog.registry.Count -ge 10)) 'catalog: registry targets extracted' -Detail "$($Catalog.registry.Count) values"
    Add-Result (Get-Verdict ($Catalog.likePatterns.Count -gt 0) 'PASS' 'WARN') 'catalog: capability patterns extracted' -Detail ($Catalog.likePatterns -join ', ')
}

# ---------------------------------------------------------------------------
# Self-test: exercise the harness without touching the system
# ---------------------------------------------------------------------------
if ($SelfTest) {
    Write-Host 'Round-trip harness self-test (no system changes)' -ForegroundColor Cyan

    Write-Section 'Catalog extraction'
    $catalog = Get-OptimizerCatalog -Path $optimizerPath
    Test-Catalog -Catalog $catalog

    Write-Section 'Diff engine'
    $baseline = New-EmptySnapshot
    $baseline.services = @([pscustomobject]@{ name = 'WSearch'; startType = 'Automatic'; status = 'Running' })
    $baseline.features = @([pscustomobject]@{ name = 'WindowsMediaPlayer'; state = 'Enabled' })
    $baseline.registry = @([pscustomobject]@{ path = 'HKLM:\Test'; name = 'Value'; exists = $true; value = 1 })
    $baseline.tasks = @([pscustomobject]@{ path = '\Test\'; name = 'Task'; state = 'Ready' })
    $baseline.power = [pscustomobject]@{ activeScheme = 'aaaa' }

    $identical = $baseline.PSObject.Copy()
    $differences = @(Compare-Snapshot -Baseline $baseline -Current $identical)
    Add-Result (Get-Verdict ($differences.Count -eq 0)) 'identical snapshots produce no differences' -Detail (Format-DifferenceList $differences)

    $changed = New-EmptySnapshot
    $changed.services = @([pscustomobject]@{ name = 'WSearch'; startType = 'Disabled'; status = 'Stopped' })
    $changed.features = @([pscustomobject]@{ name = 'WindowsMediaPlayer'; state = 'Disabled' })
    $changed.registry = @([pscustomobject]@{ path = 'HKLM:\Test'; name = 'Value'; exists = $true; value = 0 })
    $changed.tasks = @([pscustomobject]@{ path = '\Test\'; name = 'Task'; state = 'Disabled' })
    $changed.power = [pscustomobject]@{ activeScheme = 'bbbb' }

    $differences = @(Compare-Snapshot -Baseline $baseline -Current $changed)
    $areas = @($differences | ForEach-Object { $_.area } | Sort-Object -Unique)
    $expectedAreas = @('feature', 'power', 'registry', 'service', 'service-status', 'task')
    $missing = @($expectedAreas | Where-Object { $areas -notcontains $_ })
    Add-Result (Get-Verdict ($missing.Count -eq 0)) 'changed snapshots produce differences in every area' -Detail ('missing: ' + ($missing -join ', '))

    $normalised = ConvertTo-StableState 'EnablePending'
    Add-Result (Get-Verdict ($normalised -eq 'Enabled')) 'pending feature states normalise to their settled state' -Detail "EnablePending -> $normalised"

    $errorMatch = Test-LogHasError -Text '[2026-01-01 00:00:00] [ERROR] Disable optional feature: WindowsMediaPlayer -- FAILED: nope' -Identifier 'WindowsMediaPlayer'
    Add-Result (Get-Verdict $errorMatch) 'error matching finds the identifier in an [ERROR] line'

    $errorMatch = Test-LogHasError -Text '[2026-01-01 00:00:00] [OK] Disable optional feature: WindowsMediaPlayer' -Identifier 'WindowsMediaPlayer'
    Add-Result (Get-Verdict (-not $errorMatch)) 'error matching ignores [OK] lines'

    $crashText = 'Exception: At line:1 char:2'
    Add-Result (Get-Verdict (Test-Crashed -Text $crashText)) 'crash detection spots a stack frame'
    Add-Result (Get-Verdict (-not (Test-Crashed -Text '[INFO] all good'))) 'crash detection ignores clean output'

    Write-Section 'Self-test summary'
    $script:results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDir 'selftest-results.json') -Encoding UTF8
    $failures = Get-ResultCount 'FAIL'
    if ($failures -gt 0) {
        Write-Host ("Self-test failed: $failures check(s).") -ForegroundColor Red
        exit 1
    }
    Write-Host 'Self-test passed: catalog extraction, the diff engine, error matching and crash detection all behave.' -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# Pre-flight guards
# ---------------------------------------------------------------------------
Write-Host 'Win11VM Server Optimizer - throwaway-machine round-trip test' -ForegroundColor Cyan

if (-not $IAmInAThrowawayMachine) {
    Write-Host ''
    Write-Host 'Refusing to run.' -ForegroundColor Red
    Write-Host 'This test really does apply the optimizer to this machine: it removes AppX packages,' -ForegroundColor Red
    Write-Host 'disables services and rewrites registry values. Run it only inside a disposable VM or' -ForegroundColor Red
    Write-Host 'Windows Sandbox, then re-run with -IAmInAThrowawayMachine to confirm that.' -ForegroundColor Red
    exit 2
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Refusing to run: the optimizer requires an elevated session, so this harness does too.' -ForegroundColor Red
    exit 2
}

foreach ($required in @($optimizerPath, $restorePath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Write-Host ("Refusing to run: missing '{0}'." -f $required) -ForegroundColor Red
        exit 2
    }
}

if (-not (Test-Path -LiteralPath $scratchDir)) {
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
}

$computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$model = ''
if ($computer) { $model = [string]$computer.Model }
$osCaption = ''
if ($os) { $osCaption = ([string]$os.Caption).Trim() }
$osBuild = ''
if ($os) { $osBuild = [string]$os.BuildNumber }
$looksVirtual = ($model -match '(?i)virtual|vmware|virtualbox|hyper-v|kvm|qemu|hvm|parallels|xen|bochs|sandbox')

Write-Section 'Environment'
Write-Host ("machine      : {0}" -f $env:COMPUTERNAME)
Write-Host ("os           : {0} build {1}" -f $osCaption, $osBuild)
Write-Host ("model        : {0}" -f $model)
Write-Host ("powershell   : {0}" -f $PSVersionTable.PSVersion)
Write-Host ("repo         : {0}" -f $RepoRoot)
Write-Host ("output       : {0}" -f $OutputDir)
Write-Host ("profile      : {0}" -f $Profile)
Add-Result INFO 'Environment recorded' -Detail ("{0} / {1} build {2} / model {3} / profile {4}" -f $env:COMPUTERNAME, $osCaption, $osBuild, $model, $Profile)
if (-not $looksVirtual) {
    Add-Result WARN 'This machine does not look like a VM' -Detail 'model does not match any known hypervisor - make sure this really is a throwaway box'
    $null = $script:limitations.Add('Machine model does not look virtual; confirm it is disposable.')
}

# ---------------------------------------------------------------------------
# Step 1: baseline
# ---------------------------------------------------------------------------
Write-Section 'Step 1 - baseline snapshot'
$catalog = Get-OptimizerCatalog -Path $optimizerPath
Test-Catalog -Catalog $catalog
$baseline = Get-Snapshot -Catalog $catalog -SkipAppXCapture:$SkipAppX
Add-Result INFO 'Baseline captured' -Detail ("{0} services, {1} features, {2} tasks, {3} registry values, {4} apps" -f $baseline.services.Count, $baseline.features.Count, $baseline.tasks.Count, $baseline.registry.Count, $baseline.appx.Count)
$baseline | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir 'snapshot-baseline.json') -Encoding UTF8

if (Test-Path -LiteralPath $statePath) {
    Add-Result FAIL 'No pre-existing change record' -Detail "found stale $statePath - start from a fresh machine"
} else {
    Add-Result PASS 'No pre-existing change record'
}

# ---------------------------------------------------------------------------
# Step 2: dry run
# ---------------------------------------------------------------------------
Write-Section 'Step 2 - optimizer dry run'
$dryRunLog = Join-Path $OutputDir 'optimizer-dryrun.log'
$dryRun = Invoke-TestScript -Path $optimizerPath -Label 'optimizer-dryrun' -Arguments (@(
        '-Profile', $Profile,
        '-DryRun', '-Force',
        '-ExclusionPaths', $scratchDir,
        '-LogPath', $dryRunLog,
        '-StatePath', $statePath
    ))
Test-CleanRun -Run $dryRun -Label 'optimizer -DryRun'
$dryRunLogText = Read-LogText -Path $dryRunLog

$okCount = Get-LogCount -Text $dryRunLogText -Level 'OK'
Add-Result (Get-Verdict ($okCount -eq 0)) 'dry run logs no [OK] lines' -Detail "$okCount found - a dry run must never claim to have changed anything"
Add-Result (Get-Verdict (-not (Test-Path -LiteralPath $statePath))) 'dry run writes no change record' -Detail $statePath

$afterDryRun = Get-Snapshot -Catalog $catalog -SkipAppXCapture:$SkipAppX
$dryRunDifferences = @(Compare-Snapshot -Baseline $baseline -Current $afterDryRun)
$material = @($dryRunDifferences | Where-Object { $_.area -ne 'service-status' })
Add-Result (Get-Verdict ($material.Count -eq 0)) 'dry run changes nothing' -Detail (Format-DifferenceList $material)
if (@($dryRunDifferences | Where-Object { $_.area -eq 'service-status' }).Count -gt 0) {
    Add-Result INFO 'Service status moved during the dry run' -Detail 'transient service state, not a configuration change'
}
$afterDryRun | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir 'snapshot-after-dryrun.json') -Encoding UTF8

# ---------------------------------------------------------------------------
# Step 3: apply
# ---------------------------------------------------------------------------
Write-Section 'Step 3 - optimizer (real run)'
$runLog = Join-Path $OutputDir 'optimizer-run1.log'
$runArguments = @(
    '-Profile', $Profile,
    '-Force',
    '-ExclusionPaths', $scratchDir,
    '-LogPath', $runLog,
    '-StatePath', $statePath
)
if ($IncludeRestorePoint) { $runArguments += '-CreateRestorePoint' }

$run = Invoke-TestScript -Path $optimizerPath -Label 'optimizer-run1' -Arguments $runArguments
Test-CleanRun -Run $run -Label 'optimizer (apply)'
$runLogText = Read-LogText -Path $runLog
$runOk = Get-LogCount -Text $runLogText -Level 'OK'
$runSkip = Get-LogCount -Text $runLogText -Level 'SKIP'
$runError = Get-LogCount -Text $runLogText -Level 'ERROR'
Add-Result INFO 'Apply run log summary' -Detail "$runOk OK, $runSkip SKIP, $runError ERROR"

$record = $null
if (Test-Path -LiteralPath $statePath) {
    try {
        $record = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        Add-Result PASS 'change record written'
    } catch {
        Add-Result FAIL 'change record parses' -Detail $_.Exception.Message
    }
} else {
    Add-Result FAIL 'change record written' -Detail "no file at $statePath"
}
if ($record) {
    $recordCount = @($record.services).Count + @($record.registry).Count + @($record.features).Count +
                   @($record.capabilities).Count + @($record.tasks).Count + @($record.powerManagedAdapters).Count
    Add-Result (Get-Verdict ($recordCount -gt 0)) 'change record is not empty' -Detail "$recordCount reversible item(s)"
    Add-Result (Get-Verdict ($record.schemaVersion -eq 1)) 'change record schema version' -Detail "schemaVersion $($record.schemaVersion)"
}

$afterApply = Get-Snapshot -Catalog $catalog -SkipAppXCapture:$SkipAppX
$applyDifferences = @(Compare-Snapshot -Baseline $baseline -Current $afterApply | Where-Object { $_.area -ne 'service-status' })
$afterApply | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir 'snapshot-after-apply.json') -Encoding UTF8

if ($record) {
    Write-Section 'Step 3b - every recorded change really happened'

    $verified = 0
    $blocked = 0
    $mismatched = @()

    foreach ($entry in @($record.services)) {
        $current = $afterApply.services | Where-Object { $_.name -eq $entry.name } | Select-Object -First 1
        if (-not $current) {
            $mismatched += "service $($entry.name) disappeared"
        } elseif ($current.startType -eq 'Disabled') {
            $verified++
        } elseif (Test-LogHasError -Text $runLogText -Identifier $entry.name) {
            $blocked++
        } else {
            $mismatched += "service $($entry.name) is $($current.startType), not Disabled"
        }
    }

    foreach ($entry in @($record.features)) {
        $current = $afterApply.features | Where-Object { $_.name -eq $entry.name } | Select-Object -First 1
        if (-not $current -or $current.state -eq 'Disabled') {
            $verified++
        } elseif (Test-LogHasError -Text $runLogText -Identifier $entry.name) {
            $blocked++
        } else {
            $mismatched += "feature $($entry.name) is $($current.state), not Disabled"
        }
    }

    foreach ($entry in @($record.capabilities)) {
        $current = $afterApply.capabilities | Where-Object { $_.name -eq $entry.name } | Select-Object -First 1
        if (-not $current -or $current.state -ne 'Installed') {
            $verified++
        } elseif (Test-LogHasError -Text $runLogText -Identifier $entry.name) {
            $blocked++
        } else {
            $mismatched += "capability $($entry.name) is still installed"
        }
    }

    foreach ($entry in @($record.tasks)) {
        $current = $afterApply.tasks | Where-Object { $_.path -eq $entry.taskPath -and $_.name -eq $entry.taskName } | Select-Object -First 1
        if (-not $current -or $current.state -eq 'Disabled') {
            $verified++
        } elseif (Test-LogHasError -Text $runLogText -Identifier $entry.taskName) {
            $blocked++
        } else {
            $mismatched += "task $($entry.taskName) is $($current.state), not Disabled"
        }
    }

    foreach ($entry in @($record.registry)) {
        $target = $catalog.registry | Where-Object { $_.path -eq $entry.path -and $_.name -eq $entry.name } | Select-Object -First 1
        $current = $afterApply.registry | Where-Object { $_.path -eq $entry.path -and $_.name -eq $entry.name } | Select-Object -First 1
        if (-not $target) {
            $null = $script:limitations.Add("Registry value $($entry.name) is in the record but not in the optimizer catalog - harness needs updating.")
            continue
        }
        $currentValue = '<absent>'
        if ($current -and $current.exists) { $currentValue = $current.value }
        if ($current -and $current.exists -and (Test-ValueEqual $current.value $target.target)) {
            $verified++
        } elseif (Test-LogHasError -Text $runLogText -Identifier $entry.name) {
            $blocked++
        } else {
            $mismatched += "registry $($entry.name) is $currentValue, expected $($target.target)"
        }
    }

    foreach ($entry in @($record.powerManagedAdapters)) {
        $current = $afterApply.nic | Where-Object { $_.instanceName -eq $entry.instanceName } | Select-Object -First 1
        if ($current -and -not $current.enable) {
            $verified++
        } elseif (Test-LogHasError -Text $runLogText -Identifier $entry.instanceName) {
            $blocked++
        } else {
            $mismatched += "NIC $($entry.instanceName) can still be powered down"
        }
    }

    if ($record.hibernation -and $record.hibernation.wasEnabled) {
        if ($afterApply.hibernation -eq 0) { $verified++ } else { $mismatched += 'hibernation is still enabled' }
    }
    if ($record.power -and $record.power.activeScheme -and $record.power.activeScheme -notmatch '^8c5e7fda') {
        if ($afterApply.power.activeScheme -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') {
            $verified++
        } else {
            $mismatched += "power scheme is $($afterApply.power.activeScheme), not High Performance"
        }
    }
    if ($record.reservedStorage -and $record.reservedStorage.wasEnabled) {
        if ($afterApply.reservedStorage -eq 'Disabled') { $verified++ } elseif ($afterApply.reservedStorage) { $mismatched += "reserved storage is $($afterApply.reservedStorage)" }
    }

    Add-Result (Get-Verdict ($mismatched.Count -eq 0)) 'recorded changes match the live machine' -Detail ("$verified verified, $blocked blocked by a logged error, $($mismatched.Count) mismatched")
    foreach ($problem in $mismatched) {
        Add-Result FAIL 'record/reality mismatch' -Detail $problem
    }
    if ($blocked -gt 0) {
        $null = $script:limitations.Add("$blocked recorded change(s) could not be applied and are named in an [ERROR] line (Windows build or policy limitation).")
    }

    # A record is only worth having if its "before" values are the machine's actual before values. One
    # recorded backwards is worse than not recorded at all - the restore then confidently restores the
    # wrong state. Hibernation was exactly this: absent HibernateEnabled read as "was off" on a machine
    # where it was on, so the restore could never turn it back on.
    $originErrors = @()
    if ($record.power -and $record.power.activeScheme -and $baseline.power.activeScheme -and
        $record.power.activeScheme -ne $baseline.power.activeScheme) {
        $originErrors += "power scheme recorded as $($record.power.activeScheme), baseline showed $($baseline.power.activeScheme)"
    }
    if ($record.hibernation -and ([bool]$record.hibernation.wasEnabled) -ne ([int]$baseline.hibernation -eq 1)) {
        $originErrors += "hibernation recorded as wasEnabled=$($record.hibernation.wasEnabled), baseline showed $($baseline.hibernation)"
    }
    if ($record.reservedStorage -and ([bool]$record.reservedStorage.wasEnabled) -ne ($baseline.reservedStorage -eq 'Enabled')) {
        $originErrors += "reserved storage recorded as wasEnabled=$($record.reservedStorage.wasEnabled), baseline showed $($baseline.reservedStorage)"
    }
    Add-Result (Get-Verdict ($originErrors.Count -eq 0)) 'recorded original values match the baseline' -Detail ($originErrors -join '; ')
    foreach ($problem in $originErrors) {
        Add-Result FAIL 'record/baseline mismatch' -Detail $problem
    }
}

# ---------------------------------------------------------------------------
# Step 4: re-run (originals must survive)
# ---------------------------------------------------------------------------
Write-Section 'Step 4 - optimizer re-run preserves the originals'
$rerunLog = Join-Path $OutputDir 'optimizer-run2.log'
$recordBefore = ''
$recordBeforeRegistry = ''
if ($record) {
    $recordBefore = @($record.services) | ConvertTo-Json -Depth 5
    $recordBeforeRegistry = @($record.registry) | ConvertTo-Json -Depth 5
}

$rerun = Invoke-TestScript -Path $optimizerPath -Label 'optimizer-run2' -Arguments $runArguments
Test-CleanRun -Run $rerun -Label 'optimizer (re-run)'
$rerunLogText = Read-LogText -Path $rerunLog
$rerunOk = Get-LogCount -Text $rerunLogText -Level 'OK'

if (Test-Path -LiteralPath $statePath) {
    try {
        $recordAfter = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $servicesAfter = @($recordAfter.services) | ConvertTo-Json -Depth 5
        $registryAfter = @($recordAfter.registry) | ConvertTo-Json -Depth 5
        Add-Result (Get-Verdict ($servicesAfter -eq $recordBefore)) 'second run keeps the original service values'
        Add-Result (Get-Verdict ($registryAfter -eq $recordBeforeRegistry)) 'second run keeps the original registry values'
    } catch {
        Add-Result FAIL 'second run record parses' -Detail $_.Exception.Message
    }
} else {
    Add-Result FAIL 'second run kept a change record' -Detail 'the file is gone'
}

$firstRunComparable = [Math]::Max($runOk, 1)
Add-Result (Get-Verdict ($rerunOk -lt $firstRunComparable) 'PASS' 'WARN') 'second run does less work than the first' -Detail "first $runOk OK, second $rerunOk OK"

# ---------------------------------------------------------------------------
# Step 5: restore dry run
# ---------------------------------------------------------------------------
Write-Section 'Step 5 - restore dry run'
$restoreDryLog = Join-Path $OutputDir 'restore-dryrun.log'
$restoreDry = Invoke-TestScript -Path $restorePath -Label 'restore-dryrun' -Arguments @(
    '-DryRun', '-Force',
    '-StatePath', $statePath,
    '-LogPath', $restoreDryLog
)
Test-CleanRun -Run $restoreDry -Label 'restore -DryRun'
$restoreDryText = Read-LogText -Path $restoreDryLog
$restoreDryOk = Get-LogCount -Text $restoreDryText -Level 'OK'
Add-Result (Get-Verdict ($restoreDryOk -eq 0)) 'restore dry run logs no [OK] lines' -Detail "$restoreDryOk found"

$afterRestoreDry = Get-Snapshot -Catalog $catalog -SkipAppXCapture:$SkipAppX
$restoreDryDifferences = @(Compare-Snapshot -Baseline $afterApply -Current $afterRestoreDry | Where-Object { $_.area -ne 'service-status' })
Add-Result (Get-Verdict ($restoreDryDifferences.Count -eq 0)) 'restore dry run changes nothing' -Detail (Format-DifferenceList $restoreDryDifferences)

# ---------------------------------------------------------------------------
# Step 6: restore
# ---------------------------------------------------------------------------
Write-Section 'Step 6 - restore (real run)'
$restoreLog = Join-Path $OutputDir 'restore-run1.log'
$restore = Invoke-TestScript -Path $restorePath -Label 'restore-run1' -Arguments @(
    '-Force',
    '-StatePath', $statePath,
    '-LogPath', $restoreLog
)
Test-CleanRun -Run $restore -Label 'restore (apply)'
$restoreText = Read-LogText -Path $restoreLog
Add-Result INFO 'Restore log summary' -Detail ("{0} OK, {1} SKIP, {2} ERROR" -f (Get-LogCount -Text $restoreText -Level 'OK'), (Get-LogCount -Text $restoreText -Level 'SKIP'), (Get-LogCount -Text $restoreText -Level 'ERROR'))

$afterRestore = Get-Snapshot -Catalog $catalog -SkipAppXCapture:$SkipAppX
$afterRestore | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir 'snapshot-after-restore.json') -Encoding UTF8

$restoreDifferences = @(Compare-Snapshot -Baseline $baseline -Current $afterRestore)
$appxDifferences = @($restoreDifferences | Where-Object { $_.area -eq 'appx' })
$statusDifferences = @($restoreDifferences | Where-Object { $_.area -eq 'service-status' })
$restoreFailures = @($restoreDifferences | Where-Object { $_.area -ne 'appx' -and $_.area -ne 'service-status' })

Add-Result (Get-Verdict ($restoreFailures.Count -eq 0)) 'machine matches the baseline again' -Detail (Format-DifferenceList $restoreFailures)
foreach ($failure in $restoreFailures) {
    Add-Result FAIL 'restore left a difference' -Detail (Format-Difference $failure)
}

if ($statusDifferences.Count -gt 0) {
    Add-Result WARN 'Some services are not in their original running state' -Detail (Format-DifferenceList $statusDifferences)
    $null = $script:limitations.Add('Service running state differs from baseline; start types were restored correctly. Common in a VM where some services cannot start.')
}

if ($appxDifferences.Count -gt 0) {
    Add-Result INFO 'AppX packages were not restored (expected)' -Detail "$($appxDifferences.Count) package(s) - Windows has no supported re-add operation; see the restore log"
    Add-Result (Get-Verdict ($restoreText -match 'cannot be re-added')) 'restore log explains the AppX limitation'
    $null = $script:limitations.Add("$($appxDifferences.Count) AppX package(s) removed and not restored by design.")
}

# Defender exclusions are intentionally left in place; assert that, then tidy up for the report.
try {
    $exclusions = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
    if ($exclusions -contains $scratchDir) {
        Add-Result PASS 'test exclusion still present after restore (documented behaviour)'
        Remove-MpPreference -ExclusionPath $scratchDir -ErrorAction SilentlyContinue
    } else {
        Add-Result WARN 'test exclusion is not in the Defender exclusion list' -Detail 'Phase 0 may have been blocked by policy or Tamper Protection'
    }
} catch {
    Add-Result WARN 'could not read Defender exclusions' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Step 7: report
# ---------------------------------------------------------------------------
Write-Section 'Summary'

$reportPath = Join-Path $OutputDir 'report.md'
$passCount = Get-ResultCount 'PASS'
$failCount = Get-ResultCount 'FAIL'
$warnCount = Get-ResultCount 'WARN'
$overall = 'PASS'
if ($failCount -gt 0) { $overall = 'FAIL' }

$lines = New-Object System.Collections.ArrayList
$null = $lines.Add('# Round-trip test report')
$null = $lines.Add('')
$null = $lines.Add(('- Generated: {0}' -f (Get-Date).ToString('u')))
$null = $lines.Add(('- Machine: {0}' -f $env:COMPUTERNAME))
$null = $lines.Add(('- OS: {0} build {1}' -f $osCaption, $osBuild))
$null = $lines.Add(('- Model: {0}' -f $model))
$null = $lines.Add(('- PowerShell: {0}' -f $PSVersionTable.PSVersion))
$null = $lines.Add(('- Repo: {0}' -f $RepoRoot))
$null = $lines.Add(('- Result: **{0}** ({1} passed, {2} failed, {3} warnings)' -f $overall, $passCount, $failCount, $warnCount))
$null = $lines.Add('')
$null = $lines.Add('## Checks')
$null = $lines.Add('')
$null = $lines.Add('| Result | Check | Detail |')
$null = $lines.Add('|---|---|---|')
foreach ($result in $script:results) {
    $detail = ([string]$result.detail) -replace '\|', '\|'
    $name = ([string]$result.name) -replace '\|', '\|'
    $null = $lines.Add(('| {0} | {1} | {2} |' -f $result.result, $name, $detail))
}

$null = $lines.Add('')
$null = $lines.Add('## Snapshot differences')
$null = $lines.Add('')
$null = $lines.Add(('- Dry run vs baseline: {0}' -f (Format-DifferenceList $material)))
$null = $lines.Add(('- Apply vs baseline (informational): {0}' -f (Format-DifferenceList $applyDifferences)))
$null = $lines.Add(('- After restore vs baseline (excluding AppX): {0}' -f (Format-DifferenceList $restoreFailures)))

if ($script:limitations.Count -gt 0) {
    $null = $lines.Add('')
    $null = $lines.Add('## Limitations observed')
    $null = $lines.Add('')
    foreach ($limitation in $script:limitations) { $null = $lines.Add("- $limitation") }
}

$null = $lines.Add('')
$null = $lines.Add('## Logs')
$null = $lines.Add('')
$null = $lines.Add('- Dry run: `optimizer-dryrun.log`')
$null = $lines.Add('- Apply: `optimizer-run1.log`')
$null = $lines.Add('- Re-run: `optimizer-run2.log`')
$null = $lines.Add('- Restore dry run: `restore-dryrun.log`')
$null = $lines.Add('- Restore: `restore-run1.log`')
$lines | Set-Content -LiteralPath $reportPath -Encoding UTF8

$script:results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDir 'results.json') -Encoding UTF8

Write-Host ''
Write-Host ("{0} passed, {1} failed, {2} warnings" -f $passCount, $failCount, $warnCount) -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })
Write-Host ("Report: {0}" -f $reportPath)
Write-Host ("Evidence: {0}" -f $OutputDir)

if ($failCount -gt 0) {
    exit 1
}
exit 0
