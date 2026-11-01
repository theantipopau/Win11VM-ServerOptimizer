![Win11VM Server Optimizer](images/header.PNG)

# Win11VM Server Optimizer

**by Matt Hurley** — [matthurley.dev](https://matthurley.dev)

[GitHub Repository](https://github.com/theantipopau/Win11VM-ServerOptimizer)

**Current version: v1.5.0** ([changelog](CHANGELOG.md))

A PowerShell script that strips down a fresh Windows 11 Pro install for use as a **dedicated, headless-leaning server host** — game servers ([AMP](https://cubecoders.com/AMP), standalone Source/Java/Bedrock, etc.), media servers (Plex, Jellyfin, Emby), file shares, or any other always-on service.

Unlike a general-purpose desktop debloat, this is scoped specifically for machines whose only job is running server workloads — no desktop use, no gaming on the box itself, no Office/word processing.

---

## Why this exists, and why not just use a general debloater

General debloat tools (Win11Debloat, WinUtil, etc.) are built around desktop/gaming-PC use cases. Running them as-is on a server VM risks stripping or disabling things a server role actually needs, and they don't account for server-specific concerns (Defender scanning large data folders, no need to preserve GPU/gaming stack, etc.).

This script instead:

- **Explicitly leaves alone**: RDP, networking stack, Windows Firewall service, .NET runtimes, Windows Time service, Windows Update (set to manual, not disabled).
- **Strips aggressively**: consumer AppX bloat (Xbox stack, Widgets, Copilot, Cortana, OneDrive, etc.), telemetry, Search indexing, SysMain/Superfetch, hibernation/Fast Startup, unneeded scheduled tasks and services.
- **Understands server workloads**: optional `-ExclusionPaths` parameter adds Defender exclusions for your AMP instances, Plex/Jellyfin library or transcode folders, or any other data directory — instead of disabling Defender outright.
- **Can be undone**: it records the original state of everything it changes, so `Restore-ServerDefaults.ps1` can put the box back. See [Undoing it](#undoing-it).

---

## What it does

### Removed
- **Consumer AppX bloat** — Xbox app/overlay/identity stack, Cortana, Bing Weather/News/Search, Solitaire, Office Hub/OneNote, OneDrive, People, To Do, Maps, Feedback Hub, Get Help/Get Started, Mixed Reality Portal, Snip & Sketch, Your Phone, Zune Music/Video, Clipchamp, Teams (consumer), Copilot, Sticky Notes, Power Automate Desktop, new Outlook
- **Optional Windows features** — Windows Media Player, XPS Services, Work Folders client, Fax and Scan, WordPad, Steps Recorder
- **Services** — Xbox Live auth/save/networking/accessory services, Downloaded Maps Manager, Geolocation, Windows Search indexing, SysMain (Superfetch), Connected User Experiences and Telemetry, WAP Push routing, Retail Demo, Fax, Phone Service, Remote Registry, Media Player Network Sharing, Windows Mobile Hotspot, Bluetooth services
- **Scheduled tasks** — Compatibility Appraiser, CEIP Consolidator/UsbCeip, Feedback (Siuf), Maps toast/update, Windows Error Reporting queue

### Configured
- **Telemetry & UI** — telemetry policy set to minimum, Cortana/web search integration disabled, Widgets/Chat taskbar icons hidden, Search Highlights disabled, Start menu suggestions and OneDrive sync disabled, post-update welcome/"finish setting up your device" prompts suppressed, Windows Copilot turned off
- **Power** — High Performance power plan, hibernation and Fast Startup disabled, sleep timers disabled (AC & DC)
- **Processor scheduling** — set to **Background services** (`Win32PrioritySeparation = 0x18`), matching the Windows Server default: long, fixed CPU quantums with no boost for whichever window happens to have focus, which is backwards for a box whose real work is in services
- **Power throttling** — Windows throttles background-process CPU (EcoQoS) to save battery; that's exactly the work a server exists to do, so it's turned off (`PowerThrottlingOff`)
- **Reserved storage** — released (~7 GB Windows holds for update servicing), which matters on a fixed-size VM disk
- **Visual effects** — set to Best Performance, transparency disabled (irrelevant over RDP anyway, but it's one less thing burning cycles)
- **Windows Update** — set to Manual (not disabled — security patching still applies on demand)
- **Network & background tasks** — removes the ~10Mbps throttle Windows puts on background network traffic (`NetworkThrottlingIndex`), sets Delivery Optimization to HTTP-only (no peer-to-peer upload/download), disables Game Bar/GameDVR, and stops Windows powering down network adapters so they can't drop off under load (written to each adapter's `MSPower_DeviceEnable` setting and verified afterwards — the `*-NetAdapterPowerManagement` cmdlets don't expose that checkbox)
- **Defender** — optional exclusions for your server data folders (AMP instances, Plex/Jellyfin libraries, etc.), recommended over disabling Defender. These are applied *first*, before the AppX/feature servicing that would otherwise be re-scanned file by file
- **Cleanup** — temp folders cleared on every run

### Deliberately left alone
- Windows Firewall (rules aren't modified — configure per game server as normal)
- Remote Desktop / RDP
- .NET Framework / .NET Desktop Runtime
- Java (if you install it separately for Minecraft etc.)
- Windows Update service (set to Manual, not disabled)
- Windows Defender, unless `-DisableDefender` is explicitly passed
- Windows Error Reporting (`WerSvc`) — handy for diagnosing crashed server processes

---

## Undoing it

A one-way tuning script is a bad deal on a machine you actually care about, so every run that changes something writes a **change record** to `%ProgramData%\Win11VM-ServerOptimizer\state.json`:

- service start types and whether each was running
- optional features and capabilities that were enabled
- scheduled task state
- the previous value — or previous *absence* — of every registry value it touches
- the active power scheme, hibernation, reserved-storage state, and which network adapters had power management disabled

`Restore-ServerDefaults.ps1` reads that record and reverts exactly those things. It restores what *this machine* had before the optimizer first ran, not a generic table of "Windows defaults" — which matters if the box was already tuned when you got it.

```powershell
# See what would be restored
.\scripts\Restore-ServerDefaults.ps1 -DryRun

# Put it back
.\scripts\Restore-ServerDefaults.ps1
```

Or double-click `scripts\Run-Restore-ServerDefaults.bat` (same self-elevation as the other launchers).

| Parameter | Description |
|---|---|
| `-DryRun` | Shows what would be restored without changing anything |
| `-Force` | Skips the confirmation prompt before restoring (for unattended/scripted runs) |
| `-StatePath` | Change record to read (defaults to `%ProgramData%\Win11VM-ServerOptimizer\state.json` — point it elsewhere if you moved the record) |
| `-LogPath` | Where to write the restore log (defaults alongside the optimizer's log) |

What it **cannot** restore:

- **AppX packages** — Windows has no supported "re-add consumer app" operation. The record lists what was removed so you know what to reinstall from the Store.
- **Defender exclusions** — treated as your deliberate intent rather than an unwanted tweak, so they're left in place.

The record is merged across runs: re-running the optimizer after a Windows Update re-enables something does not overwrite the original values it recorded the first time, so a re-run can't "forget" what the box looked like before it was first touched.

---

## Usage

### Option A — double-click (easiest)

`.ps1` files don't run on double-click by default (Windows opens them for editing, and unsigned scripts hit the execution-policy wall), so there's a launcher that handles elevation and the policy bypass for you:

1. Copy the whole `scripts\` folder to the VM.
2. Double-click `Run-Win11VM-ServerOptimizer.bat`.
3. Accept the UAC prompt — it relaunches itself elevated, then runs the optimizer.

Pass flags straight through to the launcher, e.g. `Run-Win11VM-ServerOptimizer.bat -DryRun` (or edit a shortcut's target to add them). Arguments are forwarded verbatim, including ones containing quotes or apostrophes, and the launcher exits with the script's own exit code.

### Option B — PowerShell directly

```powershell
# Always dry-run first
.\scripts\Win11VM-ServerOptimizer.ps1 -DryRun

# Apply, with Defender exclusions for your server data folders
.\scripts\Win11VM-ServerOptimizer.ps1 -ExclusionPaths "C:\AMP\Instances","D:\Plex\Transcode"
```

Reboot once it completes, then install/configure your server software as normal. The script is idempotent, so it's safe to re-run after Windows Updates re-enable something.

**Multiple values via the `.bat` launcher:** PowerShell's `-File` mode (what the launcher uses) doesn't parse comma-separated arrays the way an interactive session does, so `-ExclusionPaths "a","b"` collapses into one value there. Both of these now work identically regardless of how you launch it:
```
-ExclusionPaths "C:\AMP\Instances","D:\Plex\Transcode"     (interactive PowerShell)
-ExclusionPaths "C:\AMP\Instances;D:\Plex\Transcode"        (.bat launcher / -File - semicolons)
```

### Parameters

| Parameter | Description |
|---|---|
| `-DryRun` | Logs what would change without making changes (and without writing a change record) |
| `-Force` | Skips the confirmation prompt before making changes (for unattended/scripted runs) |
| `-ExclusionPaths` | One or more folders (AMP instances, Plex/Jellyfin library or transcode dirs, game server data, etc.) to add as Windows Defender exclusions, applied before any removal work |
| `-DisableDefender` | Fully disables Defender real-time protection (not recommended — prefer `-ExclusionPaths` above) |
| `-KeepSearch` | Leaves Windows Search indexing (WSearch) enabled — needed if clients search this box's shared folders over SMB from File Explorer |
| `-CreateRestorePoint` | Creates a System Restore point before making changes (Windows client editions only; limited to one per 24h by Windows itself) |
| `-StatePath` | Where to write the JSON change record `Restore-ServerDefaults.ps1` reads (defaults to `%ProgramData%\Win11VM-ServerOptimizer\state.json`) |
| `-LogPath` | Where to write the log file (defaults to `%ProgramData%\Win11VM-ServerOptimizer\`; rotated to `.1` at 5 MB) |

Running without `-DryRun` or `-Force` prompts for confirmation before making any changes. Before that prompt, the script checks for already-running server software (Plex, Jellyfin, Emby, Sonarr, Radarr, Prowlarr, Bazarr, Lidarr, Readarr, qBittorrent, SABnzbd, NZBGet, Deluge, Transmission, AMP, Source dedicated servers, Java/Minecraft, SteamCMD) and surfaces it so you know what's live before you continue. If any of it is detected, the temp-file cleanup phase (Phase 11) is skipped entirely, rather than risk touching an active transcode or archive-extraction's temp files — re-run during a maintenance window to clean those up.

The script exits with code `1` if any action failed and `0` otherwise, and every logged line is one of `OK` (actually changed something), `SKIP` (nothing to do — already in the desired state), `ERROR` (failed), or `WARN`/`INFO` (informational) — so "N changes applied" only counts things that were genuinely acted on, not things that were already fine. Where a change can be verified afterwards (Defender exclusions, NIC power management, temp cleanup), it is, and the log says what actually happened rather than what was attempted.

---

## Optional: installing server software

`Install-ServerSoftware.ps1` is a separate, opt-in companion script. The optimizer above only ever removes/configures — it never installs anything — so software installation lives in its own script instead of being bolted on. Running it with no switches does nothing.

Everything installs through [winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/) (built-in, Microsoft-signed) rather than downloading installers from random URLs.

```powershell
# See what would install without installing anything
.\scripts\Install-ServerSoftware.ps1 -DryRun -All

# Pick specific software
.\scripts\Install-ServerSoftware.ps1 -DockerEngine -Jellyfin

# Anything not covered by a named switch - find IDs with `winget search <name>`
.\scripts\Install-ServerSoftware.ps1 -WingetId "Valve.Steam"
```

Or double-click `Run-Install-ServerSoftware.bat` (same self-elevation as the optimizer's launcher), passing flags the same way.

### Parameters

| Parameter | Description |
|---|---|
| `-DryRun` | Logs what would be installed without installing |
| `-Force` | Skips the confirmation prompt before installing anything (for unattended/scripted runs) |
| `-DockerEngine` | Installs **Docker Engine** (headless, service-based) — not Docker Desktop. See below for why. |
| `-Plex` | Installs Plex Media Server |
| `-Jellyfin` | Installs Jellyfin Server |
| `-Emby` | Installs Emby Server |
| `-WingetId` | One or more extra winget package IDs to install as-is (same `.bat`-launcher comma/semicolon note as `-ExclusionPaths` above applies here too) |
| `-All` | Shorthand for `-DockerEngine -Plex -Jellyfin -Emby` |
| `-LogPath` | Where to write the log file (defaults to `%ProgramData%\Win11VM-ServerOptimizer\`; rotated to `.1` at 5 MB) |

Running without `-DryRun` or `-Force` prompts for confirmation before installing anything. `-DockerEngine` needs to be run twice: once to enable the `Containers` feature, then again after a reboot to actually install Docker.

Like the optimizer, this exits `1` if any install failed and `0` otherwise, and "already installed" is reported as `SKIP` rather than counted as a change.

### Why Docker Engine, not Docker Desktop

Docker Desktop is a GUI app with a system-tray presence, its own update cycle, and a license that requires payment for larger commercial use — the opposite of what a headless, stripped-down server wants. `-DockerEngine` instead enables the Windows `Containers` optional feature and installs Docker as a background service (`dockerd`) via the `DockerMsftProvider` PowerShell module — the same method Microsoft's own Windows Server documentation uses. **A restart is required** after the feature is enabled before Docker will run.

**Known limitation:** `DockerMsftProvider` is legacy and only provides **Windows containers**. It is not a route to Linux containers — for those, use WSL2 with Docker Desktop, or (better for a server) run Docker on a Linux host and leave this box for native workloads.

---

## Testing

Two dependency-free suites (no Pester, no modules to install), so they run on any Windows PowerShell.

`tests\Invoke-ScriptTests.ps1` checks the things that are easy to let drift and expensive to get wrong when the scripts only ever run on a real machine:

- every script parses, is ASCII-only (no BOM, so PowerShell 5.1 won't misread it), and carries the `#Requires` statements it needs
- comment-based help exists for every parameter and nothing stale is left behind
- each script's version matches its newest `CHANGELOG.md` entry and the README
- the optimizer and restore script agree on the change-record schema version
- anything that counts errors also exits nonzero
- every `.bat` launcher points at a script that exists and propagates its exit code

`tests\Invoke-StateRecordTests.ps1` covers the undo mechanism, which is the one part where a bug is silent until someone actually needs to restore something. It pulls the real change-record functions out of the optimizer and exercises them against a throwaway file: a fresh record, persisting as soon as a change is recorded, accumulating across re-runs without losing the original values, lookups, corrupt-file handling, and that `-DryRun` never writes a record.

```powershell
.\tests\Invoke-ScriptTests.ps1
.\tests\Invoke-StateRecordTests.ps1
```

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs both suites plus `PSScriptAnalyzer` ([settings](PSScriptAnalyzerSettings.psd1)) on every push and pull request.

What the tests do **not** cover: actual system behaviour. They can't verify that a given Windows build still accepts a feature name or that removing an AppX package succeeds — that still needs a real VM and a `-DryRun` first.

---

## Notes

- `WerSvc` (Windows Error Reporting) is left running by default — it's handy for diagnosing crashed game/media server processes. Add it back into the `$servicesToDisable` array in the script if you don't want it.
- HKCU registry tweaks (Widgets/Chat icon, visual effects, transparency, suggestions) apply to whichever account runs the script. Run it under the same admin account you'll actually be logged in as.
- `AllowTelemetry` is set to the minimum value the policy accepts; Windows 11 Pro clamps this to "Basic" regardless (only Enterprise/Education can go fully to zero) — this is a Windows platform limit, not a bug in the script.
- `-DisableDefender` can silently fail to actually disable real-time protection if Windows Security's Tamper Protection is on (the default in Win11) — the script detects this after the fact and logs a warning telling you to turn off Tamper Protection manually if you really want it off.
- Reserved storage, processor scheduling and power throttling are all reverted by `Restore-ServerDefaults.ps1`, but if you'd rather not have them changed at all, remove the corresponding lines from the script — they're isolated to Phase 6/8/9 for exactly that reason.

---

## Tested on

- Windows 11 Pro 24H2 / 25H2, running as a Proxmox VM guest
- AMP Generic/Universal instances, Minecraft (Java + Bedrock), and Source-engine game servers

---

## License

MIT — see [LICENSE](LICENSE).

## Related

- [windows11nontouchgamingoptimizer](https://github.com/theantipopau/windows11nontouchgamingoptimizer) — gaming performance optimizer for non-touch desktops/laptops
- [windows11touchoptimizer](https://github.com/theantipopau/windows11touchoptimizer) — optimizer for low-power touchscreen devices (Surface Go, tablets, 2-in-1s)

## Disclaimer

**Use at your own risk.** This script modifies system-level settings and the registry. Always dry-run first and take a VM snapshot before applying changes. `Restore-ServerDefaults.ps1` can undo recorded changes, but a snapshot is still the only thing that covers a box that won't boot. Not affiliated with Microsoft or CubeCoders.
