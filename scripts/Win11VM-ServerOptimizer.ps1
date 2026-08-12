#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Win11VM-ServerOptimizer - Strips a Windows 11 Pro VM/host down for dedicated server hosting.

.DESCRIPTION
    Designed for machines whose ONLY job is running server workloads - game servers (AMP,
    standalone, Source/Java/Bedrock, etc.), media servers (Plex, Jellyfin, Emby), file shares,
    or any other headless-leaning service. No GUI gaming, no word processing, no general desktop
    use expected on the box itself.

    Deliberately left ALONE (do not touch, server roles depend on these):
      - .NET Framework / .NET Desktop Runtime
      - Networking stack, NIC drivers, Windows Firewall service (rules are only tidied, not disabled)
      - Remote Desktop (RDP) - assumed to be your main access method
      - Windows Time service (w32time) - game/media servers care about accurate time
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
      - Network throttling on background traffic, Game Bar/GameDVR, Delivery Optimization P2P sharing,
        NIC power management (prevents adapters sleeping under load)

    Before making changes, checks for common already-running server software (Plex, Jellyfin, Emby,
    Sonarr, Radarr, Prowlarr, Bazarr, Lidarr, Readarr, qBittorrent, SABnzbd, NZBGet, Deluge,
    Transmission, AMP, Source dedicated servers, Java/Minecraft, SteamCMD) and surfaces it in the
    confirmation prompt. If any of it is running, the temp-file cleanup phase is skipped entirely
    rather than risk touching an active transcode, extraction, or update's temp files.

.PARAMETER DryRun
    Shows what would change without making changes.

.PARAMETER Force
    Skips the "are you sure?" confirmation prompt before making changes. Use for unattended/scripted runs.

.PARAMETER DisableDefender
    Also disables Windows Defender real-time protection (NOT recommended unless this box is fully
    network-isolated - most server workloads download/update files constantly, an AV exclusion on
    your data/instances folder is usually the better/safer option, see -ExclusionPaths below).

.PARAMETER ExclusionPaths
    One or more folders to add as Windows Defender exclusions instead of disabling Defender
    entirely - e.g. AMP instances, a Plex/Jellyfin library or transcode folder, a game server's
    data directory. Example: -ExclusionPaths "C:\AMP\Instances","D:\Plex\Transcode"

    NOTE: when launching via the .bat launcher or any other "-File" invocation, PowerShell does not
    parse comma-separated arrays the way it does in an interactive session - multiple values collapse
    into one string. To work around this, a single value containing commas or semicolons is split
    automatically, so both of these work identically:
      -ExclusionPaths "C:\AMP\Instances","D:\Plex\Transcode"      (interactive session)
      -ExclusionPaths "C:\AMP\Instances;D:\Plex\Transcode"        (.bat launcher / -File)

.PARAMETER KeepSearch
    Leaves Windows Search indexing (WSearch) enabled. Disabled by default since a headless box has
    nothing local worth indexing, but if clients search this box's shared folders over SMB from
    File Explorer, that search is served by the host's Windows Search index - pass this if you rely
    on that.

.PARAMETER CreateRestorePoint
    Creates a System Restore point before making any changes (requires System Restore to be available
    and enabled on this edition - not available on Windows Server). Not a substitute for a real
    backup/VM snapshot, but a fast way to undo registry and feature changes if something goes wrong.
    Windows only allows one restore point per 24 hours by default, so this may be a no-op if one was
    already created recently.

.PARAMETER LogPath
    Where to write the log file. Defaults to a folder under ProgramData (works regardless of whether
    the current user's Desktop exists, e.g. when OneDrive Known Folder Move has relocated it).

.EXAMPLE
    .\Win11VM-ServerOptimizer.ps1 -DryRun
    .\Win11VM-ServerOptimizer.ps1 -ExclusionPaths "C:\AMP\Instances","D:\Plex\Transcode"
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$DisableDefender,
    [switch]$KeepSearch,
    [switch]$CreateRestorePoint,
    [string[]]$ExclusionPaths,
    [string]$LogPath = "$env:ProgramData\Win11VM-ServerOptimizer\Win11VM-ServerOptimizer.log"
)

