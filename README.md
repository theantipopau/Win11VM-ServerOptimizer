# Win11 AMP Server Optimizer

**by Matt Hurley** — [matthurley.dev](https://matthurley.dev)

[GitHub Repository](https://github.com/theantipopau/win11-amp-server-optimizer)

**Current version: v1.0.0**

A PowerShell script that strips down a fresh Windows 11 Pro install for use as a **dedicated, headless-leaning game server host** running [AMP (CubeCoders Application Management Panel)](https://cubecoders.com/AMP).

Unlike a general-purpose desktop debloat, this is scoped specifically for VMs whose only job is running AMP and its game server instances — no desktop use, no gaming on the box itself, no Office/word processing.

---

## Why this exists, and why not just use a general debloater

General debloat tools (Win11Debloat, WinUtil, etc.) are built around desktop/gaming-PC use cases. Running them as-is on a server VM risks stripping or disabling things a server role actually needs, and they don't account for AMP-specific concerns (Defender scanning instance folders, no need to preserve GPU/gaming stack, etc.).

This script instead:

- **Explicitly leaves alone**: RDP, networking stack, Windows Firewall service, .NET runtimes, Windows Time service, Windows Update (set to manual, not disabled).
- **Strips aggressively**: consumer AppX bloat (Xbox stack, Widgets, Copilot, Cortana, OneDrive, etc.), telemetry, Search indexing, SysMain/Superfetch, hibernation/Fast Startup, unneeded scheduled tasks and services.
- **Understands AMP**: optional `-AmpInstancesPath` parameter adds a Defender exclusion for your instances folder instead of disabling Defender outright.

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
- **Defender** — optional exclusion for your AMP instances folder (recommended over disabling Defender)
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

# Apply, with a Defender exclusion for your AMP instances folder
.\scripts\Win11VM-ServerOptimizer.ps1 -AmpInstancesPath "C:\AMP\Instances"
```

Reboot once it completes, then install/configure AMP as normal. The script is idempotent, so it's safe to re-run after Windows Updates re-enable something.

### Parameters

| Parameter | Description |
|---|---|
| `-DryRun` | Logs what would change without making changes |
| `-AmpInstancesPath` | Path to your AMP instances folder; adds a Windows Defender exclusion |
| `-DisableDefender` | Fully disables Defender real-time protection (not recommended — prefer the exclusion above) |
| `-LogPath` | Where to write the log file (defaults to Desktop) |

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
