![Win11VM Server Optimizer](images/header.PNG)

# Win11VM Server Optimizer

**by Matt Hurley** — [matthurley.dev](https://matthurley.dev)

[GitHub Repository](https://github.com/theantipopau/Win11VM-ServerOptimizer)

**Current version: v1.2.0** ([changelog](CHANGELOG.md))

A PowerShell script that strips down a fresh Windows 11 Pro install for use as a **dedicated, headless-leaning server host** — game servers ([AMP](https://cubecoders.com/AMP), standalone Source/Java/Bedrock, etc.), media servers (Plex, Jellyfin, Emby), file shares, or any other always-on service.

Unlike a general-purpose desktop debloat, this is scoped specifically for machines whose only job is running server workloads — no desktop use, no gaming on the box itself, no Office/word processing.

---

## Why this exists, and why not just use a general debloater

General debloat tools (Win11Debloat, WinUtil, etc.) are built around desktop/gaming-PC use cases. Running them as-is on a server VM risks stripping or disabling things a server role actually needs, and they don't account for server-specific concerns (Defender scanning large data folders, no need to preserve GPU/gaming stack, etc.).

This script instead:

- **Explicitly leaves alone**: RDP, networking stack, Windows Firewall service, .NET runtimes, Windows Time service, Windows Update (set to manual, not disabled).
- **Strips aggressively**: consumer AppX bloat (Xbox stack, Widgets, Copilot, Cortana, OneDrive, etc.), telemetry, Search indexing, SysMain/Superfetch, hibernation/Fast Startup, unneeded scheduled tasks and services.
- **Understands server workloads**: optional `-ExclusionPaths` parameter adds Defender exclusions for your AMP instances, Plex/Jellyfin library or transcode folders, or any other data directory — instead of disabling Defender outright.

---

## What it does

### Removed
- **Consumer AppX bloat** — Xbox app/overlay/identity stack, Cortana, Bing Weather/News/Search, Solitaire, Office Hub/OneNote, OneDrive, People, To Do, Maps, Feedback Hub, Get Help/Get Started, Mixed Reality Portal, Snip & Sketch, Your Phone, Zune Music/Video, Clipchamp, Teams (consumer), Copilot, Sticky Notes, Power Automate Desktop, new Outlook
- **Optional Windows features** — Windows Media Player, XPS Services, Work Folders client, Fax and Scan, WordPad, Steps Recorder
- **Services** — Xbox Live auth/save/networking/accessory services, Downloaded Maps Manager, Geolocation, Windows Search indexing, SysMain (Superfetch), Connected User Experiences and Telemetry, WAP Push routing, Retail Demo, Fax, Phone Service, Bluetooth services
- **Scheduled tasks** — Compatibility Appraiser, CEIP Consolidator/UsbCeip, Feedback (Siuf), Maps toast/update, Windows Error Reporting queue

### Configured
- **Telemetry & UI** — telemetry policy set to minimum, Cortana/web search integration disabled, Widgets/Chat taskbar icons hidden, Start menu suggestions and OneDrive sync disabled, Windows Copilot turned off
- **Power** — High Performance power plan, hibernation and Fast Startup disabled, sleep timers disabled (AC & DC)
- **Visual effects** — set to Best Performance, transparency disabled (irrelevant over RDP anyway, but it's one less thing burning cycles)
- **Windows Update** — set to Manual (not disabled — security patching still applies on demand)
- **Network & background tasks** — removes the ~10Mbps throttle Windows puts on background network traffic (`NetworkThrottlingIndex`), stops reserving CPU for foreground multimedia that doesn't exist on a headless box (`SystemResponsiveness`), sets Delivery Optimization to HTTP-only (no peer-to-peer upload/download), disables Game Bar/GameDVR, and disables NIC power management so adapters can't be put to sleep under load
- **Defender** — optional exclusions for your server data folders (AMP instances, Plex/Jellyfin libraries, etc.), recommended over disabling Defender
- **Cleanup** — temp folders cleared on every run

### Deliberately left alone
- Windows Firewall (rules aren't modified — configure per game server as normal)
- Remote Desktop / RDP
- .NET Framework / .NET Desktop Runtime
- Java (if you install it separately for Minecraft etc.)
- Windows Update service (set to Manual, not disabled)
- Windows Defender, unless `-DisableDefender` is explicitly passed

---

## Usage

### Option A — double-click (easiest)

`.ps1` files don't run on double-click by default (Windows opens them for editing, and unsigned scripts hit the execution-policy wall), so there's a launcher that handles elevation and the policy bypass for you:

1. Copy the whole `scripts\` folder to the VM.
2. Double-click `Run-Win11VM-ServerOptimizer.bat`.
3. Accept the UAC prompt — it relaunches itself elevated, then runs the optimizer.

Pass flags straight through to the launcher, e.g. `Run-Win11VM-ServerOptimizer.bat -DryRun` (or edit a shortcut's target to add them).

### Option B — PowerShell directly

```powershell
# Always dry-run first
.\scripts\Win11VM-ServerOptimizer.ps1 -DryRun

# Apply, with Defender exclusions for your server data folders
.\scripts\Win11VM-ServerOptimizer.ps1 -ExclusionPaths "C:\AMP\Instances","D:\Plex\Transcode"
```

Reboot once it completes, then install/configure your server software as normal. The script is idempotent, so it's safe to re-run after Windows Updates re-enable something.

### Parameters

| Parameter | Description |
|---|---|
| `-DryRun` | Logs what would change without making changes |
| `-Force` | Skips the confirmation prompt before making changes (for unattended/scripted runs) |
| `-ExclusionPaths` | One or more folders (AMP instances, Plex/Jellyfin library or transcode dirs, game server data, etc.) to add as Windows Defender exclusions |
| `-DisableDefender` | Fully disables Defender real-time protection (not recommended — prefer `-ExclusionPaths` above) |
| `-LogPath` | Where to write the log file (defaults to Desktop) |

Running without `-DryRun` or `-Force` prompts for confirmation before making any changes.

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
| `-WingetId` | One or more extra winget package IDs to install as-is |
| `-All` | Shorthand for `-DockerEngine -Plex -Jellyfin -Emby` |
| `-LogPath` | Where to write the log file (defaults to Desktop) |

Running without `-DryRun` or `-Force` prompts for confirmation before installing anything. `-DockerEngine` needs to be run twice: once to enable the `Containers` feature, then again after a reboot to actually install Docker.

### Why Docker Engine, not Docker Desktop

Docker Desktop is a GUI app with a system-tray presence, its own update cycle, and a license that requires payment for larger commercial use — the opposite of what a headless, stripped-down server wants. `-DockerEngine` instead enables the Windows `Containers` optional feature and installs Docker as a background service (`dockerd`) via the `DockerMsftProvider` PowerShell module — the same method Microsoft's own Windows Server documentation uses. **A restart is required** after the feature is enabled before Docker will run.

---

## Notes

- `WerSvc` (Windows Error Reporting) is left running by default — it's handy for diagnosing crashed game server processes. Comment it out of the `$servicesToDisable` array in the script if you don't want it.
- HKCU registry tweaks (Widgets/Chat icon, visual effects, transparency) apply to whichever account runs the script. Run it under the same admin account you'll actually be logged in as.
- `AllowTelemetry` is set to the minimum value the policy accepts; Windows 11 Pro clamps this to "Basic" regardless (only Enterprise/Education can go fully to zero) — this is a Windows platform limit, not a bug in the script.

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

**Use at your own risk.** This script modifies system-level settings and the registry. Always dry-run first and take a VM snapshot before applying changes. Not affiliated with Microsoft or CubeCoders.