if ($ExclusionPaths) {
    $ExclusionPaths = $ExclusionPaths | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path $logDir)) {
    try {
        New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    } catch {
        $fallback = Join-Path $env:TEMP "Win11VM-ServerOptimizer.log"
        Write-Host "WARNING: Could not create log directory '$logDir' ($($_.Exception.Message)). Falling back to '$fallback'." -ForegroundColor Yellow
        $LogPath = $fallback
    }
}

$ErrorActionPreference = 'Continue'
$script:changes = 0
$script:errors = 0
$script:ScriptVersion = '1.4.0'

function Write-Banner {
    $lines = @(
        "Win11VM Server Optimizer  v$script:ScriptVersion"
        "Optimize. Streamline. Perform."
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
        Write-Log "DRY RUN - would do: $Description" 'DRYRUN'
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

$knownServerProcessNames = @(
    "Plex Media Server"
    "Plex Media Scanner"
    "PlexTranscoder"
    "jellyfin"
    "EmbyServer"
    "Sonarr"
    "Radarr"
    "Prowlarr"
    "Bazarr"
    "Lidarr"
    "Readarr"
    "qbittorrent"
    "SABnzbd"
    "nzbget"
    "deluge*"
    "transmission*"
    "AMPInstMgr*"
    "srcds*"
    "java*"        # broad on purpose - Minecraft servers run as java.exe; worst case is an unnecessary skip
    "steamcmd*"
)

function Get-RunningServerProcesses {
    Get-Process -Name $knownServerProcessNames -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ProcessName -Unique | Sort-Object
}

Write-Banner
Write-Log "=== Win11VM-ServerOptimizer v$script:ScriptVersion starting (DryRun=$DryRun) ==="

$script:runningServerProcesses = Get-RunningServerProcesses
if ($script:runningServerProcesses) {
    Write-Log "Detected running server software: $($script:runningServerProcesses -join ', '). This script does not stop or touch these directly, but the recommended restart afterward will." 'WARN'
}

if (-not $DryRun -and -not $Force) {
    $confirmMessage = "This will modify system settings, services, and the registry on THIS machine."
    if ($script:runningServerProcesses) {
        $confirmMessage += " Detected running: $($script:runningServerProcesses -join ', ')."
    }
    $confirmMessage += " Continue? [y/N]"
    $confirm = Read-Host $confirmMessage
    if ($confirm -notmatch '^(y|yes)$') {
        Write-Log "User declined confirmation - exiting without making changes." 'WARN'
        exit 0
    }
}

if ($CreateRestorePoint -and -not $DryRun) {
    Invoke-Action "Create System Restore point" {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description "Win11VM-ServerOptimizer pre-change ($script:ScriptVersion)" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
    }
    Write-Log "Note: Windows only allows one restore point per 24 hours by default - if one was already created recently, no new one was made just now." 'INFO'
}

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
    $installed = Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue
    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object DisplayName -like "*$app*"

    if (-not $installed -and -not $provisioned) {
        Write-Log "AppX package not present, nothing to remove: $app" 'SKIP'
        continue
    }

    Invoke-Action "Remove AppX package: $app" {
        if ($installed) { $installed | Remove-AppxPackage -AllUsers -ErrorAction Stop }
        if ($provisioned) { $provisioned | Remove-AppxProvisionedPackage -Online -ErrorAction Stop | Out-Null }
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
    $state = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
    if (-not $state -or $state.State -eq 'Disabled') {
        Write-Log "Optional feature already disabled or not present: $feature" 'SKIP'
        continue
    }
    Invoke-Action "Disable optional feature: $feature" {
        Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart -ErrorAction Stop | Out-Null
    }
}

$wordpad = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Microsoft.Windows.WordPad*" -and $_.State -eq 'Installed' }
if ($wordpad) {
    Invoke-Action "Remove WordPad capability" {
        $wordpad | Remove-WindowsCapability -Online -ErrorAction Stop | Out-Null
    }
} else {
    Write-Log "WordPad capability already removed or not present" 'SKIP'
}

$stepsRecorder = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "App.StepsRecorder*" -and $_.State -eq 'Installed' }
if ($stepsRecorder) {
    Invoke-Action "Remove Steps Recorder capability" {
        $stepsRecorder | Remove-WindowsCapability -Online -ErrorAction Stop | Out-Null
    }
} else {
    Write-Log "Steps Recorder capability already removed or not present" 'SKIP'
}

# ---------------------------------------------------------------------------
# PHASE 3: Services - disable what a headless game server box will never use
# ---------------------------------------------------------------------------
Write-Log "--- Phase 3: Disabling unneeded services ---"

# Deliberately NOT touching: LanmanServer/Workstation, W32Time, mpssvc (firewall),
# BFE, Dnscache, Dhcp, RpcSs, WinDefend, TermService (RDP), wuauserv (set below, not disabled)
# WerSvc (Windows Error Reporting) is also deliberately NOT touched - handy for diagnosing a
# crashed game/media server process. See README if you want to disable it yourself.
$servicesToDisable = @(
    "XblAuthManager"        # Xbox Live Auth
    "XblGameSave"           # Xbox Live Game Save
    "XboxNetApiSvc"         # Xbox Live Networking
    "XboxGipSvc"            # Xbox Accessory Management
    "MapsBroker"            # Downloaded Maps Manager
    "lfsvc"                 # Geolocation
    "WSearch"                # Windows Search indexing - see -KeepSearch if clients search shares over SMB
    "SysMain"                # Superfetch - actively counterproductive on VM/vdisk storage
    "DiagTrack"              # Connected User Experiences and Telemetry
    "dmwappushservice"       # WAP Push message routing
    "RetailDemo"             # Retail Demo Service
    "Fax"
    "PhoneSvc"
    "BluetoothUserService*"  # per-user service, name has a random per-session suffix - wildcard needed
    "bthserv"
)

if ($KeepSearch) {
    $servicesToDisable = $servicesToDisable | Where-Object { $_ -ne 'WSearch' }
    Write-Log "-KeepSearch set - leaving Windows Search indexing enabled." 'INFO'
}

foreach ($svc in $servicesToDisable) {
    $services = @(Get-Service -Name $svc -ErrorAction SilentlyContinue)
    if ($services.Count -eq 0) {
        Write-Log "Service not present, nothing to disable: $svc" 'SKIP'
        continue
    }
    foreach ($service in $services) {
        if ($service.StartType -eq 'Disabled' -and $service.Status -eq 'Stopped') {
            Write-Log "Service already stopped and disabled: $($service.Name)" 'SKIP'
            continue
        }
        Invoke-Action "Stop and disable service: $($service.Name)" {
            if ($service.Status -ne 'Stopped') { Stop-Service -Name $service.Name -Force -ErrorAction Stop }
            Set-Service -Name $service.Name -StartupType Disabled -ErrorAction Stop
        }
    }
}

Invoke-Action "Set Windows Update to notify only (not disabled - security patching still runs manually)" {
    Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop
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
        if (-not (Test-Path $tweak.Path)) { New-Item -Path $tweak.Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $tweak.Path -Name $tweak.Name -Value $tweak.Value -PropertyType $tweak.Type -Force -ErrorAction Stop | Out-Null
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
    $taskName = Split-Path $task -Leaf
    $taskPath = (Split-Path $task -Parent) + '\'
    $taskObj = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue

    if (-not $taskObj) {
        Write-Log "Scheduled task not present: $task" 'SKIP'
        continue
    }
    if ($taskObj.State -eq 'Disabled') {
        Write-Log "Scheduled task already disabled: $task" 'SKIP'
        continue
    }
    Invoke-Action "Disable scheduled task: $task" {
        Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Out-Null
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
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
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
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}
Invoke-Action "Disable transparency effects" {
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}

# ---------------------------------------------------------------------------
# PHASE 8: Network & background-task tuning for server workloads
# ---------------------------------------------------------------------------
Write-Log "--- Phase 8: Network & background-task tuning ---"

$serverRegTweaks = @(
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"; Name = "NetworkThrottlingIndex"; Value = 0xffffffff; Type = "DWord" }  # removes the ~10Mbps cap Windows puts on background network traffic
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"; Name = "DODownloadMode"; Value = 0; Type = "DWord" }                               # HTTP only - no peer-to-peer upload/download of Windows Update payloads
    @{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"; Name = "AllowGameDVR"; Value = 0; Type = "DWord" }
)

foreach ($tweak in $serverRegTweaks) {
    Invoke-Action "Set $($tweak.Path)\$($tweak.Name) = $($tweak.Value)" {
        if (-not (Test-Path $tweak.Path)) { New-Item -Path $tweak.Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $tweak.Path -Name $tweak.Name -Value $tweak.Value -PropertyType $tweak.Type -Force -ErrorAction Stop | Out-Null
    }
}

$adaptersWithPowerMgmt = Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue
if (-not $adaptersWithPowerMgmt) {
    Write-Log "No network adapters expose power management settings - skipping NIC power management" 'SKIP'
} else {
    Invoke-Action "Disable power management on network adapters (prevent NIC sleep)" {
        # Some virtual adapters accept the query but reject the actual set - that's a common, expected
        # condition (not a failure worth halting over), so this specific call stays SilentlyContinue.
        $adaptersWithPowerMgmt | Set-NetAdapterPowerManagement -AllowComputerToTurnOffDevice Disabled -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# PHASE 9: Defender exclusions for server data folders (safer than disabling Defender)
# ---------------------------------------------------------------------------
if ($ExclusionPaths) {
    foreach ($path in $ExclusionPaths) {
        if (-not (Test-Path $path)) {
            Write-Log "Exclusion path does not exist yet (Defender will still accept it, applies once something appears there): $path" 'WARN'
        }
        Invoke-Action "Add Defender exclusion for folder: $path" {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
        }
    }
} else {
    Write-Log "No -ExclusionPaths supplied - skipping Defender exclusions. Recommend re-running with your server data folders once installed, e.g. -ExclusionPaths 'C:\AMP\Instances','D:\Plex\Transcode'" 'WARN'
}

if ($DisableDefender) {
    Write-Log "DisableDefender flag set - disabling real-time protection. NOT recommended for hosts that pull updates/media from the internet." 'WARN'
    Invoke-Action "Disable Windows Defender real-time protection" {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
    }
    if (-not $DryRun) {
        $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($mpStatus -and $mpStatus.RealTimeProtectionEnabled) {
            Write-Log "Real-time protection is STILL enabled after attempting to disable it. This usually means Tamper Protection is on - Set-MpPreference cannot override it. Disable Tamper Protection manually in Windows Security if you really want real-time protection off." 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
# PHASE 10: Cleanup
# ---------------------------------------------------------------------------
Write-Log "--- Phase 10: Cleanup ---"

if ($script:runningServerProcesses) {
    Write-Log "Skipping temp file cleanup - server software is running ($($script:runningServerProcesses -join ', ')) and may be using temp folders for active transcodes or archive extraction. Re-run during a maintenance window to clean up temp files." 'WARN'
} else {
    Invoke-Action "Clear temp files" {
        Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Log "=== Complete. $script:changes change(s) applied, $script:errors error(s). A restart is recommended before starting your server workloads. ==="

if ($DryRun) {
    Write-Log "This was a DRY RUN - nothing was actually changed. Re-run without -DryRun to apply." 'DRYRUN'
}

if ($script:errors -gt 0) {
    exit 1
}
exit 0
