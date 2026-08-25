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
| **Hygiene** *(read-only)* | Duplicate winget Ids, dead/duplicated PATH entries, uninstall targets that no longer exist, free space | Reports only — never changes anything. Runs last, so it audits the state the run just produced. Findings are `warn`, never `error` |

`pip` / `npm` stubs are present but off by default.

The hygiene component is the one thing here that doesn't update anything. It's included because the
rot it looks for is what makes updates fail *quietly*: a stale `UninstallString` is exactly why
winget installed Python **side-by-side** on this box instead of upgrading in place — and reported
success doing it. See the v0.21.0 CHANGELOG entry for the full post-mortem. It's runnable on its own
too: `pwsh -File C:\ProgramData\SunUp\bin\Hygiene.ps1` (exit 0 clean, 1 findings).

Nothing here is vendor- or hardware-specific — every component ships with Windows or with winget, so
SunUp runs on any Windows box. (v0.14.0 removed the Dell Command Update integration; see the
CHANGELOG for the evidence behind that.)

### Who installs Windows updates — and why Windows goes quiet

SunUp installs Windows updates itself, so `Install.ps1` sets a policy telling Windows Update to
**download but not install**. Four values, under
`HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`:

| Value | | Why |
|---|---|---|
| `AU\NoAutoUpdate` | `0` | Windows Update stays **on** and keeps delivering everything |
| `AU\AUOptions` | `3` | download, but don't install — SunUp owns install timing |
| `SetUpdateNotificationLevel` | `1` | enables the notification policy below |
| `UpdateNotificationLevel` | `1` | stop "updates are available" nagging, **keep restart warnings** |

