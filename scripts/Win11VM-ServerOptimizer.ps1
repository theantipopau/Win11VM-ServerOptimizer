#Requires -Version 5.1
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
      - OneDrive, Cortana, Search-Bing integration, Start menu suggestions, Search Highlights
      - Optional features not needed headless: Media Player, Fax & Scan, WordPad, XPS, Steps Recorder
      - Visual effects (set to Best Performance)
      - SysMain/Superfetch, Fast Startup, hibernation (VMs don't benefit from these, they just burn disk/RAM)
      - Background app permissions, unneeded scheduled tasks (Customer Experience, Feedback, etc.)
      - Network throttling on background traffic, Game Bar/GameDVR, Delivery Optimization P2P sharing,
        NIC power management (prevents adapters sleeping under load), power throttling of background
        processes, and processor scheduling left on "Programs" rather than "Background services"

    Before making changes, checks for common already-running server software (Plex, Jellyfin, Emby,
    Sonarr, Radarr, Prowlarr, Bazarr, Lidarr, Readarr, qBittorrent, SABnzbd, NZBGet, Deluge,
    Transmission, AMP, Source dedicated servers, Java/Minecraft, SteamCMD) and surfaces it in the
    confirmation prompt. If any of it is running, the temp-file cleanup phase is skipped entirely
    rather than risk touching an active transcode, extraction, or update's temp files.

    Every change that can be reverted is recorded to a JSON change record as it is made (original
    service start types, feature/capability state, scheduled task state, and the previous value of
    every registry value touched). Point Restore-ServerDefaults.ps1 at that file to put the box back
    the way it was. AppX packages are not auto-restorable - Windows has no supported "re-add this
    consumer app" operation - so they are recorded for reporting only.

.PARAMETER DryRun
    Shows what would change without making changes. Nothing is written to the change record.

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

    These are applied first, before any removal work, so the operations that follow (AppX and
    optional-feature servicing, which touch a lot of files) aren't fighting real-time scanning.

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

.PARAMETER StatePath
    Where to write the JSON change record that Restore-ServerDefaults.ps1 reads. Defaults alongside
    the log under ProgramData. The record is merged across runs - original values recorded on the
    first run are never overwritten by later runs, so a re-run can't "forget" what the box looked
    like before it was first touched.

.PARAMETER LogPath
    Where to write the log file. Defaults to a folder under ProgramData (works regardless of whether
    the current user's Desktop exists, e.g. when OneDrive Known Folder Move has relocated it).
    Rotated to <LogPath>.1 once it passes 5 MB, so repeated runs don't grow it without bound.

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
    [string]$StatePath = "$env:ProgramData\Win11VM-ServerOptimizer\state.json",
    [string]$LogPath = "$env:ProgramData\Win11VM-ServerOptimizer\Win11VM-ServerOptimizer.log"
)

$script:ScriptVersion = '1.5.0'
$script:StateSchemaVersion = 1

if ($ExclusionPaths) {
    $ExclusionPaths = $ExclusionPaths | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

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

$LogPath = New-LogDirectory -Path $LogPath -FallbackName 'Win11VM-ServerOptimizer.log'
$StatePath = New-LogDirectory -Path $StatePath -FallbackName 'state.json'

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
$script:lastActionOk = $false

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
    $script:lastActionOk = $false
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
        $script:lastActionOk = $true
    } catch {
        Write-Log "$Description -- FAILED: $($_.Exception.Message)" 'ERROR'
        $script:errors++
    }
}

# ---------------------------------------------------------------------------
# Change record - everything reversible is recorded before it is changed, so
# Restore-ServerDefaults.ps1 can undo this specific run rather than guessing at
# this machine's "defaults".
# ---------------------------------------------------------------------------
function Initialize-State {
    $script:state = $null

    if (Test-Path -LiteralPath $StatePath) {
        try {
            $loaded = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $loaded -or $loaded.schemaVersion -ne $script:StateSchemaVersion) {
                throw "unrecognised change-record format (schemaVersion '$($loaded.schemaVersion)')"
            }
            $script:state = $loaded
            Write-Log "Found an existing change record from $($script:state.firstRun); original values it holds will be preserved rather than re-recorded." 'INFO'
            return
        } catch {
            if ($DryRun) {
                Write-Log "Change record at '$StatePath' could not be read ($($_.Exception.Message)). A real run would move it aside and start a new one." 'WARN'
            } else {
                $corrupt = "$StatePath.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
                Move-Item -LiteralPath $StatePath -Destination $corrupt -Force -ErrorAction SilentlyContinue
                Write-Log "Change record at '$StatePath' could not be read ($($_.Exception.Message)). Moved it to '$corrupt' and started a new one - original values from the earlier run are no longer available in the record." 'WARN'
            }
        }
    }

    if (-not $script:state) {
        $script:state = [pscustomobject]@{
            schemaVersion        = $script:StateSchemaVersion
            scriptVersion        = $script:ScriptVersion
            createdOn            = (Get-Date).ToString('o')
            lastRun              = (Get-Date).ToString('o')
            services             = @()
            features             = @()
            capabilities         = @()
            tasks                = @()
            registry             = @()
            power                = $null
            hibernation          = $null
            reservedStorage      = $null
            powerManagedAdapters = @()
            appxRemoved          = @()
        }
    }
}

