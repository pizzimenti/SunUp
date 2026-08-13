# SunUp

**Your Windows box, updated by the time you sit down.** SunUp is a self-contained, unattended
update routine for Windows — one scheduled run each morning that patches *everything safe to patch*
and shows you a clean summary of what changed. It exists because Windows Update's built-in scheduling
is unreliable: it drifts, defers, and reboots on its own clock instead of yours.

The name: it runs at **dawn (~08:00)** so you start the day with fresh updates — and it keeps the
*"up"* of Update. (Renamed from `AutoUpdate` in v0.5.0.)

![SunUp summary dialog](docs/sample-dialog.png)

The dialog shows the current run in full color and the **past 30 days** of updates greyed out beneath
it, so you can see at a glance what's been changing.

## What it updates

All toggleable in `config.json`, run in one coordinated pass:

| Component | What | Notes |
|---|---|---|
| **Defender** | Antivirus signature definitions | Duration captured per run |
| **Windows + Microsoft Update** | OS + Office/other MS products | via PSWindowsUpdate; can exclude by title (e.g. pinned `NVIDIA` drivers) |
| **winget** | Desktop app upgrades | per-package, capturing old→new version, duration, and download size; plus a per-user pass for the HKCU packages SYSTEM cannot see |
| **PowerShell modules** | PSGallery modules | weekly (`psModules.everyDays`), not daily |

`pip` / `npm` stubs are present but off by default.

Nothing here is vendor- or hardware-specific — every component ships with Windows or with winget, so
SunUp runs on any Windows box. (v0.14.0 removed the Dell Command Update integration; see the
CHANGELOG for the evidence behind that.)

## How it's scheduled

One SYSTEM scheduled task (`SunUp`) with three triggers, de-duplicated to **once per calendar day**
by a `lastrun.json` stamp (whichever fires first does the work; the rest no-op):

- **Daily 08:00** — only if the box is awake (the trigger never wakes it).
- **Boot + 1h** — catches a day missed while powered off.
- **Resume + 1h** — catches a day missed while asleep (Power-Troubleshooter event).

A missed 08:00 is picked up ~1h after the next boot/resume, so updates never ambush you the moment
you sit down.

## The summary dialog

After every cycle (even when nothing needed updating), an interactive task (`SunUp-Notify`) shows the
Win11-styled dialog above in your desktop session. It lists the current run's updates in normal color
and the past `notify.historyDays` (default **30**) greyed out below, with a **When** column. By default
the history is collapsed to the latest occurrence per package (`notify.historyCollapse`) so daily
Defender-signature bumps don't flood it.

### Reboots, on your terms

If — and only if — an update leaves a reboot **pending**, the dialog owns a cancellable countdown
(**Restart now** / **Postpone**). A reboot that isn't actually needed never prompts you. If no one is
logged in, the engine reboots headlessly after a grace period and shows the summary at next sign-in.

The default `rebootPolicy: "ifRequired"` reboots only when a component **this run** actually reported
a reboot as required. Set `"always"` to reboot on any confirmed pending state, or `"never"` to never
auto-reboot.

### How "pending" is decided

`RebootState.ps1` is the single detector, shared by the engine and the tray so the icon and the
restart decision can never disagree. It **classifies** signals rather than counting them, and
reports *why*, which `-Mode Status` and the run log both print:

- **Authoritative** — Component Based Servicing (`RebootPending`, `RebootInProgress`,
  `PackagesPending`), Windows Update's `RebootRequired`, a queued machine rename, a staged domain join.
- **Run signals** — an MSI `3010` or a winget restart exit code from this run. These set *no* OS flag
  anywhere, so a registry-only check reports "no restart needed" on a box that plainly needs one.
- **Classified** — `PendingFileRenameOperations` is a work queue for `smss.exe`, not a reboot signal.
  A rename *into* a destination counts; a delete-on-boot of a file under a temp directory does not,
  because that is an application cleaning up after itself. Anything unrecognised counts (fails open).

That last rule matters more than it sounds. Any Node/Electron app that unpacks a native `.node`
addon to `%TEMP%` registers a delete-on-boot for it, often minutes into *every* startup — so the
naive "is `PendingFileRenameOperations` non-empty?" check that every reboot-detection snippet on the
internet uses reports a permanent pending reboot on an ordinary developer machine.

## System tray

Windows has no service-manager UI for a scheduled task, so SunUp adds a **tray presence**, launched
at logon. The icon is a **full sun** normally and a **setting sun** when a restart is needed — a
difference in shape rather than shade, so it survives the 16px the notification area renders at.
Right-click for:

<img src="docs/tray-menu.png" alt="SunUp tray menu" width="280">

