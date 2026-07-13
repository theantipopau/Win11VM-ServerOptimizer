# Changelog

This project has two independently-versioned scripts: `Win11VM-ServerOptimizer.ps1` (strips/configures the OS) and `Install-ServerSoftware.ps1` (opt-in software installer). Each entry below notes which one it applies to.

## [1.2.0] - 2026-07-13 (Win11VM-ServerOptimizer.ps1)
### Added
- Network & background-task tuning phase: `NetworkThrottlingIndex` removed, `SystemResponsiveness` set to 0, Delivery Optimization forced to HTTP-only, Game Bar/GameDVR disabled, NIC power management disabled
- `-Force` switch and a confirmation prompt before any non-dry-run change
### Fixed
- Native command failures (`powercfg`, etc.) are now correctly detected instead of silently logging as `OK`

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
