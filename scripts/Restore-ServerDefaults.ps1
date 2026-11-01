#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Restore-ServerDefaults - Reverses the changes Win11VM-ServerOptimizer.ps1 recorded.

.DESCRIPTION
    The optimizer writes a JSON change record as it runs, capturing the original state of everything
    it can put back: service start types and running state, enabled optional features and
    capabilities, scheduled task state, and the previous value (or absence) of every registry value
    it touched, plus the active power scheme, hibernation, and reserved storage state.

    This script reads that record and reverts exactly what was recorded - it does not apply a
    generic "Windows defaults" table. That matters because the correct value to restore is whatever
    THIS machine had before the optimizer first ran, not whatever a stock install ships with.

    What can be restored:
      - Services: original start type, and started again if they were running
      - Optional features and capabilities: re-enabled (a restart is usually required)
      - Scheduled tasks: re-enabled
      - Registry values: previous value, or removed if they did not exist before
      - Power: previous active power scheme, hibernation, reserved storage

    What cannot be restored:
      - AppX packages (Xbox, Cortana, Solitaire, etc.). Windows has no supported "re-add consumer app"
        operation, so the record lists them for reporting and you reinstall anything you actually
        want from the Store.
      - Defender exclusions. These are treated as your deliberate intent rather than an unwanted
        tweak, so they are left in place; remove them in Windows Security if you want them gone.

.PARAMETER StatePath
    Path to the change record written by Win11VM-ServerOptimizer.ps1. Defaults to the optimizer's
    default location under ProgramData. Must point at the record for the machine you are restoring.

.PARAMETER DryRun
    Shows what would be restored without changing anything.

.PARAMETER Force
    Skips the "are you sure?" confirmation prompt. Use for unattended/scripted runs.

.PARAMETER LogPath
    Where to write the log file. Defaults alongside the optimizer's log under ProgramData. Rotated to
    <LogPath>.1 once it passes 5 MB.

.EXAMPLE
    .\Restore-ServerDefaults.ps1 -DryRun
    .\Restore-ServerDefaults.ps1
#>

[CmdletBinding()]
param(
    [string]$StatePath = "$env:ProgramData\Win11VM-ServerOptimizer\state.json",
    [switch]$DryRun,
    [switch]$Force,
    [string]$LogPath = "$env:ProgramData\Win11VM-ServerOptimizer\Restore-ServerDefaults.log"
)

$script:ScriptVersion = '1.0.1'
$script:StateSchemaVersion = 1

function New-LogDirectory {
    param([string]$Path, [string]$FallbackName)
    $dir = Split-Path -Path $Path -Parent
    if (-not $dir) { return $Path }
    if (-not (Test-Path -LiteralPath $dir)) {
        try {
            New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            $fallback = Join-Path $env:TEMP $FallbackName
            Write-Host "WARNING: Could not create log directory '$dir' ($($_.Exception.Message)). Falling back to '$fallback'." -ForegroundColor Yellow
            return $fallback
        }
    }
    return $Path
}

$LogPath = New-LogDirectory -Path $LogPath -FallbackName 'Restore-ServerDefaults.log'

if (Test-Path -LiteralPath $LogPath) {
    try {
        $logItem = Get-Item -LiteralPath $LogPath -ErrorAction Stop
        if ($logItem.Length -gt 5MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force -ErrorAction Stop
        }
    } catch {
        Write-Host "WARNING: Could not rotate the log file at '$LogPath' ($($_.Exception.Message)). Continuing to append to it." -ForegroundColor Yellow
    }
}

$ErrorActionPreference = 'Continue'
$script:changes = 0
$script:errors = 0
$script:skipped = 0