- **Run now** — trigger an update pass immediately
- **Show last summary** — re-open the most recent dialog
- **Open logs folder**
- **Auto-reboot when needed** — toggle `rebootPolicy` (checkmark reflects current state)
- **Exit**

The tooltip shows the last run and, when a restart is outstanding, **what is asking for it**
("Restart needed — Windows Update"). A balloon pops when a run completes.

## Logging

Three tiers, so failures are trivial to find, under `C:\ProgramData\SunUp\`:

- `logs\sunup.log` — curated rolling timeline (rotated at 5 MB × 5).
- `logs\history.jsonl` — one compact JSON line per run (queryable trail; also the source for the
  dialog's 30-day history).
- `logs\runs\<timestamp>\` — isolated per-run dir (kept for the last `keepRuns`, default 30) holding
  `run.log`, a full `transcript.log`, the **raw output of every tool** in its own file, and a
  structured `result.json`.

A run that is killed mid-flight never writes `result.json`, and every other alert path runs after the
updates — so the **next** run detects the orphaned dir, reports it once (event 2011 + a SysSentry
alert naming the last line it logged) and marks it with `incomplete.json`. A run still in progress
looks the same from outside, so each run drops a `running.json` liveness marker (PID + process start
time) while it works: a concurrent manual `-Force` run is recognised as alive and left alone.

The two detached passes (`SunUp-User`, `SunUp-SelfHost`) finish after the engine has exited, so they
write their own records into that run's dir — `user-winget.json`, `selfhost.json`,
`user-selfhost.json` — and the **next** run folds them into its `updates[]`, dialog, history and
reboot decision, exactly once (marked `ingested`).

Plus a `REPORT.md` digest and the Application event log (source `SunUp`: 2000 start, 2001 clean,
2002 completed with warnings, 2005 reboot, 2006 stale-reboot-pending, 2010 errors, 2011 previous run
killed mid-run, 2020/2021 self-host handoff, 2030/2031 user-scope pass).

## Install / uninstall

```powershell
# from an elevated PowerShell, in the repo dir:
pwsh -File .\Install.ps1      # deploys to C:\ProgramData\SunUp, registers the tasks
pwsh -File .\Uninstall.ps1    # removes the tasks (add -Purge to also delete data + event source)
```

`Install.ps1` is idempotent and also **migrates a previous `AutoUpdate` install** in place (moves its
data/logs/history/config to the SunUp name, swaps the tasks and event source) without losing history.

## Manage / diagnose

```powershell
pwsh -File C:\ProgramData\SunUp\bin\Status.ps1               # task state, last run, per-component status
pwsh -File C:\ProgramData\SunUp\bin\SunUp.ps1 -Mode Errors   # last failed runs + error text + log tails
pwsh -File C:\ProgramData\SunUp\bin\SunUp.ps1 -Mode Tail     # tail of the most recent run
pwsh -File C:\ProgramData\SunUp\bin\SunUp.ps1 -Mode Run -Force   # run now, bypassing the day stamp
```

> Heads-up: a forced run **will reboot** if an update this run installs requires it (`rebootPolicy`
> `ifRequired`, the default), or if any reboot is pending under `rebootPolicy: "always"`. To test
> safely, set `rebootPolicy: "never"` first.

## Configuration

`C:\ProgramData\SunUp\config.json` (reloaded each run; keys missing from an older file are merged from
defaults):

| Key | Default | Meaning |
|---|---|---|
| `rebootPolicy` | `"ifRequired"` | `ifRequired` reboots only when a component this run required it; `always` reboots on any *confirmed* pending state (see [How "pending" is decided](#how-pending-is-decided)); `never` never does |
| `rebootDelaySeconds` | `120` | headless restart grace |
| `rebootGraceInteractiveSec` | `300` | countdown the dialog shows when a user is logged in |
| `pendingRebootAlertDays` | `3` | under `ifRequired`, alert once if a reboot stays pending this many days without a run requiring it (`0` disables). The timer restarts whenever the box boots |
| `keepRuns` | `30` | per-run log dirs to retain |
| `notify.historyDays` | `30` | days of past updates shown (greyed) in the dialog |
| `notify.historyCollapse` | `true` | keep only the latest occurrence per package in the history |
| `notify.historyMaxRows` | `500` | cap on history rows |
| `vendorUpdates` | `"allow"` | `block` keeps **this machine's OEM** from pushing driver/firmware/utility updates, on both delivering paths (Windows Update titles + winget ids). The OEM is detected at run time, so the same setting blocks Dell on a Dell and Lenovo on a Lenovo — see `VendorProfiles.ps1`. A block that can't be enforced (unrecognized OEM) is logged, never silent |
| `windowsUpdate.notTitle` | `"NVIDIA"` | skip updates whose title matches (preserves pinned drivers) |
| `winget.excludePattern` | (regex) | skip pinned/self-updating apps — applied to **both** the machine and user passes |
| `winget.userScope` | `true` | also upgrade per-user (HKCU) packages via `SunUp-User` (see below) |
| `winget.selfHostPattern` | `Microsoft\.PowerShell\|Microsoft\.DesktopAppInstaller` | packages that host the engine's own process. The engine does **not** upgrade these — it hands them to `SelfHost.ps1` (see below) |
| `winget.selfHostInstallerArgs` | `MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress` | **unused since v0.12.0**, retained so existing configs load. Passing this via `--custom` did not stop Restart Manager (measured 2026-07-28) |
| `psModules.everyDays` | `7` | run PowerShell-module updates at most this often |

### Per-user packages (`SunUp-User`)

winget resolves installed packages **per user**. The engine runs as SYSTEM, so anything registered
under **HKCU is invisible to it** — not skipped, simply absent from `winget upgrade`. On this box
the two lists were disjoint, and six user-scope tools (Deno, yt-dlp FFmpeg, fzf, ripgrep, Rufus,
Sysinternals) matched nothing in `excludePattern` — they had never been updated by SunUp at all.

`UserScope.ps1` runs as the interactive user via the **`SunUp-User`** task (same principal as the
notify and tray tasks), started by the engine at the end of a run. It **shares the engine's
`excludePattern` and `selfHostPattern`**, so there is one policy in one place: apps excluded
because they self-update (Claude, Spotify, Discord, Slack, Teams, LM Studio) stay excluded.

- Requires a logged-on user; a headless run defers to the next run that has a session. Skipped too
  when the run is going to reboot — the pass outlives a 300 s countdown, and restarting on top of a
  live `winget upgrade` leaves a package half-installed.
- Self-hosting packages found **here** cannot go to the SYSTEM handoff — they are HKCU-registered,
  which is exactly what SYSTEM cannot see. The pass launches `SelfHost.ps1` itself (Windows
  PowerShell 5.1, as this user, after the pass exits) and records them in `user-selfhost.json`.
- Results in `user-winget.log` / `user-winget.json` in the run dir; events 2030/2031.
- Never reboots — the engine owns that decision, and acts on a reboot recorded here at the next run.
- **Limitation:** the dialog payload is written before this runs, so packages upgraded here appear
  in the next run's dialog and history rather than that run's dialog.

Set `winget.userScope: false` to turn the pass off.

### Upgrading PowerShell itself

The engine runs under `pwsh`. Upgrading `Microsoft.PowerShell` makes Windows Installer's Restart
Manager shut down every process holding files in the install target — including the engine asking
for the install. Three runs died this way before it was diagnosed, each leaving no `result.json`,
no reboot decision and no day stamp; because the stamp is written at the *end* of a run, the next
trigger simply re-ran and re-died. It presented as "updates aren't running".

Trying to disable Restart Manager from inside the engine (`MSIRESTARTMANAGERCONTROL=Disable` via
winget's `--custom`) **did not work** — RM ran anyway. So the engine no longer tries to survive it:

- `Comp-Winget` splits out packages matching `winget.selfHostPattern` and upgrades everything else.
- As its last act, the engine registers and starts the one-shot **`SunUp-SelfHost`** task, which
  runs `SelfHost.ps1` under **Windows PowerShell 5.1** — a separate installation RM cannot reach.
- The helper waits for the engine's PID to exit — and for the `SunUp-User` task to go idle, since
  that pass runs under pwsh 7 and would otherwise be killed mid-upgrade — then upgrades. The run is
  already complete, so a kill costs nothing. Results land in `selfhost.log` / `selfhost.json` in the
  run dir, and the **next run folds them into its own `updates[]`, dialog, history and reboot
  decision**. The task self-deletes.
- A *headless* reboot skips the handoff (it would race the shutdown). An interactive countdown is
  cancellable, so the helper is started anyway and sits it out first: postponing no longer costs a
  day for a reboot that never happened.
- The engine confirms the task actually entered `Running` before reporting a handoff —
  `Start-ScheduledTask` returns success without running anything when an `IgnoreNew` instance is
  already active.

**Your open `pwsh` terminals will still be killed** when PowerShell 7 upgrades. That is Restart
Manager; nothing short of a reboot-time install avoids it.

## Requirements

- Windows 10/11, PowerShell 7 (`pwsh`).
- [PSWindowsUpdate](https://www.powershellgallery.com/packages/PSWindowsUpdate) (installed by `Install.ps1`).

## License

MIT
