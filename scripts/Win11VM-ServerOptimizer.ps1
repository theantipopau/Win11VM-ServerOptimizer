#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Win11VM-ServerOptimizer - Strips a Windows 11 Pro VM down for headless/AMP game server hosting.

.DESCRIPTION
    Designed for VMs whose ONLY job is running game servers via CubeCoders AMP.
    No GUI gaming, no word processing, no general desktop use expected on the box itself.

    Deliberately left ALONE (do not touch, AMP / server role depends on these):
      - .NET Framework / .NET Desktop Runtime
      - Networking stack, NIC drivers, Windows Firewall service (rules are only tidied, not disabled)
      - Remote Desktop (RDP) - assumed to be your main access method
      - Windows Time service (w32time) - game servers care about accurate time
      - Windows Update service (set to notify, not disabled outright - security patches still matter)
      - Windows Defender (excluded from removal by default - use -DisableDefender to opt out, not recommended)

    Stripped:
      - Consumer AppX bloat (Xbox, Widgets, Copilot, Solitaire, Maps, People, Clipchamp, etc.)
      - Telemetry / diagnostics / advertising ID / tailored experiences
      - OneDrive, Cortana, Search-Bing integration, Start menu suggestions
      - Optional features not needed headless: Media Player, Fax & Scan, WordPad, XPS, Steps Recorder
      - Visual effects (set to Best Performance)
      - SysMain/Superfetch, Fast Startup, hibernation (VMs don't benefit from these, they just burn disk/RAM)
      - Background app permissions, unneeded scheduled tasks (Customer Experience, Feedback, etc.)

.PARAMETER DryRun
    Shows what would change without making changes.

.PARAMETER DisableDefender
    Also disables Windows Defender real-time protection (NOT recommended unless this VM is fully
    network-isolated - AMP downloads/updates game server files constantly, an AV exclusion on the
    AMP instances folder is usually the better/safer option, see bottom of script).

.PARAMETER AmpInstancesPath
    Path to your AMP instances folder, used to add a Defender exclusion instead of disabling Defender
    entirely. Example: "C:\AMP\Instances"

.PARAMETER LogPath
    Where to write the log file. Defaults to Desktop.

.EXAMPLE
    .\Win11VM-ServerOptimizer.ps1 -DryRun
    .\Win11VM-ServerOptimizer.ps1 -AmpInstancesPath "C:\AMP\Instances"
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$DisableDefender,
    [string]$AmpInstancesPath,
    [string]$LogPath = "$env:USERPROFILE\Desktop\Win11VM-ServerOptimizer.log"
)

$ErrorActionPreference = 'Continue'
$script:changes = 0
$script:ScriptVersion = '1.0.0'

function Write-Banner {
    $lines = @(
        "Win11 AMP Server Optimizer  v$script:ScriptVersion"
        "Windows 11 VM debloat & tuning for CubeCoders AMP hosts"
        ""
        "Author : Matt Hurley"
        "Web    : https://matthurley.dev"
        "Repo   : https://github.com/theantipopau/win11-amp-server-optimizer"
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
        Write-Log "DRY RUN - would do: $Description" 'DRYRUN'
        return
    }
    try {
        & $Action
        Write-Log $Description 'OK'
        $script:changes++
    } catch {
        Write-Log "$Description -- FAILED: $($_.Exception.Message)" 'ERROR'
    }
}

Write-Banner
Write-Log "=== Win11VM-ServerOptimizer v$script:ScriptVersion starting (DryRun=$DryRun) ==="

# ---------------------------------------------------------------------------
# PHASE 1: Remove consumer AppX bloat
# ---------------------------------------------------------------------------
Write-Log "--- Phase 1: Removing consumer AppX packages ---"