function Write-Banner {
    $lines = @(
        "Restore Server Defaults  v$script:ScriptVersion"
        "Undo Win11VM-ServerOptimizer using its change record"
        ""
        "Author : Matt Hurley"
        "Web    : https://matthurley.dev"
        "Repo   : https://github.com/theantipopau/Win11VM-ServerOptimizer"
    )
    $width = (($lines | Measure-Object -Property Length -Maximum).Maximum) + 4
    $border = '+' + ('-' * $width) + '+'

    Write-Host ""
    Write-Host $border -ForegroundColor Cyan
    foreach ($line in $lines) {
        Write-Host ('| ' + $line.PadRight($width - 2) + ' |') -ForegroundColor Cyan
    }
    Write-Host $border -ForegroundColor Cyan
    Write-Host ""
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Invoke-Action {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) {
        Write-Log "DRY RUN - would: $Description" 'DRYRUN'
        return
    }
    $global:LASTEXITCODE = 0
    try {
        & $Action
        if ($LASTEXITCODE) {
            throw "native command exited with code $LASTEXITCODE"
        }
        Write-Log $Description 'OK'
        $script:changes++
    } catch {
        Write-Log "$Description -- FAILED: $($_.Exception.Message)" 'ERROR'
        $script:errors++
    }
}

