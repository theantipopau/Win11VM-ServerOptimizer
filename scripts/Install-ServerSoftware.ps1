#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install-ServerSoftware - Opt-in installer for common headless server workloads via winget.

.DESCRIPTION
    Companion to Win11VM-ServerOptimizer.ps1. That script strips the OS down; this one installs
    the actual server software you want to run on top of it. Kept as a separate script on purpose
    - the optimizer only ever removes/configures, it never installs, and mixing the two would make
    it unclear what running "the optimizer" actually does to a box.

    Everything here goes through winget (the built-in, Microsoft-signed package manager) rather
    than downloading installers from arbitrary URLs. Nothing is installed unless you pass its
    switch - running the script with no switches does nothing.

    Deliberately installs Docker ENGINE, not Docker Desktop:
      - Docker Desktop is a GUI app with a system tray presence and a paid license for larger
        commercial use - the opposite of what a headless, stripped-down server wants.
      - Docker Engine is installed as a Windows service (dockerd) with no GUI, via the same
        DockerMsftProvider PowerShell module Microsoft's own Windows Server docs use.
      - Requires the "Containers" Windows optional feature, which needs a restart before Docker
        itself can be installed. -DockerEngine runs in two passes: the first run enables the
        feature and stops there; after you reboot, run it again with -DockerEngine to install
        Docker itself.

.PARAMETER DryRun
    Shows what would be installed/changed without making changes.

.PARAMETER Force
    Skips the "are you sure?" confirmation prompt before installing anything. Use for unattended/scripted runs.

.PARAMETER DockerEngine
    Installs Docker Engine (headless, service-based) - enables the Containers optional feature,
    installs the DockerMsftProvider PowerShell module, then installs Docker via that provider.

.PARAMETER Plex
    Installs Plex Media Server via winget.

.PARAMETER Jellyfin
    Installs Jellyfin Server via winget.

.PARAMETER Emby
    Installs Emby Server via winget.

.PARAMETER WingetId
    One or more additional winget package IDs to install as-is, e.g. -WingetId "Valve.Steam","RARLab.WinRAR".
    Use `winget search <name>` to find IDs for anything not covered by the switches above.

.PARAMETER All
    Shorthand for -DockerEngine -Plex -Jellyfin -Emby.

.PARAMETER LogPath
    Where to write the log file. Defaults to Desktop.

.EXAMPLE
    .\Install-ServerSoftware.ps1 -DryRun -All
    .\Install-ServerSoftware.ps1 -DockerEngine -Jellyfin
    .\Install-ServerSoftware.ps1 -WingetId "Valve.Steam"
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$DockerEngine,
    [switch]$Plex,
    [switch]$Jellyfin,
    [switch]$Emby,
    [string[]]$WingetId,
    [switch]$All,
    [string]$LogPath = "$env:USERPROFILE\Desktop\Install-ServerSoftware.log"
)

if ($All) {
    $DockerEngine = $true
    $Plex = $true
    $Jellyfin = $true
    $Emby = $true
}

$ErrorActionPreference = 'Continue'
$script:changes = 0
$script:ScriptVersion = '1.1.0'

function Write-Banner {
    $lines = @(
        "Install-ServerSoftware  v$script:ScriptVersion"
        "Opt-in installer for headless server workloads"
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
    }
}

function Install-WingetPackage {
    param([string]$Id, [string]$FriendlyName)

    $global:LASTEXITCODE = 0
    winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "$FriendlyName (winget id: $Id) is already installed - skipping" 'INFO'
        return
    }

    Invoke-Action "Install $FriendlyName (winget id: $Id)" {
        $result = winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements 2>&1
        $result | ForEach-Object { Write-Log "  winget: $_" 'INFO' }
        if ($LASTEXITCODE -ne 0) {
            throw "winget exited with code $LASTEXITCODE"
        }
    }
}