$appxToRemove = @(
    "Microsoft.XboxApp"
    "Microsoft.XboxGameOverlay"
    "Microsoft.XboxGamingOverlay"
    "Microsoft.XboxIdentityProvider"
    "Microsoft.XboxSpeechToTextOverlay"
    "Microsoft.Xbox.TCUI"
    "Microsoft.GamingApp"
    "Microsoft.549981C3F5F10"          # Cortana
    "Microsoft.BingWeather"
    "Microsoft.BingNews"
    "Microsoft.BingSearch"
    "Microsoft.MicrosoftSolitaireCollection"
    "Microsoft.MicrosoftOfficeHub"
    "Microsoft.Office.OneNote"
    "Microsoft.OneDriveSync"
    "Microsoft.People"
    "Microsoft.Todos"
    "Microsoft.WindowsMaps"
    "Microsoft.WindowsFeedbackHub"
    "Microsoft.GetHelp"
    "Microsoft.Getstarted"
    "Microsoft.MixedReality.Portal"
    "Microsoft.ScreenSketch"
    "Microsoft.YourPhone"
    "Microsoft.ZuneMusic"
    "Microsoft.ZuneVideo"
    "Microsoft.Clipchamp"
    "MicrosoftTeams"
    "Microsoft.Copilot"
    "Microsoft.MicrosoftStickyNotes"
    "Microsoft.PowerAutomateDesktop"
    "Microsoft.OutlookForWindows"
    "Clipchamp.Clipchamp"
)

