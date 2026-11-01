# Throwaway-VM round-trip test

`Invoke-RoundTripTest.ps1` applies the optimizer to a machine, then proves that
`Restore-ServerDefaults.ps1` puts it back. It exists because the unit tests can only check the
scripts' structure — they cannot tell you whether a given Windows build still accepts a feature
name, whether `Remove-AppxPackage` succeeded, or whether the change record really describes what
happened.

**Run it only on a machine you are willing to destroy.** It is the optimizer plus a full restore,
including AppX removal, which Windows has no supported way to undo.

---

## What a passing run proves

- A dry run changes nothing, writes no change record, and never logs `OK`.
- Every item in the change record really is in its new state afterwards (or is named in an
  `[ERROR]` line explaining why the OS refused).
- The record's "before" values match the baseline the harness took before anything ran — a setting
  recorded backwards would otherwise be "restored" to the wrong state and still look like a pass.
- Re-running the optimizer immediately afterwards does *less* work and leaves the original values
  in the record untouched — the "re-run after Windows Update" case.
- A restore dry run changes nothing.
- A real restore returns service start types, optional features, capabilities, scheduled tasks,
  registry values, the power scheme, hibernation, reserved storage and NIC power management to
  their pre-optimizer state.

## What it does not prove

- Anything about a different Windows build, edition, or language.
- That the box is a good server. It checks configuration, not throughput.
- That every AppX package can be restored — none of them can, by design.
- Behaviour after a reboot. Feature re-enables that land in `EnablePending` are normalised and
  reported as restored; only a reboot proves they settle.

---

## Getting a throwaway Windows 11

### Option A — Windows Sandbox (fastest, no ISO)

Windows Sandbox is a disposable copy of your own Windows image. It is the least work and the least
Windows-like (no reboot, System Restore unavailable), which makes it a good first pass.

```powershell
# One-time, in an elevated prompt. Requires virtualization enabled in firmware and ~4 GB RAM.
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
# Reboot when prompted.
```

Then, from the repository:

```powershell
.\tests\vm\New-SandboxConfig.ps1
```

That writes a `.wsb` file (and a results folder) under `artifacts\sandbox\`. Double-click the
`.wsb`, and the round-trip runs automatically inside the sandbox. Results land back in the mapped
repository folder, so you can read `report.md` on the host when the sandbox closes.

### Option B — A real Hyper-V VM

Closest to the intended target (a full Windows 11 Pro install you can reboot and checkpoint).

1. Enable Hyper-V (`Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All`,
   reboot).
2. Create a Generation 2 VM with a Windows 11 Pro ISO. 2 vCPU / 4 GB RAM is enough; give it
   internet access for the optional-feature and AppX operations.
3. Finish OOBE, sign in, and take a **checkpoint** before running anything.
4. Copy the repository into the VM (or run `Invoke-RoundTripTest.ps1` from a shared folder).
5. In an elevated PowerShell inside the VM:

   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\tests\vm\Invoke-RoundTripTest.ps1 -IAmInAThrowawayMachine
   ```

   It exercises the optimizer's default `GameServer` profile. Pass `-Profile MediaServer` or
   `-Profile FileShare` to cover another one, on a fresh machine each time - a profile is verified
   against the record it wrote, and the record refuses to start from a machine that already has one.

6. Revert to the checkpoint before each subsequent run.

The launcher `Run-RoundTripTest.bat` does the same thing with self-elevation, for a double-click.

### Option C — Any other hypervisor

Proxmox, VMware, VirtualBox, a cloud VM: the in-guest command is identical. Snapshot first, and
remember that the harness deliberately removes AppX packages, so "revert snapshot" is the cleanup.

---

## Reading the result

Everything lands in `artifacts\roundtrip-<timestamp>\` (or whatever you pass as `-OutputDir`):

| File | What it is |
|---|---|
| `report.md` | Human-readable summary: every check, every snapshot difference, and the limitations the run hit |
| `results.json` | The same checks, machine-readable |
| `snapshot-baseline.json`, `snapshot-after-dryrun.json`, `snapshot-after-apply.json`, `snapshot-after-restore.json` | Raw before/after state, for when a diff needs explaining |
| `optimizer-dryrun.log`, `optimizer-run1.log`, `optimizer-run2.log`, `restore-dryrun.log`, `restore-run1.log` | The scripts' own logs |
| `*.output.txt` | Captured console output of each run (catches stack traces the log file wouldn't contain) |

`PASS`/`FAIL`/`WARN`/`INFO` behave as you would expect. **The run only passes with zero `FAIL`s.**

### Warnings you should expect, and why

- **AppX packages were not restored (expected).** Windows cannot re-add consumer apps. The restore
  script reports them; the harness records them as a limitation, not a failure.
- **`An action failed` / exit code 1.** The optimizer's contract is to exit `1` when any action
  fails. On a locked-down image that is correct behaviour — e.g. Tamper Protection blocking an AV
  change, or a policy-protected AppX. The harness lists the failing lines. If a *pass* exits `1`
  for an action that should have worked, that is a bug.
- **Some services are not in their original running state.** Start types are restored and asserted;
  a service that cannot start in the VM (no dependent hardware, for example) is reported as a warning.
- **Feature/capability pending states.** `EnablePending` is treated as `Enabled`. That is how Windows
  reports a re-enable that needs a reboot, and Windows Sandbox cannot reboot.

---

## Guardrails

- `-IAmInAThrowawayMachine` is required. Without it the harness refuses to run and explains why.
- It requires an elevated session, matching the optimizer.
- It warns if the machine's model does not look like a VM (best effort — not a hard block).
- It never passes `-DisableDefender`, and only passes `-CreateRestorePoint` if you ask.
- It creates one Defender exclusion for a scratch folder to exercise Phase 0, asserts the restore
  script leaves it alone (documented behaviour), then removes it.
- It refuses to run if a change record already exists at its output path — start from a clean
  machine so "the originals were preserved" means something.

## Self-test

The harness can check itself without changing anything, and without admin:

```powershell
.\tests\vm\Invoke-RoundTripTest.ps1 -SelfTest
```

It pulls the service/feature/task/AppX/registry catalogs out of the optimizer's AST (so the test
follows the script rather than a copy of its lists), then exercises the snapshot comparison, error
matching and crash detection against synthetic data. Run this after changing the optimizer: if a
catalog can no longer be extracted, the self-test fails loudly instead of the VM run silently
checking nothing.

## When something fails

1. Read `report.md` first — the failing check names the exact before/after value.
2. Open the matching log: a `FAIL` on "recorded changes match the live machine" means the script
   recorded a change it did not make; a `FAIL` on "machine matches the baseline again" means the
   restore script missed something. Those are the two that matter.
3. Keep the whole `artifacts\roundtrip-*` folder — it is the reproduction.