Write-Banner
Write-Log "=== Install-ServerSoftware v$script:ScriptVersion starting (DryRun=$DryRun) ==="

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Log "winget was not found on this system. Install 'App Installer' from the Microsoft Store, then re-run this script." 'ERROR'
    exit 1
}

if (-not ($DockerEngine -or $Plex -or $Jellyfin -or $Emby -or $WingetId)) {
    Write-Log "No software selected - nothing to do. Pass -DockerEngine, -Plex, -Jellyfin, -Emby, -WingetId <id>, or -All." 'WARN'
    exit 0
}

if (-not $DryRun -and -not $Force) {
    $confirm = Read-Host "This will install software on THIS machine. Continue? [y/N]"
    if ($confirm -notmatch '^(y|yes)$') {
        Write-Log "User declined confirmation - exiting without installing anything." 'WARN'
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Docker Engine (headless, service-based - not Docker Desktop)
# ---------------------------------------------------------------------------
if ($DockerEngine) {
    Write-Log "--- Docker Engine ---"

    # The Containers feature only becomes usable after a reboot. Installing the Docker package
    # before that reboot has happened is a documented source of broken installs, so this is done
    # as two passes: enable the feature and stop, then (on a later run, after reboot) install Docker.
    $containersFeature = Get-WindowsOptionalFeature -Online -FeatureName Containers -ErrorAction SilentlyContinue
    $containersAlreadyEnabled = $containersFeature -and $containersFeature.State -eq 'Enabled'

    if (-not $containersAlreadyEnabled) {
        Invoke-Action "Enable Windows Containers feature" {
            Enable-WindowsOptionalFeature -Online -FeatureName Containers -NoRestart -ErrorAction Stop | Out-Null
        }
        if ($DryRun) {
            Write-Log "DRY RUN - Containers feature is not currently enabled. A real run would enable it and stop there; Docker itself would install on a follow-up run after a restart." 'DRYRUN'
        } else {
            Write-Log "Containers feature was just enabled and requires a restart before Docker can be installed. Restart this machine, then re-run with -DockerEngine to finish installing Docker." 'WARN'
        }
    } else {
        Invoke-Action "Install NuGet package provider (required by DockerMsftProvider)" {
            Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
        }
        Invoke-Action "Trust PSGallery repository (required for non-interactive module install)" {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        }
        Invoke-Action "Install DockerMsftProvider PowerShell module" {
            Install-Module -Name DockerMsftProvider -Repository PSGallery -Force -ErrorAction Stop
        }
        Invoke-Action "Install Docker Engine via DockerMsftProvider" {
            Install-Package -Name docker -ProviderName DockerMsftProvider -Force -ErrorAction Stop | Out-Null
        }
        Write-Log "Docker Engine installed. A further restart is recommended before relying on it, then confirm with 'docker version'." 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Media servers
# ---------------------------------------------------------------------------
if ($Plex) {
    Write-Log "--- Plex Media Server ---"
    Install-WingetPackage -Id "Plex.PlexMediaServer" -FriendlyName "Plex Media Server"
}

if ($Jellyfin) {
    Write-Log "--- Jellyfin Server ---"
    Install-WingetPackage -Id "Jellyfin.Server" -FriendlyName "Jellyfin Server"
}

if ($Emby) {
    Write-Log "--- Emby Server ---"
    Install-WingetPackage -Id "Emby.EmbyServer" -FriendlyName "Emby Server"
}

# ---------------------------------------------------------------------------
# Arbitrary additional packages
# ---------------------------------------------------------------------------
if ($WingetId) {
    Write-Log "--- Additional winget packages ---"
    foreach ($id in $WingetId) {
        Install-WingetPackage -Id $id -FriendlyName $id
    }
}

Write-Log "=== Complete. $script:changes change(s) applied. ==="

if ($DryRun) {
    Write-Log "This was a DRY RUN - nothing was actually installed. Re-run without -DryRun to apply." 'DRYRUN'
}
