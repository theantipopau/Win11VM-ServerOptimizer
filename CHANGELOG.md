# Changelog

This project has two independently-versioned scripts: `Win11VM-ServerOptimizer.ps1` (strips/configures the OS) and `Install-ServerSoftware.ps1` (opt-in software installer). Each entry below notes which one it applies to.

## [1.4.0] - 2026-08-12 (Win11VM-ServerOptimizer.ps1)
Follow-up audit found several places where the script could report success without having actually done (or verified) anything - all fixed here.
### Fixed
- **`-ExclusionPaths` was silently broken when launched via the `.bat` launcher** — PowerShell's `-File` mode doesn't parse comma-separated arrays, so multiple paths collapsed into one malformed string that `Add-MpPreference` accepted without complaint. Now normalizes both comma- and semicolon-separated input regardless of invocation method.
- **Default log path assumed `%USERPROFILE%\Desktop` exists** — false whenever OneDrive Known Folder Move has relocated it, causing every log write to fail silently under `$ErrorActionPreference = 'Continue'`. Default moved to `%ProgramData%\Win11VM-ServerOptimizer\`, with a fallback to `%TEMP%` if even that can't be created.
- **`Invoke-Action` logged `OK` and incremented the change counter for pure no-ops** — every action used `-ErrorAction SilentlyContinue` internally, so "target doesn't exist" and "target existed and was successfully changed" were indistinguishable. AppX removal, optional features/capabilities, services, and scheduled tasks now check for existence/current state first and log a distinct `SKIP` when there's nothing to do; the actual mutating calls now use `-ErrorAction Stop` so genuine failures are caught instead of swallowed.
- **`WerSvc` was being disabled despite the code comment and README both saying it's kept for crash diagnostics** — removed from the disable list so behavior matches the documented intent.
- **`SystemResponsiveness = 0` was backwards** — per Microsoft's own MMCSS documentation this value is the CPU percentage *guaranteed to background tasks* (default 20, server OSes often raise it), not something to zero out for "more background CPU." Removed the tweak entirely rather than guess at a better value.
- **`-DisableDefender` could silently no-op under Tamper Protection** (on by default in Win11) — now verifies `RealTimeProtectionEnabled` after the attempt and explicitly warns if Tamper Protection blocked it.
- **`BluetoothUserService` never matched** — it's a per-user service with a random per-session suffix (`BluetoothUserService_xxxxx`); now matched with a wildcard.
- Script now exits with code `1` if any action failed, `0` otherwise (previously always exited `0`), so scheduled/automated runs can detect failure.
### Added
- Pre-flight process detection now also covers Jellyfin, Emby, AMP, Source dedicated servers, Java/Minecraft, and SteamCMD (previously only Plex/*arr/download clients)
- `-KeepSearch` — leaves Windows Search indexing enabled, for boxes where clients search shared folders over SMB from File Explorer
- `-CreateRestorePoint` — creates a System Restore point before changes (Windows client editions only)
- Exclusion paths that don't exist yet are now flagged with a warning (Defender still accepts them) instead of failing silently

## [1.3.0] - 2026-07-13 (Win11VM-ServerOptimizer.ps1)
### Added
- Pre-flight detection of already-running server software (Plex, Sonarr, Radarr, Prowlarr, Bazarr, Lidarr, Readarr, qBittorrent, SABnzbd, NZBGet, Deluge, Transmission), surfaced in the confirmation prompt
- Temp-file cleanup (Phase 10) is now skipped entirely if any of the above is detected running, instead of risking an active transcode or archive extraction's temp files

## [1.2.0] - 2026-07-13 (Win11VM-ServerOptimizer.ps1)
### Added
- Network & background-task tuning phase: `NetworkThrottlingIndex` removed, `SystemResponsiveness` set to 0, Delivery Optimization forced to HTTP-only, Game Bar/GameDVR disabled, NIC power management disabled
- `-Force` switch and a confirmation prompt before any non-dry-run change
### Fixed
- Native command failures (`powercfg`, etc.) are now correctly detected instead of silently logging as `OK`

## [1.2.0] - 2026-08-12 (Install-ServerSoftware.ps1)
### Fixed
- Same `-File`-launcher array-binding bug as the optimizer's `-ExclusionPaths` (see 1.4.0 above), affecting `-WingetId` — fixed the same way
- Same nonexistent-Desktop `LogPath` default bug — fixed the same way

## [1.1.0] - 2026-07-13 (Install-ServerSoftware.ps1)
### Added
- `-Force` switch and a confirmation prompt before installing anything
### Fixed
- PSGallery is now marked trusted before `Install-Module`, preventing an unattended run from hanging on an interactive prompt
- Docker Engine install now runs in two passes (enable the `Containers` feature and stop, then install Docker after a reboot) instead of attempting both before the required restart
- Native command / winget failures are now correctly detected instead of silently logging as `OK`
- Replaced an undocumented "already installed" winget exit code with an explicit `winget list` check

## [1.1.0] - 2026-07-13 (Win11VM-ServerOptimizer.ps1)
### Changed
- Generalized from AMP-only to any server workload: `-AmpInstancesPath` replaced with `-ExclusionPaths` (accepts multiple folders), banner/README rewritten to cover game servers, media servers (Plex/Jellyfin/Emby), and file shares
### Added
- `Install-ServerSoftware.ps1` companion script (Docker Engine, Plex, Jellyfin, Emby, arbitrary winget IDs)
- Project header banner

## [1.0.0] - Win11VM-ServerOptimizer.ps1
### Added
- Initial release: AMP-focused Windows 11 Pro debloat/tuning script (AppX removal, service/feature/scheduled-task disabling, telemetry and power registry tweaks, optional Defender exclusion for AMP instances)