function Get-RegistryCurrentValue {
    param([string]$Path, [string]$Name)
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($key.GetValueNames() -contains $Name) {
            return [pscustomobject]@{
                present = $true
                value   = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
    } catch {
        # Key missing or unreadable - treated as "value not present".
        Write-Verbose "Could not read '$Name' under '$Path' ($($_.Exception.Message))."
    }
    return [pscustomobject]@{ present = $false; value = $null }
}

Write-Banner
Write-Log "=== Restore-ServerDefaults v$script:ScriptVersion starting (DryRun=$DryRun) ==="

if (-not (Test-Path -LiteralPath $StatePath)) {
    Write-Log "No change record found at '$StatePath'. Nothing to restore from - the optimizer writes one every run it applies changes; pass -StatePath if the record lives somewhere else." 'ERROR'
    exit 1
}

try {
    $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Log "Could not read the change record at '$StatePath' ($($_.Exception.Message))." 'ERROR'
    exit 1
}

if ($null -eq $state -or $state.schemaVersion -ne $script:StateSchemaVersion) {
    Write-Log "The change record at '$StatePath' is not a format this script understands (schemaVersion '$($state.schemaVersion)', expected '$($script:StateSchemaVersion)'). Use the Restore-ServerDefaults.ps1 release that matches the optimizer version that wrote it." 'ERROR'
    exit 1
}

Write-Log "Change record written by optimizer v$($state.scriptVersion) on $($state.createdOn), last updated $($state.lastRun)." 'INFO'

$totalRecords = @($state.registry).Count + @($state.services).Count + @($state.features).Count +
                @($state.capabilities).Count + @($state.tasks).Count
if ($totalRecords -eq 0) {
    Write-Log "The change record is empty - no reversible changes were recorded, so there is nothing to restore." 'WARN'
    exit 0
}

Write-Log "Record contains: $(@($state.registry).Count) registry value(s), $(@($state.services).Count) service(s), $(@($state.features).Count) optional feature(s), $(@($state.capabilities).Count) capability(ies), $(@($state.tasks).Count) scheduled task(s), $(@($state.appxRemoved).Count) removed app(s) that cannot be restored automatically." 'INFO'

if (-not $DryRun -and -not $Force) {
    $confirm = Read-Host "This will re-enable services, features and scheduled tasks that the optimizer disabled, and restore recorded registry values. Continue? [y/N]"
    if ($confirm -notmatch '^(y|yes)$') {
        Write-Log "User declined confirmation - exiting without making changes." 'WARN'
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Registry values
# ---------------------------------------------------------------------------
Write-Log "--- Restoring registry values ---"

foreach ($entry in @($state.registry)) {
    $target = "$($entry.path)\$($entry.name)"

    if ($entry.existed) {
        $want = $entry.originalValue
        $current = Get-RegistryCurrentValue -Path $entry.path -Name $entry.name
        if ($current.present -and $current.value -eq $want) {
            Write-Log "Registry value already at its original value: $target = $want" 'SKIP'
            $script:skipped++
            continue
        }
        Invoke-Action "Restore $target = $want" {
            if (-not (Test-Path -LiteralPath $entry.path)) { New-Item -Path $entry.path -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -Path $entry.path -Name $entry.name -Value $want -PropertyType $entry.type -Force -ErrorAction Stop | Out-Null
        }
    } else {
        $current = Get-RegistryCurrentValue -Path $entry.path -Name $entry.name
        if (-not $current.present) {
            Write-Log "Registry value already absent: $target" 'SKIP'
            $script:skipped++
            continue
        }
        Invoke-Action "Remove $target (did not exist before the optimizer ran)" {
            Remove-ItemProperty -Path $entry.path -Name $entry.name -ErrorAction Stop
        }
    }
}

# ---------------------------------------------------------------------------
# Optional features and capabilities
# Features first: re-enabling one can recreate services that the service pass
# below then restores the start type for.
# ---------------------------------------------------------------------------
Write-Log "--- Re-enabling optional features ---"

foreach ($entry in @($state.features)) {
    $featureState = Get-WindowsOptionalFeature -Online -FeatureName $entry.name -ErrorAction SilentlyContinue
    if (-not $featureState) {
        Write-Log "Optional feature no longer present on this build: $($entry.name)" 'SKIP'
        $script:skipped++
        continue
    }
    if ($featureState.State -eq 'Enabled') {
        Write-Log "Optional feature already enabled: $($entry.name)" 'SKIP'
        $script:skipped++
        continue
    }
    Invoke-Action "Enable optional feature: $($entry.name)" {
        Enable-WindowsOptionalFeature -Online -FeatureName $entry.name -NoRestart -ErrorAction Stop | Out-Null
    }
}

Write-Log "--- Re-adding capabilities ---"

foreach ($entry in @($state.capabilities)) {
    $capabilityState = Get-WindowsCapability -Online -Name $entry.name -ErrorAction SilentlyContinue
    if (-not $capabilityState) {
        Write-Log "Capability no longer present on this build: $($entry.name)" 'SKIP'
        $script:skipped++
        continue
    }
    if ($capabilityState.State -eq 'Installed') {
        Write-Log "Capability already installed: $($entry.name)" 'SKIP'
        $script:skipped++
        continue
    }
    Invoke-Action "Re-add capability: $($entry.name)" {
        Add-WindowsCapability -Online -Name $entry.name -ErrorAction Stop | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Scheduled tasks
# ---------------------------------------------------------------------------
Write-Log "--- Re-enabling scheduled tasks ---"

foreach ($entry in @($state.tasks)) {
    $taskObj = Get-ScheduledTask -TaskName $entry.taskName -TaskPath $entry.taskPath -ErrorAction SilentlyContinue
    if (-not $taskObj) {
        Write-Log "Scheduled task no longer present: $($entry.taskPath)$($entry.taskName)" 'SKIP'
        $script:skipped++
        continue
    }
    if ($taskObj.State -ne 'Disabled') {
        Write-Log "Scheduled task already enabled: $($entry.taskPath)$($entry.taskName)" 'SKIP'
        $script:skipped++
        continue
    }
    Invoke-Action "Enable scheduled task: $($entry.taskPath)$($entry.taskName)" {
        Enable-ScheduledTask -TaskPath $entry.taskPath -TaskName $entry.taskName -ErrorAction Stop | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------
Write-Log "--- Restoring services ---"

foreach ($entry in @($state.services)) {
    $service = Get-Service -Name $entry.name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log "Service no longer present: $($entry.name)" 'SKIP'
        $script:skipped++
        continue
    }

    if ($service.StartType.ToString() -ne $entry.originalStartType) {
        Invoke-Action "Set service '$($entry.name)' startup type back to $($entry.originalStartType)" {
            Set-Service -Name $entry.name -StartupType $entry.originalStartType -ErrorAction Stop
        }
    } else {
        Write-Log "Service '$($entry.name)' startup type already $($entry.originalStartType)" 'SKIP'
        $script:skipped++
    }

    if ($entry.originalStatus -eq 'Running') {
        $service = Get-Service -Name $entry.name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running') {
            Invoke-Action "Start service '$($entry.name)' (it was running before)" {
                Start-Service -Name $entry.name -ErrorAction Stop
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Power and storage
# ---------------------------------------------------------------------------
if ($state.power -and $state.power.activeScheme) {
    Write-Log "--- Restoring power scheme ---"
    $currentScheme = $null
    try {
        $schemeOutput = (& powercfg /getactivescheme) -join ' '
        if ($schemeOutput -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $currentScheme = $Matches[1]
        }
    } catch {
        Write-Log "Could not read the active power scheme ($($_.Exception.Message))." 'WARN'
    }

    if ($currentScheme -eq $state.power.activeScheme) {
        Write-Log "Power scheme already back to $($state.power.activeScheme)" 'SKIP'
        $script:skipped++
    } else {
        Invoke-Action "Restore previously active power scheme ($($state.power.activeScheme))" {
            powercfg /setactive $state.power.activeScheme | Out-Null
        }
    }
}

if ($state.hibernation -and $state.hibernation.wasEnabled) {
    Write-Log "--- Restoring hibernation ---"
    # Same absent-value trap as the optimizer: HibernateEnabled only exists once hibernation has been
    # toggled, so a machine that still has it on reports nothing here.
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    $hibernateEnabled = (Get-ItemProperty -LiteralPath $powerKey -Name 'HibernateEnabled' -ErrorAction SilentlyContinue).HibernateEnabled
    if ($null -eq $hibernateEnabled) {
        $hibernateEnabled = (Get-ItemProperty -LiteralPath $powerKey -Name 'HibernateEnabledDefault' -ErrorAction SilentlyContinue).HibernateEnabledDefault
    }
    if ($null -eq $hibernateEnabled) { $hibernateEnabled = 1 }
    if ($hibernateEnabled -eq 1) {
        Write-Log "Hibernation already enabled" 'SKIP'
        $script:skipped++
    } else {
        Invoke-Action "Re-enable hibernation (it was enabled before)" {
            powercfg /hibernate on
        }
    }
}

if ($state.reservedStorage -and $state.reservedStorage.wasEnabled) {
    Write-Log "--- Restoring reserved storage ---"
    $reservedState = $null
    try {
        $dismText = ((& dism.exe /Online /Get-ReservedStorageState) -join ' ') -replace "`0", ' '
        if ($dismText -match 'Enabled') { $reservedState = 'Enabled' }
        elseif ($dismText -match 'Disabled') { $reservedState = 'Disabled' }
    } catch {
        Write-Log "Could not read the reserved storage state ($($_.Exception.Message))." 'WARN'
    }

    if ($reservedState -eq 'Enabled') {
        Write-Log "Reserved storage already enabled" 'SKIP'
        $script:skipped++
    } elseif ($reservedState -eq 'Disabled') {
        Invoke-Action "Re-enable reserved storage (it was enabled before)" {
            dism.exe /Online /Set-ReservedStorageState /State:Enabled | Out-Null
        }
    } else {
        Write-Log "Reserved storage state could not be determined - skipping" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Network adapter power management
# ---------------------------------------------------------------------------
if (@($state.powerManagedAdapters).Count -gt 0) {
    Write-Log "--- Restoring network adapter power management ---"
    $powerDevices = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue)

    foreach ($entry in @($state.powerManagedAdapters)) {
        $device = $powerDevices | Where-Object { $_.InstanceName -eq $entry.instanceName } | Select-Object -First 1
        if (-not $device) {
            Write-Log "Network device no longer present: $($entry.instanceName)" 'SKIP'
            $script:skipped++
            continue
        }
        if ($device.Enable) {
            Write-Log "Windows can already power this device down again: $($entry.instanceName)" 'SKIP'
            $script:skipped++
            continue
        }
        Invoke-Action "Allow Windows to power down network device '$($entry.instanceName)' again" {
            Set-CimInstance -InputObject $device -Property @{ Enable = $true } -ErrorAction Stop
        }
    }
}

# ---------------------------------------------------------------------------
# Things that cannot be restored automatically
# ---------------------------------------------------------------------------
if (@($state.appxRemoved).Count -gt 0) {
    Write-Log "--- Removed apps (manual step) ---" 'INFO'
    Write-Log "These AppX packages were removed by the optimizer and cannot be re-added by script; reinstall anything you want back from the Microsoft Store: $((@($state.appxRemoved) | ForEach-Object { $_.name }) -join ', ')" 'WARN'
}

$summary = "=== Complete. $script:changes change(s) applied, $script:skipped already in the requested state, $script:errors error(s)."
if (-not $DryRun) {
    $summary += " A restart is recommended if any optional feature or capability was re-enabled."
}
$summary += " ==="
Write-Log $summary

if ($DryRun) {
    Write-Log "This was a DRY RUN - nothing was actually changed. Re-run without -DryRun to apply." 'DRYRUN'
}

if ($script:errors -gt 0) {
    exit 1
}
exit 0