function Save-State {
    if ($DryRun) { return }
    try {
        $script:state.lastRun = (Get-Date).ToString('o')
        $script:state.scriptVersion = $script:ScriptVersion
        $json = $script:state | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $StatePath -Value $json -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log "Could not write the change record to '$StatePath' ($($_.Exception.Message)). Settings were still applied, but Restore-ServerDefaults.ps1 will not be able to undo this run." 'ERROR'
        $script:errors++
    }
}

function Get-StateRecord {
    param(
        [string]$Collection,
        [hashtable]$Match
    )
    foreach ($record in @($script:state.$Collection)) {
        $isMatch = $true
        foreach ($key in $Match.Keys) {
            if ($record.$key -ne $Match[$key]) { $isMatch = $false; break }
        }
        if ($isMatch) { return $record }
    }
    return $null
}

function Add-StateRecord {
    param(
        [string]$Collection,
        [pscustomobject]$Record
    )
    $script:state.$Collection = @($script:state.$Collection) + $Record
    # Written through immediately rather than only at the end of the run: a Ctrl+C, a reboot from a
    # pending servicing operation, or a crash mid-phase must not lose the original values for changes
    # that were already applied. Recording slightly more than was actually changed is harmless - the
    # restore script skips anything already in the requested state.
    Save-State
}

