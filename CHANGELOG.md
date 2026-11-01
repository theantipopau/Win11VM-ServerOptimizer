# Changelog

This project has three independently-versioned scripts: `Win11VM-ServerOptimizer.ps1` (strips/configures the OS), `Install-ServerSoftware.ps1` (opt-in software installer), and `Restore-ServerDefaults.ps1` (undoes the optimizer from its change record). Each entry below notes which one it applies to.

## [1.5.0] - 2026-11-01 (Win11VM-ServerOptimizer.ps1)
A script that can only ever go one direction is a bad deal on a machine you actually care about, so this release makes the changes reversible - and finishes the "verify, don't assume" work 1.4.0 started.
### Added
- **Change record** (`state.json`, written under `%ProgramData%\Win11VM-ServerOptimizer\`): before touching anything reversible, the script records the original state - service start types and running state, enabled optional features and capabilities, scheduled task state, the previous value (or previous absence) of every registry value it writes, the active power scheme, hibernation, and reserved-storage state. Records merge across runs, so a re-run after Windows Update re-enables something cannot overwrite the original values captured on the first run.
- **`Restore-ServerDefaults.ps1`** (new script, v1.0.0) - reads that record and reverts exactly what was recorded, rather than applying a generic "Windows defaults" table that may never have been what this machine had. Ships with its own double-click launcher, and reports the AppX packages it cannot restore.
- `-StatePath` on the optimizer to control where the record is written.
- **Processor scheduling set to Background services** (`Win32PrioritySeparation = 0x18`) - long, fixed CPU quantums with no foreground boost, matching the Windows Server default. The client default (2) resolves to short, variable quantums with a boost for whichever window has focus, which is backwards for a box whose work is in services nobody is looking at.
- **Power throttling disabled** (`PowerThrottlingOff`) - Windows throttles background-process CPU (EcoQoS) to save battery; on a server the background process is the workload.
- **Reserved storage released** via DISM (~7 GB held for update servicing), which matters on a fixed-size VM disk.
- Services: `RemoteRegistry`, `WMPNetworkSvc` (moot once Media Player is removed), `icssvc` (Windows Mobile Hotspot).
- Registry: Search Highlights off, "tips/tricks/suggestions" and post-update welcome + "finish setting up your device" prompts off.
- Log rotation: the log is moved to `<log>.1` once it passes 5 MB, instead of appending forever on a box that gets re-run after every Windows Update.
- **Tests and CI** - `tests\Invoke-ScriptTests.ps1` (contract checks: parsing, help/parameter parity, version consistency against the README and CHANGELOG, shared schema version, exit-code contract, launcher wiring) and `tests\Invoke-StateRecordTests.ps1` (exercises the real change-record functions against a temp file, including re-run merging, corrupt-file handling and dry-run behaviour). Both are dependency-free, so no Pester or module install is needed. `.github/workflows/ci.yml` runs them plus `PSScriptAnalyzer` on every push and pull request.
- `#Requires -Version 5.1` on every script (they were always 5.1-era code; now it says so).
### Fixed
- **NIC power management never worked at all.** The old call was `Set-NetAdapterPowerManagement -AllowComputerToTurnOffDevice Disabled`, but that cmdlet has no such parameter (it only handles wake/offload flags), so it threw on every run - and `-ErrorAction SilentlyContinue` plus an unconditional `OK` in `Invoke-Action` hid it. The "allow the computer to turn off this device" setting actually lives on the device's `MSPower_DeviceEnable` WMI instance, matched to each adapter by its PnP device id; that is what the script now writes, and it re-queries afterwards to confirm the setting took, reporting `SKIP`/`WARN` honestly when firmware or a vendor driver refuses.
- **Temp cleanup logged `OK` even when every file was locked** - it now counts before and after and reports what was actually removed (locked files are normal, and no longer indistinguishable from a successful clean).
- **Registry tweaks counted as a change even when the value already matched** - every write re-set the value and logged `OK`, so a re-run reported a full set of "changes" that changed nothing. Values are now compared first and reported as `SKIP` when already correct, which is what the README always claimed the `OK`/`SKIP` levels meant.
- **Defender exclusions ran last and were never verified** - they now run first (Phase 0), before the AppX/feature servicing that would otherwise be re-scanned file by file, and the script re-reads the exclusion list afterwards to catch Tamper Protection silently dropping them.
- **Power plan, hibernation and sleep reported changes unconditionally** - each now checks the current state first (`powercfg /getactivescheme`, `HibernateEnabled`, the AC/DC standby indexes) and reports `SKIP` when already set.
### Changed
- `.bat` launchers now exit with the PowerShell script's own exit code (previously the trailing `pause` always returned 0, so automation saw success no matter what happened) and forward arguments containing apostrophes without breaking the elevation command. Elevation failures are reported as failures instead of exiting silently.
- `-ExclusionPaths` is applied in Phase 0 rather than Phase 9; phase numbers shift accordingly (cleanup is now Phase 11).

## [1.3.0] - 2026-11-01 (Install-ServerSoftware.ps1)
### Fixed
- **The installer never exited nonzero.** It incremented no error counter and always returned 0, so a failed Plex/Jellyfin/Emby install looked identical to a clean run to any wrapper or scheduled task - while the optimizer it ships beside had reported failures correctly since 1.4.0. It now counts failures, includes them in the summary, and exits 1 if any install failed.
- **"Already installed" detection trusted `winget list`'s exit code alone**, which some winget versions report as success even with no matching package (`No installed package found`). It now confirms the package id actually appears in the output before skipping.
### Added
- Log rotation at 5 MB, matching the optimizer.
- Explicit warning that `DockerMsftProvider` is legacy and provides Windows containers only - it is not a route to Linux containers.
- `#Requires -Version 5.1`.

## [1.0.0] - 2026-11-01 (Restore-ServerDefaults.ps1)
### Added
- Initial release: reverts the optimizer's recorded changes - registry values (restored to their previous value, or removed if they did not exist before), optional features and capabilities, scheduled tasks, service start types and running state, power scheme, hibernation, reserved storage, and network adapter power management. Supports `-DryRun`, `-Force`, `-StatePath` (must match the optimizer's record) and `-LogPath`; exits 1 if any action failed.
- Reports AppX packages that were removed and cannot be reinstalled by script, and deliberately leaves Defender exclusions in place.

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