**Why SunUp takes the install step at all.** Not for scheduling — that argument is handled in code by
the pre-flight skip described [below](#if-a-restart-is-already-pending-sunup-doesnt-install-on-top-of-it).
It's for **selectivity**. `windowsUpdate.notTitle` lets you say *"everything except NVIDIA"*, and
Windows Update has no per-title exclusion mechanism at all — the nearest thing,
`ExcludeWUDriversInQualityUpdate`, is all-or-nothing on drivers. Let Windows install on its own
schedule and every pin you've set is silently bypassed.

**Why the notification half is needed.** `AUOptions=3` is named *"auto download and notify for
install"*, and that second clause is not optional — telling a human to press Install is the only
other thing Windows Update is allowed to do. There's no value meaning *"download it, don't install
it, and stay quiet"*. So suppressing Windows' installs necessarily switches on Windows' nagging:

> **Updates are available**
> Required updates need to be installed.
> *Your organization manages your update settings*

That toast is Windows working exactly as configured, **not** a missed reboot signal — it says
*install*, never *restart*. `UpdateNotificationLevel` is the Windows Update for Business setting that
exists precisely so a fleet whose updates are managed elsewhere doesn't nag its users about work
already being done. SunUp is that manager, population one.

It's set to **1, not 2**, deliberately. Level 2 would also suppress restart warnings. SunUp owns
restart messaging and does it better — but a Windows restart warning is an *independent* backstop for
a SunUp that's broken, not running, or reporting clean while doing nothing, which is not hypothetical
(v0.13.1: *"the Dell path was dead for four days, reporting clean"*). Keep the second opinion.

Writing any value under this branch is also what makes Windows say *"your organization manages your
update settings"* — on a standalone box with no domain, no Entra join and no MDM. That wording is
about the policy branch, not about your machine being enrolled in anything.

`WuPolicy.ps1` holds the values and the reasoning; `Install.ps1` asserts them, `Uninstall.ps1`
reverts them, `-Mode Status` reports them, and the test suite pins them.

> **If you uninstall SunUp, the policy must come off with it** — and `Uninstall.ps1` does that. Left
> behind, `AUOptions=3` means Windows downloads updates forever and installs none of them: no error,
> a green Windows Update page, and a box that has quietly stopped patching itself.

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
Win11-styled dialog above in your desktop session. Since v0.17.0 the **restart** lives in its own
native notification (`SunUp-Restart`, below); this dialog is the record of what happened, and takes
the countdown back only if a toast cannot be shown. It lists the current run's updates in normal color
and the past `notify.historyDays` (default **30**) greyed out below, with a **When** column. By default
the history is collapsed to the latest occurrence per package (`notify.historyCollapse`) so daily
Defender-signature bumps don't flood it.

### Restarts, on your terms

If — and only if — an update leaves a restart **pending**, a native Windows **Restarting Soon**
notification appears in your desktop session and owns a cancellable countdown:

- a header, then **which update** is asking (named, not "an update");
- a smaller line saying, in ordinary words, what is still exposed or still broken until you restart;
- a countdown that ticks in place;
- **Restart now**, and **Pause** — which toggles to **Unpause** and holds the countdown
  **indefinitely**. Nothing auto-resumes it. If you paused it, you meant it.

A restart that isn't actually needed never prompts you. If no one is logged in, the engine restarts
headlessly after a grace period and shows the summary at next sign-in. If a toast can't be shown for
any reason, the summary dialog takes the countdown back — the machine is never restarted without a
visible warning.

The default `rebootPolicy: "ifRequired"` restarts only when a component **this run** actually
reported a restart as required. Set `"always"` to restart on any confirmed pending state, or
`"never"` to never auto-restart.

After the machine comes back, the summary says when it went down and when it returned, in local time:

```
Restarted to finish updates.  restarted 9:09:45 AM, back up 9:10:15 AM (down 30s)
```

### How SunUp knows it has already restarted

Whichever surface issues a restart records it first — for which run, and **which boot the machine was
on** — in `notify\restart-state.json`. "Has the restart happened?" is then an integer comparison of
two readings of the same counter, with no clock, timezone or timestamp involved:

> A restart is complete iff the current boot identity differs from the recorded one.

If that record cannot be written, **the restart is not issued.** A restart nothing can prove happened
is one the next sign-in would ask for again — which is exactly what happened on 2026-08-12, when a
mis-parsed timestamp had this machine restart three times in seventy minutes. It also means a
restart that was issued but *didn't happen* (an aborted shutdown, an app blocking it) is now a state
of its own: SunUp says so and offers a manual button, instead of quietly trying again.

### If a restart is already pending, SunUp doesn't install on top of it

An update that is installed but waiting on a restart is reported by the Windows Update agent as
**not installed** — so it gets offered again, and installing it again is redoing finished work.

That is not hypothetical. On 2026-08-12 Windows' own update orchestrator installed the August
cumulative at 21:45 the night before; SunUp reinstalled it at 08:04 the next morning. It cost four
minutes, told you it had installed 93 GB that were already on the disk, and — because under
`ifRequired` only *this run's* work triggers a restart — it manufactured the restart request that
started three of them.

So SunUp now checks for a pending servicing restart **before** it runs, and skips the Windows Update
pass while one is outstanding: those updates are installed and waiting to be committed, and the job
at that point is to get the machine restarted, not to pile more on top. The skip still asks for the
restart, so it lasts one cycle at most, and it never applies under `rebootPolicy: "never"` — where
no restart is coming and skipping would mean never installing at all.

> Windows Update's own auto-install was the other half of this, and `Install.ps1` now sets it to
> **download but notify** — see [Who installs Windows updates](#who-installs-windows-updates--and-why-windows-goes-quiet).
> Note that the pre-flight skip above fixes this failure *on its own*: the policy is not what keeps
> the duplicate install away, it's what keeps your `notTitle` pins enforceable. Until v0.20.0 the
> policy was a manual registry edit documented only here, so every machine except the author's ran a
> configuration the product had never been tested against.

### How "pending" is decided

`RebootState.ps1` is the single detector, shared by the engine, the tray, the summary dialog and the
restart toast, so no two of them can disagree about whether this machine needs restarting or whether
it already has. It **classifies** signals rather than counting them, and reports *why*, which
`-Mode Status`, the run log, the toast and the dialog all draw on:

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
updates — so the **next** run detects the orphaned dir, reports it once (event 2011 + an alert
toast naming the last line it logged) and marks it with `incomplete.json`. A run still in progress
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

Install also sets the [Windows Update policy](#who-installs-windows-updates--and-why-windows-goes-quiet)
that hands install timing to SunUp, and **`Uninstall.ps1` reverts it** — with or without `-Purge`, since
leaving it behind would stop the machine installing Windows updates at all. Only the four values
SunUp wrote are removed, and a key is deleted only if it's left empty, so a real Group Policy sharing
that branch is untouched.

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

`Status.ps1` reports the [Windows Update policy](#who-installs-windows-updates--and-why-windows-goes-quiet)
alongside the reboot state, so the split of responsibility is visible on the box rather than only in
this file:

```
  Reboot now    : False
  WU policy     : SunUp owns install timing; Windows notifications suppressed
```

If the policy has drifted — a re-imaged box, a competing GPO, an install that never ran — each missing
value is listed with its consequence, followed by `-> re-run Install.ps1 to reassert`. The line worth
knowing on sight is `Windows Update is DISABLED by policy`: that's `NoAutoUpdate=1`, which is *not* a
stricter version of what SunUp wants — it stops the downloads SunUp then has nothing to install.

## Configuration

`C:\ProgramData\SunUp\config.json` (reloaded each run; keys missing from an older file are merged from
defaults):

| Key | Default | Meaning |
|---|---|---|
| `rebootPolicy` | `"ifRequired"` | `ifRequired` reboots only when a component this run required it; `always` reboots on any *confirmed* pending state (see [How "pending" is decided](#how-pending-is-decided)); `never` never does |
| `rebootDelaySeconds` | `120` | headless restart grace |
| `rebootGraceInteractiveSec` | `300` | countdown the **Restarting Soon** notification shows when a user is logged in. Pausing it holds it indefinitely; this is only the starting value |
| `pendingRebootAlertDays` | `3` | under `ifRequired`, alert once if a reboot stays pending this many days without a run requiring it (`0` disables). The timer restarts whenever the box boots |
| `keepRuns` | `30` | per-run log dirs to retain |
| `notify.enabled` | `true` | show the summary dialog and the restart notification at all |
| `notify.historyDays` | `30` | days of past updates shown (greyed) in the dialog |
| `notify.historyCollapse` | `true` | keep only the latest occurrence per package in the history |
| `notify.historyMaxRows` | `500` | cap on history rows |
| `notify.explain` | `"off"` | `off` uses the built-in plain-language consequence table — offline, instant, no key. `auto` additionally asks Claude for a sentence about what *these* updates leave exposed, cached per KB in `notify\why-cache.json` so each is researched once ever. Bounded by a 30s timeout; every failure falls back to the table, and it never delays a restart warning by more than that |
| `vendorUpdates` | `"allow"` | `block` keeps **this machine's OEM** from pushing driver/firmware/utility updates, on both delivering paths (Windows Update titles + winget ids). The OEM is detected at run time, so the same setting blocks Dell on a Dell and Lenovo on a Lenovo — see `VendorProfiles.ps1`. A block that can't be enforced (unrecognized OEM) is logged, never silent |
| `windowsUpdate.notTitle` | `"NVIDIA"` | skip updates whose title matches (preserves pinned drivers) |
| `winget.excludePattern` | (regex) | skip pinned/self-updating apps — applied to **both** the machine and user passes |
| `winget.userScope` | `true` | also upgrade per-user (HKCU) packages via `SunUp-User` (see below) |
| `winget.selfHostPattern` | `Microsoft\.PowerShell\|Microsoft\.DesktopAppInstaller` | packages that host the engine's own process. The engine does **not** upgrade these — it hands them to `SelfHost.ps1` (see below) |
| `winget.selfHostInstallerArgs` | `MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress` | **unused since v0.12.0**, retained so existing configs load. Passing this via `--custom` did not stop Restart Manager (measured 2026-07-28) |
| `psModules.everyDays` | `7` | run PowerShell-module updates at most this often |
| `hygiene.enabled` | `true` | read-only hygiene checks. Silent on a healthy box, so leaving it on costs one report line |
| `hygiene.minFreeGB` | `25` | free-space threshold — the **only** size check here. Size heuristics were rejected everywhere else: the biggest directories on a dev box are usually deliberate (a pinned Rust toolchain, a NuGet cache), and a threshold that fires every run against intentional state is how an alert log becomes wallpaper |

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
- Windows PowerShell 5.1 (`powershell.exe`, present on every Windows install). Two components run
  there on purpose: `SelfHost.ps1`, because Restart Manager cannot reach a separate installation, and
  `Show-RestartToast.ps1`, because the WinRT toast APIs have no .NET Core projection.
- [PSWindowsUpdate](https://www.powershellgallery.com/packages/PSWindowsUpdate) (installed by `Install.ps1`).
- `notify.explain = auto` additionally wants the `claude` CLI on `PATH`. Without it SunUp uses its
  built-in explanations and logs the fact — nothing else changes.

## License

MIT