function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )

    $existed = $false
    $current = $null
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($key.GetValueNames() -contains $Name) {
            $existed = $true
            $current = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    } catch [System.Management.Automation.ItemNotFoundException] {
        $existed = $false
    } catch [System.Security.SecurityException] {
        $existed = $false
    }

    if ($existed -and $current -eq $Value) {
        Write-Log "Registry value already set: $Path\$Name = $Value" 'SKIP'
        return
    }

    if ($DryRun) {
        Write-Log "DRY RUN - would record the current value and set $Path\$Name = $Value" 'DRYRUN'
        return
    }

    if (-not (Get-StateRecord -Collection 'registry' -Match @{ path = $Path; name = $Name })) {
        Add-StateRecord -Collection 'registry' -Record ([pscustomobject]@{
                path          = $Path
                name          = $Name
                existed       = $existed
                originalValue = $current
                type          = $Type
            })
    }

    Invoke-Action "Set $Path\$Name = $Value" {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
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

function Get-RunningServerProcess {
    Get-Process -Name $knownServerProcessNames -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ProcessName -Unique | Sort-Object
}

Write-Banner
Write-Log "=== Win11VM-ServerOptimizer v$script:ScriptVersion starting (DryRun=$DryRun) ==="

$script:runningServerProcesses = Get-RunningServerProcess
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

# Loaded only after the operator has confirmed - a declined run should not touch the change record
# (reading it is harmless, but renaming a corrupt one is not something to do without consent).
Initialize-State

if ($CreateRestorePoint -and -not $DryRun) {
    Invoke-Action "Create System Restore point" {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description "Win11VM-ServerOptimizer pre-change ($script:ScriptVersion)" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
    }
    Write-Log "Note: Windows only allows one restore point per 24 hours by default - if one was already created recently, no new one was made just now." 'INFO'
}

# ---------------------------------------------------------------------------
# PHASE 0: Defender exclusions
# Applied before the removal phases on purpose: AppX and optional-feature
# servicing rewrites a lot of files, and paying for real-time scans on all of
# it - data folders included - is exactly the cost -ExclusionPaths exists to avoid.
# ---------------------------------------------------------------------------
Write-Log "--- Phase 0: Defender exclusions for server data folders ---"

if ($ExclusionPaths) {
    $existingExclusions = @()
    try {
        $existingExclusions = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
    } catch {
        Write-Log "Could not read current Defender exclusions ($($_.Exception.Message)) - will attempt to add them anyway." 'WARN'
    }

    $addedExclusions = @()
    foreach ($path in $ExclusionPaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Log "Exclusion path does not exist yet (Defender will still accept it, applies once something appears there): $path" 'WARN'
        }
        if ($existingExclusions -contains $path) {
            Write-Log "Defender exclusion already present: $path" 'SKIP'
            continue
        }
        Invoke-Action "Add Defender exclusion for folder: $path" {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
        }
        if ($script:lastActionOk) { $addedExclusions += $path }
    }

    if (-not $DryRun) {
        $verified = @()
        try {
            $verified = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
        } catch {
            Write-Log "Could not re-read Defender exclusions to verify them ($($_.Exception.Message))." 'WARN'
        }
        foreach ($path in $addedExclusions) {
            if ($verified -notcontains $path) {
                Write-Log "Defender exclusion for '$path' was accepted but is not in the exclusion list afterwards - Tamper Protection or a policy may be re-adding/blocking exclusions. Check Windows Security > Virus & threat protection > Exclusions." 'WARN'
            }
        }
    }
} else {
    Write-Log "No -ExclusionPaths supplied - skipping Defender exclusions. Recommend re-running with your server data folders once installed, e.g. -ExclusionPaths 'C:\AMP\Instances','D:\Plex\Transcode'" 'WARN'
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

    if ($script:lastActionOk -and -not (Get-StateRecord -Collection 'appxRemoved' -Match @{ name = $app })) {
        # Recorded for reporting only - Windows has no supported way to re-add a removed consumer app.
        Add-StateRecord -Collection 'appxRemoved' -Record ([pscustomobject]@{ name = $app })
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
    $featureInfo = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
    if (-not $featureInfo -or $featureInfo.State -eq 'Disabled') {
        Write-Log "Optional feature already disabled or not present: $feature" 'SKIP'
        continue
    }
    if (-not $DryRun -and -not (Get-StateRecord -Collection 'features' -Match @{ name = $feature })) {
        Add-StateRecord -Collection 'features' -Record ([pscustomobject]@{ name = $feature })
    }
    Invoke-Action "Disable optional feature: $feature" {
        Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart -ErrorAction Stop | Out-Null
    }
}

$wordpad = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Microsoft.Windows.WordPad*" -and $_.State -eq 'Installed' }
if ($wordpad) {
    foreach ($capability in $wordpad) {
        if (-not $DryRun -and -not (Get-StateRecord -Collection 'capabilities' -Match @{ name = $capability.Name })) {
            Add-StateRecord -Collection 'capabilities' -Record ([pscustomobject]@{ name = $capability.Name })
        }
    }
    Invoke-Action "Remove WordPad capability" {
        $wordpad | Remove-WindowsCapability -Online -ErrorAction Stop | Out-Null
    }
} else {
    Write-Log "WordPad capability already removed or not present" 'SKIP'
}

$stepsRecorder = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "App.StepsRecorder*" -and $_.State -eq 'Installed' }
if ($stepsRecorder) {
    foreach ($capability in $stepsRecorder) {
        if (-not $DryRun -and -not (Get-StateRecord -Collection 'capabilities' -Match @{ name = $capability.Name })) {
            Add-StateRecord -Collection 'capabilities' -Record ([pscustomobject]@{ name = $capability.Name })
        }
    }
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
    "WSearch"               # Windows Search indexing - see -KeepSearch if clients search shares over SMB
    "SysMain"               # Superfetch - actively counterproductive on VM/vdisk storage
    "DiagTrack"             # Connected User Experiences and Telemetry
    "dmwappushservice"      # WAP Push message routing
    "RetailDemo"            # Retail Demo Service
    "Fax"
    "PhoneSvc"
    "RemoteRegistry"        # remote registry editing - a network attack surface no server here needs
    "WMPNetworkSvc"         # Media Player Network Sharing - moot once Media Player is removed above
    "icssvc"                # Windows Mobile Hotspot Service
    "BluetoothUserService*" # per-user service, name has a random per-session suffix - wildcard needed
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
        if (-not $DryRun -and -not (Get-StateRecord -Collection 'services' -Match @{ name = $service.Name })) {
            Add-StateRecord -Collection 'services' -Record ([pscustomobject]@{
                    name               = $service.Name
                    originalStartType  = $service.StartType.ToString()
                    originalStatus     = $service.Status.ToString()
                })
        }
        Invoke-Action "Stop and disable service: $($service.Name)" {
            if ($service.Status -ne 'Stopped') { Stop-Service -Name $service.Name -Force -ErrorAction Stop }
            Set-Service -Name $service.Name -StartupType Disabled -ErrorAction Stop
        }
    }
}