foreach ($app in $appxToRemove) {
    Invoke-Action "Remove AppX package: $app" {
        Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -like "*$app*" |
            Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---------------------------------------------------------------------------
# PHASE 2: Optional Windows features not needed on a headless game server
# ---------------------------------------------------------------------------
Write-Log "--- Phase 2: Disabling unneeded optional features ---"

$featuresToDisable = @(
    "WindowsMediaPlayer"
    "Printing-XPSServices-Features"
    "WorkFolders-Client"
    "FaxServicesClientPackage"
)

foreach ($feature in $featuresToDisable) {
    Invoke-Action "Disable optional feature: $feature" {
        Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart -ErrorAction SilentlyContinue | Out-Null
    }
}

Invoke-Action "Remove WordPad capability" {
    Get-WindowsCapability -Online | Where-Object Name -like "Microsoft.Windows.WordPad*" |
        Remove-WindowsCapability -Online -ErrorAction SilentlyContinue | Out-Null
}
Invoke-Action "Remove Steps Recorder capability" {
    Get-WindowsCapability -Online | Where-Object Name -like "App.StepsRecorder*" |
        Remove-WindowsCapability -Online -ErrorAction SilentlyContinue | Out-Null
}

# ---------------------------------------------------------------------------
# PHASE 3: Services - disable what a headless game server box will never use
# ---------------------------------------------------------------------------
Write-Log "--- Phase 3: Disabling unneeded services ---"

# Deliberately NOT touching: LanmanServer/Workstation, W32Time, mpssvc (firewall),
# BFE, Dnscache, Dhcp, RpcSs, WinDefend, TermService (RDP), wuauserv (set below, not disabled)
$servicesToDisable = @(
    "XblAuthManager"        # Xbox Live Auth
    "XblGameSave"           # Xbox Live Game Save
    "XboxNetApiSvc"         # Xbox Live Networking
    "XboxGipSvc"            # Xbox Accessory Management
    "MapsBroker"            # Downloaded Maps Manager
    "lfsvc"                 # Geolocation
    "WSearch"                # Windows Search indexing - VM has no local docs to index
    "SysMain"                # Superfetch - actively counterproductive on VM/vdisk storage
    "DiagTrack"              # Connected User Experiences and Telemetry
    "dmwappushservice"       # WAP Push message routing
    "RetailDemo"             # Retail Demo Service
    "Fax"
    "WerSvc"                 # Windows Error Reporting service (kept for troubleshooting - comment out if unwanted)
    "PhoneSvc"
    "BluetoothUserService"
    "bthserv"
)

foreach ($svc in $servicesToDisable) {
    Invoke-Action "Stop and disable service: $svc" {
        Get-Service -Name $svc -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }
}

Invoke-Action "Set Windows Update to notify only (not disabled - security patching still runs manually)" {
    Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# PHASE 4: Telemetry, ads, Widgets, Copilot, Search-Bing integration
# ---------------------------------------------------------------------------
Write-Log "--- Phase 4: Registry tweaks - telemetry, Widgets, Copilot, suggestions ---"

$regTweaks = @(
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortana"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "DisableWebSearch"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "ConnectedSearchUseWeb"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"; Name = "AllowNewsAndInterests"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; Name = "TurnOffWindowsCopilot"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338388Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarDa"; Value = 0; Type = "DWord" }  # Widgets icon
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarMn"; Value = 0; Type = "DWord" }  # Chat icon
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"; Name = "DisableFileSyncNGSC"; Value = 1; Type = "DWord" }
)

foreach ($tweak in $regTweaks) {
    Invoke-Action "Set $($tweak.Path)\$($tweak.Name) = $($tweak.Value)" {
        if (-not (Test-Path $tweak.Path)) { New-Item -Path $tweak.Path -Force | Out-Null }
        New-ItemProperty -Path $tweak.Path -Name $tweak.Name -Value $tweak.Value -PropertyType $tweak.Type -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# PHASE 5: Scheduled tasks that only matter on a desktop
# ---------------------------------------------------------------------------
Write-Log "--- Phase 5: Disabling unneeded scheduled tasks ---"

$tasksToDisable = @(
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"
    "\Microsoft\Windows\Application Experience\ProgramDataUpdater"
    "\Microsoft\Windows\Autochk\Proxy"
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator"
    "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip"
    "\Microsoft\Windows\Feedback\Siuf\DmClient"
    "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload"
    "\Microsoft\Windows\Maps\MapsToastTask"
    "\Microsoft\Windows\Maps\MapsUpdateTask"
    "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
)

foreach ($task in $tasksToDisable) {
    Invoke-Action "Disable scheduled task: $task" {
        Disable-ScheduledTask -TaskPath (Split-Path $task -Parent) -TaskName (Split-Path $task -Leaf) -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---------------------------------------------------------------------------
# PHASE 6: Power - VMs gain nothing from sleep/hibernate/fast startup
# ---------------------------------------------------------------------------
Write-Log "--- Phase 6: Power configuration ---"

Invoke-Action "Set power plan to High Performance" {
    powercfg /setactive SCHEME_MIN | Out-Null
}
Invoke-Action "Disable hibernation" {
    powercfg /hibernate off
}
Invoke-Action "Disable Fast Startup" {
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
}
Invoke-Action "Disable sleep (AC and DC)" {
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
}

# ---------------------------------------------------------------------------
# PHASE 7: Visual effects - Best Performance (irrelevant over RDP anyway)
# ---------------------------------------------------------------------------
Write-Log "--- Phase 7: Visual effects set to Best Performance ---"

Invoke-Action "Set visual effects to Best Performance" {
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -PropertyType DWord -Force | Out-Null
}
Invoke-Action "Disable transparency effects" {
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0 -PropertyType DWord -Force | Out-Null
}

# ---------------------------------------------------------------------------
# PHASE 8: Defender exclusion for AMP (safer than disabling Defender)
# ---------------------------------------------------------------------------
if ($AmpInstancesPath) {
    Invoke-Action "Add Defender exclusion for AMP instances folder: $AmpInstancesPath" {
        Add-MpPreference -ExclusionPath $AmpInstancesPath -ErrorAction SilentlyContinue
    }
} else {
    Write-Log "No -AmpInstancesPath supplied - skipping Defender exclusion. Recommend re-running with it once AMP is installed, e.g. -AmpInstancesPath 'C:\AMP\Instances'" 'WARN'
}

if ($DisableDefender) {
    Write-Log "DisableDefender flag set - disabling real-time protection. NOT recommended for AMP hosts that pull updates from the internet." 'WARN'
    Invoke-Action "Disable Windows Defender real-time protection" {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# PHASE 9: Cleanup
# ---------------------------------------------------------------------------
Write-Log "--- Phase 9: Cleanup ---"
Invoke-Action "Clear temp files" {
    Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Log "=== Complete. $script:changes change(s) applied. A restart is recommended before spinning up AMP instances. ==="

if ($DryRun) {
    Write-Log "This was a DRY RUN - nothing was actually changed. Re-run without -DryRun to apply." 'DRYRUN'
}