$wuauserv = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
if (-not $wuauserv) {
    Write-Log "Windows Update service not present on this edition - skipping" 'SKIP'
} elseif ($wuauserv.StartType -eq 'Manual') {
    Write-Log "Windows Update service already set to Manual" 'SKIP'
} else {
    Invoke-Action "Set Windows Update to notify only (not disabled - security patching still runs manually)" {
        Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop
    }
}

# ---------------------------------------------------------------------------
# PHASE 4: Telemetry, ads, Widgets, Copilot, Search-Bing integration, suggestions
# ---------------------------------------------------------------------------
Write-Log "--- Phase 4: Registry tweaks - telemetry, Widgets, Copilot, suggestions ---"

Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0
Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0
Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableWebSearch" -Value 1
Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "ConnectedSearchUseWeb" -Value 0
Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0
Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1
Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Name "DisableFileSyncNGSC" -Value 1
Set-RegValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-338388Enabled" -Value 0  # Start menu suggestions
Set-RegValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-338389Enabled" -Value 0  # "tips, tricks, and suggestions"
Set-RegValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-310093Enabled" -Value 0  # post-update welcome experience
Set-RegValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "ScoobeSystemSettingEnabled" -Value 0      # "finish setting up your device" prompts
Set-RegValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SoftLandingEnabled" -Value 0               # Windows welcome/tips after updates
Set-RegValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SilentInstalledAppsEnabled" -Value 0
Set-RegValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa" -Value 0                             # Widgets icon
Set-RegValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarMn" -Value 0                             # Chat icon
Set-RegValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" -Name "IsDynamicSearchBoxEnabled" -Value 0               # Search Highlights

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
    if (-not $DryRun -and -not (Get-StateRecord -Collection 'tasks' -Match @{ taskPath = $taskPath; taskName = $taskName })) {
        Add-StateRecord -Collection 'tasks' -Record ([pscustomobject]@{
                taskPath = $taskPath
                taskName = $taskName
            })
    }
    Invoke-Action "Disable scheduled task: $task" {
        Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Out-Null
    }
}

# ---------------------------------------------------------------------------
# PHASE 6: Power - VMs gain nothing from sleep/hibernate/fast startup
# ---------------------------------------------------------------------------
Write-Log "--- Phase 6: Power configuration ---"

$activeScheme = $null
try {
    $schemeOutput = (& powercfg /getactivescheme) -join ' '
    if ($schemeOutput -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $activeScheme = $Matches[1]
    }
} catch {
    Write-Log "Could not read the active power scheme ($($_.Exception.Message))." 'WARN'
}

if ($null -eq $script:state.power) {
    if ($DryRun) {
        Write-Log "DRY RUN - would record the active power scheme ($activeScheme) before changing it" 'DRYRUN'
    } else {
        $script:state.power = [pscustomobject]@{ activeScheme = $activeScheme }
        Save-State
    }
}

if ($activeScheme -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') {
    Write-Log "Power plan already High Performance" 'SKIP'
} else {
    Invoke-Action "Set power plan to High Performance" {
        powercfg /setactive SCHEME_MIN | Out-Null
    }
}

$hibernationKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
$hibernateEnabled = (Get-ItemProperty -LiteralPath $hibernationKey -Name 'HibernateEnabled' -ErrorAction SilentlyContinue).HibernateEnabled
if ($null -eq $script:state.hibernation) {
    if ($DryRun) {
        Write-Log "DRY RUN - would record whether hibernation was enabled before disabling it" 'DRYRUN'
    } else {
        $script:state.hibernation = [pscustomobject]@{ wasEnabled = ($hibernateEnabled -eq 1) }
        Save-State
    }
}

if ($hibernateEnabled -eq 0) {
    Write-Log "Hibernation already disabled" 'SKIP'
} else {
    Invoke-Action "Disable hibernation" {
        powercfg /hibernate off
    }
}

Set-RegValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0  # Fast Startup

$sleepQuery = (& powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE) -join "`n"
$acSleepDisabled = $sleepQuery -match 'Current AC Power Setting Index:\s*0x00000000'
$dcSleepDisabled = $sleepQuery -match 'Current DC Power Setting Index:\s*0x00000000'
if ($acSleepDisabled -and $dcSleepDisabled) {
    Write-Log "Sleep already disabled (AC and DC)" 'SKIP'
} else {
    Invoke-Action "Disable sleep (AC and DC)" {
        powercfg /change standby-timeout-ac 0
        powercfg /change standby-timeout-dc 0
    }
}

# ---------------------------------------------------------------------------
# PHASE 7: Visual effects - Best Performance (irrelevant over RDP anyway)
# ---------------------------------------------------------------------------
Write-Log "--- Phase 7: Visual effects set to Best Performance ---"

Set-RegValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2
Set-RegValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0

# ---------------------------------------------------------------------------
# PHASE 8: Network, scheduling, and background-task tuning for server workloads
# ---------------------------------------------------------------------------
Write-Log "--- Phase 8: Network, scheduling & background-task tuning ---"

Set-RegValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 0xffffffff  # removes the ~10Mbps cap on background network traffic
Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 0                            # HTTP only - no peer-to-peer upload/download of Windows Update payloads
Set-RegValue -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0
Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0

# Processor scheduling: 0x18 (24) is what Performance Options writes for "Background services" -
# long, fixed quantums with no foreground boost. The Windows client default (2) resolves to short,
# variable quantums with a boost for whichever window has focus, which is exactly backwards for a
# box whose real work is in services nobody is looking at. This matches the Windows Server default.
Set-RegValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Value 24

# Windows throttles background process CPU (EcoQoS) to save battery/thermals on laptops. On a
# server the "background" process is the workload; without this, long-running service work can be
# scheduled onto low-power cores or capped.
Set-RegValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Name "PowerThrottlingOff" -Value 1

# "Allow the computer to turn off this device to save power" is not exposed by
# Set-NetAdapterPowerManagement (no such parameter - the previous call here silently did nothing)
# and Disable-NetAdapterPowerManagement only covers wake/offload flags. The setting lives on the
# device's MSPower_DeviceEnable WMI instance, matched to an adapter by its PnP device id.
$adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PnPDeviceID })
$powerManagedDevices = @()
if ($adapters.Count -gt 0) {
    $powerEnableDevices = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | Where-Object { $_.Enable })
    foreach ($adapter in $adapters) {
        $powerManagedDevices += @($powerEnableDevices | Where-Object { $_.InstanceName -like "$($adapter.PnPDeviceID)*" })
    }
    $powerManagedDevices = @($powerManagedDevices | Sort-Object InstanceName -Unique)
}

if ($adapters.Count -eq 0) {
    Write-Log "No network adapters found - skipping NIC power management" 'SKIP'
} elseif ($powerManagedDevices.Count -eq 0) {
    Write-Log "No network adapter currently allows Windows to power it down - nothing to change" 'SKIP'
} elseif ($DryRun) {
    Write-Log "DRY RUN - would stop Windows powering down $($powerManagedDevices.Count) network adapter(s)" 'DRYRUN'
} else {
    foreach ($device in $powerManagedDevices) {
        try {
            Set-CimInstance -InputObject $device -Property @{ Enable = $false } -ErrorAction Stop
            # Recorded only after the write succeeded, so restore never re-enables something that
            # was never changed.
            if (-not (Get-StateRecord -Collection 'powerManagedAdapters' -Match @{ instanceName = $device.InstanceName })) {
                Add-StateRecord -Collection 'powerManagedAdapters' -Record ([pscustomobject]@{ instanceName = $device.InstanceName })
            }
        } catch {
            Write-Log "Could not change power management for network device '$($device.InstanceName)': $($_.Exception.Message)" 'ERROR'
            $script:errors++
        }
    }

    $stillPowerManaged = @()
    $remainingDevices = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | Where-Object { $_.Enable })
    foreach ($adapter in $adapters) {
        $stillPowerManaged += @($remainingDevices | Where-Object { $_.InstanceName -like "$($adapter.PnPDeviceID)*" })
    }
    $stillPowerManaged = @($stillPowerManaged | Sort-Object InstanceName -Unique)

    if ($stillPowerManaged.Count -eq 0) {
        Write-Log "Stopped Windows from powering down $($powerManagedDevices.Count) network adapter(s)" 'OK'
        $script:changes++
    } elseif ($stillPowerManaged.Count -lt $powerManagedDevices.Count) {
        Write-Log "Stopped Windows from powering down $($powerManagedDevices.Count - $stillPowerManaged.Count) of $($powerManagedDevices.Count) adapter(s); $($stillPowerManaged.Count) still allow it (firmware or a vendor driver may enforce power management)" 'WARN'
        $script:changes++
    } else {
        Write-Log "No adapter accepted the power management change - firmware or a vendor driver is overriding it on all $($powerManagedDevices.Count) adapter(s)" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# PHASE 9: Reserved storage
# Windows keeps ~7 GB reserved for update/component servicing. On a fixed-size
# server VM disk that is a lot of permanently idle space; DISM releases it and
# Windows Update still works (it just can't pre-stage as much).
# ---------------------------------------------------------------------------
Write-Log "--- Phase 9: Reserved storage ---"

$reservedStorageState = $null
try {
    $dismOutput = (& dism.exe /Online /Get-ReservedStorageState) -join ' '
    if ($dismOutput -match 'Enabled') { $reservedStorageState = 'Enabled' }
    elseif ($dismOutput -match 'Disabled') { $reservedStorageState = 'Disabled' }
} catch {
    Write-Log "Could not read the reserved storage state ($($_.Exception.Message))." 'WARN'
}

if ($null -eq $reservedStorageState) {
    $dismSnippet = (($dismOutput -replace '\s+', ' ').Trim())
    if ($dismSnippet.Length -gt 120) { $dismSnippet = $dismSnippet.Substring(0, 120) }
    Write-Log "Reserved storage state could not be determined on this build - skipping (not supported here, or DISM is busy). DISM said: $dismSnippet" 'SKIP'
} elseif ($reservedStorageState -eq 'Disabled') {
    Write-Log "Reserved storage already disabled" 'SKIP'
} else {
    if ($null -eq $script:state.reservedStorage) {
        if ($DryRun) {
            Write-Log "DRY RUN - would record that reserved storage was enabled before releasing it" 'DRYRUN'
        } else {
            $script:state.reservedStorage = [pscustomobject]@{ wasEnabled = $true }
            Save-State
        }
    }
    Invoke-Action "Disable reserved storage (releases ~7 GB held for update servicing)" {
        dism.exe /Online /Set-ReservedStorageState /State:Disabled | Out-Null
    }
}

# ---------------------------------------------------------------------------
# PHASE 10: Optional Defender real-time disable
# ---------------------------------------------------------------------------
if ($DisableDefender) {
    Write-Log "--- Phase 10: Defender real-time protection ---"
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
# PHASE 11: Cleanup
# ---------------------------------------------------------------------------
Write-Log "--- Phase 11: Cleanup ---"

$tempTargets = @("$env:TEMP", "$env:SystemRoot\Temp") | Where-Object { Test-Path -LiteralPath $_ }

if ($script:runningServerProcesses) {
    Write-Log "Skipping temp file cleanup - server software is running ($($script:runningServerProcesses -join ', ')) and may be using temp folders for active transcodes or archive extraction. Re-run during a maintenance window to clean up temp files." 'WARN'
} elseif ($DryRun) {
    Write-Log "DRY RUN - would clear temp files in: $($tempTargets -join ', ')" 'DRYRUN'
} else {
    $before = 0
    foreach ($target in $tempTargets) {
        $before += @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue).Count
    }
    foreach ($target in $tempTargets) {
        Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    $after = 0
    foreach ($target in $tempTargets) {
        $after += @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue).Count
    }

    if ($before -eq 0) {
        Write-Log "Temp folders already empty" 'SKIP'
    } elseif ($after -eq 0) {
        Write-Log "Cleared temp files ($before item(s) removed)" 'OK'
        $script:changes++
    } elseif ($after -lt $before) {
        Write-Log "Cleared temp files ($($before - $after) of $before removed; $after still locked by running processes - normal, retried next run)" 'OK'
        $script:changes++
    } else {
        Write-Log "No temp files could be removed - all $before item(s) are locked by running processes" 'WARN'
    }
}

Save-State

Write-Log "=== Complete. $script:changes change(s) applied, $script:errors error(s). A restart is recommended before starting your server workloads. ==="
Write-Log "Change record: $StatePath - pass it to Restore-ServerDefaults.ps1 to undo this run." 'INFO'

if ($DryRun) {
    Write-Log "This was a DRY RUN - nothing was actually changed. Re-run without -DryRun to apply." 'DRYRUN'
}

if ($script:errors -gt 0) {
    exit 1
}
exit 0
