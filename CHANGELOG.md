# Changelog

All notable changes to SunUp (formerly AutoUpdate). Format: [Keep a Changelog](https://keepachangelog.com/).

## [0.10.0] - 2026-07-27

### Fixed — SunUp no longer kills itself while upgrading PowerShell
- On **2026-07-22** the run died mid-flight and nothing said so for five days. Root cause:
  winget's `Microsoft.PowerShell 7.6.3 → 7.6.4` upgrade. SunUp runs under `pwsh`, and the MSI's
  **Restart Manager** enumerates processes holding files under the install target and shuts them
  down — including the engine that asked for the install. Event log, 14:15:19–14:15:23:
  `RestartManager 10002 Shutting down application or service 'PowerShell 7'` →
  `10010 Application 'pwsh.exe' cannot be restarted — Application SID does not match Conductor SID` →
  `MsiInstaller 11708 Product: PowerShell 7-x64 — Installation failed` (rolled back; the box stayed on
  7.6.3). The engine was terminated ~200 lines before its reboot decision, so it never rebooted, never
  showed the dialog, and never wrote `result.json`. The `ifRequired` policy was not at fault — the
  code that evaluates it never executed. (Collateral: the same sweep killed ProcWatch's engine, which
  stayed dead until the box was rebooted by hand.)
- Packages that host the engine's own process are now identified by **`winget.selfHostPattern`**
  (default `Microsoft\.PowerShell|Microsoft\.DesktopAppInstaller`) and handled two ways:
  - **Upgraded last**, after every other package — a surprise kill can no longer cost the packages
    that hadn't been reached yet.
  - **Installed with Restart Manager disabled**, via `winget --custom` carrying
    **`MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress`** (`winget.selfHostInstallerArgs`).
    With RM off, files in use fall back to PendingFileRename: the install completes, the engine
    **survives**, and the MSI returns `3010`, which SunUp already maps to "reboot required" — so the
    restart happens where it belongs, in the one coordinated reboot at the end of the run.
  - `--custom` (appends to winget's defaults), never `--override` (which would *replace* them and
    drop the `/qn` that keeps the install silent).
- Those args are **Windows Installer properties**, so they are only attached when they can actually
  apply. `Get-WingetInstallerType` asks `winget show` what is about to run and
  `Test-MsiPropertiesApply` gates on it: `msi`/`wix`/`burn` (bundles forward properties to the MSIs
  they wrap) get the args; `msix` — which is what `Microsoft.DesktopAppInstaller` is — along with
  `exe`/`inno`/`nullsoft` and an unreadable type do not, since those would receive the properties as
  junk on their command line. Such packages are still **deferred to last**, and the run logs that
  Restart Manager could not be disabled for them. (Raised in review by CodeRabbit.)

### Added — a killed run is no longer silent (event 2011)
- A run terminated mid-flight produced **no signal whatsoever**: `result.json`, `history.jsonl`,
  events 2001/2010, the SysSentry echo and the summary dialog are all written *after* the component
  loop, and `lastrun.json` is never stamped — so the next day's run looked like an ordinary
  first-run-of-the-day. The only trace of 2026-07-22 was ProcWatch's unrelated stale-heartbeat alert.
- Each run now scans for the fingerprint of a dead run — a previous run dir with `run.log` but **no**
  `result.json` — and reports it once with **event 2011** + a SysSentry alert quoting the last line
  that run logged, so the message says *where* it stopped. `incomplete.json` marks a dir as reported
  so the alert can't repeat.
- "No `result.json`" alone would also match a run **still in progress**. `MultipleInstances=IgnoreNew`
  only serializes *task-launched* runs — the documented `SunUp.ps1 -Mode Run -Force` is a standalone
  process the scheduler never sees, so a manual run and a scheduled one genuinely can overlap. Every
  run therefore writes a **`running.json`** liveness marker (PID **plus that process's start time**,
  because PIDs are recycled) before touching a single component, and deletes it once `result.json`
  exists. `Test-RunAlive` clears a candidate only when the marked PID is running *and* the image name
  and start time still match; if the start time can't be read it assumes **alive**, so a live peer is
  never mislabelled. A dir with no marker predates v0.10.0 or died before writing one — either way
  its owner is gone, so it still counts as crashed. (Caught in review by Codex.)
- Two further concurrency holes closed, also from review:
  - **Run dirs are now claimed atomically.** The stamp has second resolution, so two runs starting in
    the same second were handed the *same* dir — interleaved logs, one `running.json` overwriting the
    other, and whichever finished first writing a `result.json` that made the dir look complete even
    if its peer was killed later. `New-RunDirectory` claims a dir by **creating** it (`New-Item`
    without `-Force` fails if it exists, so the claim is atomic against a racing peer) and falls back
    to a PID-qualified name, then a counter.
  - **The marker is dropped only once `result.json` is really on disk.** `$ErrorActionPreference` is
    `Continue`, so a transient lock or I/O error let `Set-Content` fail quietly while the marker was
    deleted regardless — leaving a run with neither file, which a peer could read as a crash or the
    next run could read as a completed run that was killed. The write is now terminating and
    verified; if it fails the marker stays and the run is reported unfinished, which is the truth.

### Added — `tests\Test-SunUp.ps1`
- First tests in the repo, covering both changes above without performing a real update run: the
  engine parses; `Report-CrashedRuns` (lifted from source via the PowerShell AST, so the test
  exercises the shipped code) flags exactly the dead run dirs and exactly once, ignoring finished
  runs, empty dirs and the live run; the self-hosting partition loses no package, orders PowerShell
  last, and attaches `--custom` to that package alone. `pwsh -File .\tests\Test-SunUp.ps1`

## [0.9.0] - 2026-07-08

### Fixed — winget rows now show a real download size instead of "—"
- winget updates always displayed `—` in the dialog's **size** column. Root cause: `Get-WingetSizeMB`
  scraped the size from winget's animated `/ N MB` download progress, but SunUp installs with
  `--silent --disable-interactivity`, which suppresses that progress entirely — winget's captured
  output logs only a bare `Downloading <url>` line with no byte count, so the regex never matched and
  size was always `$null`. This was a source-text problem, not a parsing bug: the number simply wasn't
  in the text.
- Replaced `Get-WingetSizeMB` with **`Get-WingetDownloadSizeMB`**, which reads the true installer size
  over HTTP. It extracts every `Downloading <url>` line from the install output and issues a `HEAD`
  request per artifact with **`Accept-Encoding: identity`** — identity is load-bearing: it forces the
  server off on-the-fly gzip, which otherwise omits `Content-Length` (Google's CDN does exactly this,
  the reason a naive HEAD returned nothing). Sizes are summed across artifacts so installs that pull
  dependencies count them all. Verified live: Google Chrome now reports **466.5 MB**.
- The lookup runs **after** the package has already upgraded, so a network hiccup, chunked-transfer
  server, or expired signed URL only blanks the size cell — never the update or its status. Returns
  `$null` (→ `—`) honestly when there is no URL (msstore packages install via the Store) or no
  `Content-Length`. Runs under `pwsh` (PS7+), whose default TLS needs no pinning.

## [0.8.1] - 2026-07-03

### Fixed — duplicate update rows no longer triple-count sizes
- A single run could record the **same logical update multiple times**. Windows Update offers an
  Audio Processing Object (APO) driver package **once per matching audio endpoint**, so the
  2026-07-02 run stored three byte-identical `AudioProcessingObject Driver Update (1.0.4.7057)`
  rows (same `name|source|old|new|sizeMB`). This bloated `updates[]` in `history.jsonl` and, worse,
  tripled the dialog's `totalSizeMB` — **87 MB reported for 29 MB of actual bytes** (WU downloads
  the package once regardless of how many endpoints claim it).
- The engine now collapses rows identical in `name|source|old|new|sizeMB` into a single row before
  the result is persisted, annotating the count as `×N` (e.g. `AudioProcessingObject Driver Update
  (1.0.4.7057) ×3`) and keeping **one representative size** so totals reflect reality. Rows that
  merely share a name but differ in version or size stay separate — size is part of the collapse key.

## [0.8.0] - 2026-07-02

### Changed — `rebootPolicy: "ifRequired"` is the new default (no more reboots you didn't need)
- SunUp already computed two reboot signals but decided on the wrong one: `rebootPending` (a blunt
  OS-level flag that a PnP/driver install trips even when nothing needs a restart) drove the reboot,
  while `rebootRequiredByRun` (whether a component **this run** actually reported `reboot=true`) was
  only recorded. The reboot decision is now a `rebootPolicy` switch:
  - **`ifRequired`** (new default) — reboot only when a component this run required it.
  - **`always`** — reboot on any OS pending flag (the old 0.1.0–0.7.0 behavior; still available).
  - **`never`** — never auto-reboot.
  - Motivating case: a 2026-07-02 run installed only a Defender signature + a Microsoft
    AudioProcessingObject **driver**; the driver set the OS pending flag, so `always` rebooted the box
    even though `rebootRequiredByRun` was `false`. Under `ifRequired` that morning would not reboot.
- When an OS pending flag is set but no component this run required a reboot, `ifRequired` logs it
  quietly (INFO) instead of raising a daily SysSentry "reboot pending" alert. `never` still nudges.
- Tray **Auto-reboot when needed** toggle is now three-state aware: the checkmark means *enabled*
  (`ifRequired` **or** `always`); toggling on sets the smart `ifRequired` default, toggling off sets
  `never`. Balloon reads "Auto-reboot is now ON (only when required)".

### Added — hardening for the `ifRequired` blind spot + winget observability
- **Stale pending-reboot watchdog.** `ifRequired` deliberately leaves an OS pending flag that no run
  required — but a *genuinely* needed reboot (missed detection, or a flag set outside SunUp) could
  then sit forever. The engine now tracks how long a flag has persisted (via `pendingSince` in
  `lastrun.json`) and raises a **one-time** WARN + event `2006` + SysSentry alert once it exceeds
  `pendingRebootAlertDays` (default `3`, `0` disables). Rebooting or the flag clearing resets it.
- **winget list-exit logging.** A non-zero exit from `winget upgrade` (network/source hiccup) parses
  to zero rows and used to masquerade as "up to date"; the list exit code is now logged (and a WARN
  emitted) so an incomplete scan is visible.
- **Skipped packages surfaced.** Excluded winget packages now show as a count in the component detail
  (`up to date, 2 skipped` / `1 upgraded, 0 failed (of 1), 2 skipped`), not just buried in the raw log.
- **Dialog honors run-signal reboots (PR review, Codex P1).** Under `ifRequired` a reboot can be
  required by the run (e.g. a winget/MSI `3010` exit) while no OS pending flag is set. The dialog now
  decides pre- vs post-reboot by whether the box has **booted since the run finished** (`runEndUtc`
  vs `LastBootUpTime`) instead of the OS pending flag — which previously misread a flag-less reboot as
  "already rebooted" and silently skipped the interactive countdown. Defaults to showing the countdown
  on any uncertainty. Headless reboots were unaffected.
- **A failed winget upgrade-list no longer reports "up to date" (PR review).** A non-zero list exit
  with zero parsed rows now returns `warn` ("upgrade list incomplete") so `result.json`/`Status`
  reflect the partial run, not just the log.

### Fixed — winget no longer warns every run on unupgradable UWP framework packages
- `Microsoft.VCLibs.140.00` / `.UWPDesktop` are UWP **framework** packages that winget can't deploy
  (they fail `0x8A15005C` "Failed to extract the contents of the archive" every run) and are serviced
  by the Store / dependent apps, not winget. They're now in the default `winget.excludePattern`, so a
  clean run stops flipping to **warn** over an unactionable, perennial failure.
- Excluded winget packages are now logged (count + ids) to `winget.log` and the run log — a skip is a
  deliberate decision, not a silent no-op.

## [0.7.0] - 2026-06-27

### Added — system-tray presence (`SunUp-Tray.ps1`)
- Windows has no service-manager face for a scheduled task, so SunUp now has a **tray icon** (a sun;
  turns amber when a reboot is pending) with a right-click menu: a header (last run + next scheduled
  run), **Run now** (triggers the SYSTEM task), **Show last summary** (re-opens the dialog), **Open
  logs folder**, an **Auto-reboot when needed** toggle (flips `rebootPolicy` in config; the checkmark
  reflects state), and **Exit**. Double-clicking the icon opens the last summary. The tip/icon refresh
  on a 45s timer, and a **balloon** pops when a new run completes.
- Launched at logon by a new **`SunUp-Tray`** task (interactive user, single-instance via a named
  mutex + `MultipleInstances=IgnoreNew`, `RunLevel Highest` so its actions can drive the SYSTEM task
  and edit config). `Install.ps1` registers and starts it; `Uninstall.ps1` stops and removes it.

## [0.6.0] - 2026-06-27

### Changed — capture every column the sources actually expose (no more avoidable blanks)
- **Dell now records real name + version + download size** per applied update, parsed from
  `dcu-cli /scan -report` XML (`<name>`/`<version>`/`<bytes>`), instead of the old generic
  `'installed'` / `—`. The engine scans to an XML report first, partitions into apply (driver/
  firmware/utility) vs BIOS (report-only), applies, then records the applied set from the report.
- **Dell exit codes are interpreted correctly.** Previously every result was labelled
  "drivers/firmware applied (exit N)" even when nothing applied. Now: `0`=applied, `1`=applied+reboot,
  `5`=reboot pending from a prior op (nothing applied now), `500`=no applicable updates, else=warn.
- **Windows Update fills the "old" column for OS updates** by snapshotting the build (`CurrentBuild.UBR`)
  before/after the run — a Cumulative/Feature/Servicing-Stack update shows `26200.8737 -> 26200.9xxx`
  instead of a blank. Per-update size is still taken from WU when it reports it.
- **Batch installers (WU, Dell) now show a Duration** — the measured install/apply batch span. Exact
  for a single-item batch; the shared batch total when several install together (documented).

### Notes — the only two cells that can still legitimately show "—"
- **Defender download size**: no Defender API exposes the signature-package size.
- **Dell "old" version**: dcu-cli's report lists only the *available* version, never the installed one.
These are source limitations, not logging gaps — the data doesn't exist to capture.

## [0.5.0] - 2026-06-27

### Changed
- **Renamed `AutoUpdate` → `SunUp`** (it runs at dawn so you start the day with fresh updates, and
  keeps the "up" of Update). Every path, scheduled-task name (`SunUp` / `SunUp-Notify`), event-log
  source, and the dialog title now derive from a single `$Name` constant in each script. `Install.ps1`
  performs an **idempotent live migration**: it quiesces the old tasks, `Move-Item`s
  `C:\ProgramData\AutoUpdate` → `C:\ProgramData\SunUp` (preserving config, logs, history, notify
  state, ACLs), registers the new-named tasks *before* removing the old ones, swaps the event source,
  and refreshes the SysSentry baseline last. Re-running heals a partial migration.

### Added
- **30-day update history in the dialog.** Below the current run (normal color), the dialog lists the
  past `notify.historyDays` (default 30) of updates **greyed out but legible**, with a new **When**
  column. The engine (SYSTEM) assembles the list from `history.jsonl` and embeds it in the
  user-readable notify payload, since the non-elevated dialog can't read `logs\`. `notify.historyCollapse`
  (default **true**) keeps only the latest occurrence per package so daily Defender-signature bumps
  don't flood the list; `notify.historyMaxRows` (default 500) caps it. Greying is a DataGridCell
  `DataTrigger` on a per-row `IsPast` flag using the existing muted-grey theme color.

### Fixed
- **Per-update Duration column was empty for Defender.** The engine timed each component but discarded
  it for the per-row record. Defender's `Update-MpSignature` is now wrapped in its own Stopwatch so its
  Duration populates. Windows Update / Dell per-row Duration stays "—" on purpose: they install items as
  a batch and expose no per-item timing, and stamping each row with the shared batch time would be a lie
  (per-row durations are display-only, not summed into totals). Defender/Dell download **size** stays "—"
  (those sources expose no size).

## [0.4.3] - 2026-06-27

### Fixed
- **Post-reboot dialog showed the literal text `&#x2714;`** instead of a green ✔. The two
  checkmarks in the *XAML string* render fine (XamlReader decodes XML entities), but the
  post-reboot branch assigned `"&#x2714;"` directly to a `TextBlock.Text` property at runtime —
  not XAML, so it displayed verbatim. Now assigns the real glyph via `[char]0x2714`.

### Changed
- **Dialog restart now leads with `Restart-Computer -Force`**, with `shutdown.exe` as the fallback
  (was the reverse). In the elevated interactive-task context `shutdown.exe` returns **exit=1 even
  with the privilege held** (observed during the 0.4.2 real-reboot test — only the
  `Restart-Computer` fallback actually rebooted), so the proven call now goes first. The visible
  countdown already serves as the user warning.
- **PowerShell module updates moved to weekly** (`psModules.everyDays`, default 7), gated by their
  own `psmodules-lastrun.json` stamp — the slowest component (~5–7 min) for the rarest payload now
  runs ~once a week instead of daily, cutting the typical daily run to ~2–3 min. The rest of the
  cycle still runs every day. A failed module run isn't stamped, so it retries the next day.

## [0.4.2] - 2026-06-27

### Fixed
- **Restart from the dialog silently did nothing.** Two stacked bugs: the `AutoUpdate-Notify` task
  ran `RunLevel Limited`, so `shutdown.exe` was Access-Denied (the CLI needs an elevated token even
  though the privilege is held); and `Invoke-Restart` used `Start-Process` with no `-Wait/-PassThru`,
  discarding the error. Now the notify task runs `RunLevel Highest`, and `Invoke-Restart` captures
  `shutdown.exe`'s exit code to `notify\reboot.log` and falls back to `Restart-Computer -Force`.

## [0.4.1] - 2026-06-27

### Fixed
- Dialog title bar stayed light on a dark system theme: the `SourceInitialized` handler used
  `$using:light`, which is only valid in remoting/job scriptblocks — in a WPF event handler it
  throws, and the `try/catch` silently skipped BOTH DWM calls (dark title bar *and* acrylic).
  Switched to a script-scope `$script:isDark`. Title bar now follows the theme and the acrylic
  backdrop actually applies.

## [0.4.0] - 2026-06-27

### Changed
- **Dialog shows after EVERY cycle**, even when nothing was updated (friendly "You're up to date"
  empty state).
- **Reboot trigger reverted to "is a reboot pending when checked"** (`Test-PendingReboot`), not the
  v0.3.1 per-run signal. Chrome sets no pending flag → never prompts; Dell/WU drivers do → countdown
  — even if a *prior* run installed them. (Removes the v0.3.1/0.3.2 "only this run" gating.)
- **Pre- and post-reboot dialogs both show the changes table.** One payload drives both; the dialog
  re-checks the live pending-reboot state at display time: pending now → table + cancellable
  countdown (Restart now / Postpone); already rebooted → table + "Restarted to finish" + Close.
- **A newer cycle replaces an open dialog** (`AutoUpdate-Notify` → `MultipleInstances=StopExisting`).
- Post-reboot (and headless-run) summaries appear at next sign-in via an **AtLogon trigger** on the
  notify task; display is gated by a `pendingShow` flag the dialog clears once seen.

### Added
- `notify\` subfolder (payload `latest-updates.json` moved here); installer grants the interactive
  user **Modify** on it so the non-elevated dialog can clear `pendingShow`.

## [0.3.2] - 2026-06-27

### Changed
- `winget.excludePattern` now also skips load-bearing per-user/Electron apps whose uninstaller
  refuses to run while open: **LM Studio** (the `:1234` API), Spotify, Discord, Slack (added
  `ElementLabs|LM ?Studio|Spotify|Discord|Slack`). Surfaced when a per-package winget upgrade tried
  to update a *running* LM Studio and its uninstall step failed (harmless — winget aborted, install
  left intact). Note: these are per-user (HKCU) installs, so the real SYSTEM task never sees them;
  this guards manual/user-session runs and documents intent. Such apps self-update anyway.

## [0.3.1] - 2026-06-27

### Changed
- **Restart is offered only when an update installed THIS RUN actually requires it** — never for a
  pre-existing/unrelated pending-reboot state. A Chrome-only run (winget exit 0) never prompts a
  restart. The per-run signal comes from each installer: winget reboot exit codes (MSI 3010 +
  `0x8A150077/78/79`, treated as success-with-reboot), Windows Update's per-update/post-install
  reboot status, and dcu-cli exit **1** (reboot required by this apply) — exit **5** (reboot pending
  from a prior op) explicitly does NOT count. `result.json` gains `rebootRequiredByRun`; the global
  `rebootPending` is kept for Status/info only. A pre-existing pending reboot is logged quietly,
  never prompted.

## [0.3.0] - 2026-06-27

### Added
- **Win11 summary dialog after each run that changed something** (`Show-UpdateDialog.ps1`): an
  acrylic-backdrop WPF window with a gridlined table — package, source, old version, new version,
  duration, download size — plus summary chips (count / total size / total time). Light/dark + accent
  aware. Shown via a new on-demand **`AutoUpdate-Notify`** task that runs in the interactive user
  session (SYSTEM can't show UI); engine fires it with `Start-ScheduledTask`.
- **Per-item update capture**: winget now upgrades packages individually so each one's old→new
  version, duration, and download size are recorded; Windows Update items carry KB + size; Dell
  drivers and Defender signature bumps are recorded too. Written to `latest-updates.json` and into
  `result.json` (`updates[]`).
- **Reboot ownership split** (fixes the restart-race): when a user is logged in, the dialog owns a
  visible, cancellable countdown (`rebootGraceInteractiveSec`, default 300s) with Restart now /
  Postpone — the engine no longer reboots out from under an interactive user. Headless (no user),
  the engine reboots itself after `rebootDelaySeconds` as before. `policy=never` never reboots.
- `winget.excludePattern` (default `NVIDIA|GeForce|Claude|Anthropic`) — per-item skip of pinned/
  self-updating packages now that winget upgrades one at a time. `notify.enabled` config toggle.
- `Get-Config` merges the on-disk config over defaults, so a config written by an older version
  still resolves keys added later.

## [0.2.0] - 2026-06-27

### Added
- **Three-tier logging for fast failure diagnosis:**
  - `logs\autoupdate.log` — curated rolling timeline, now rotated at 5MB × 5.
  - `logs\runs\<yyyy-MM-dd_HHmmss>\` — isolated per-run directory (retention: last `keepRuns`, default 30),
    holding `run.log` (this run's timeline), `transcript.log` (full Start-Transcript capture), a
    `<component>.log` with the **raw output of every tool** (defender/windowsupdate/winget/dell-apply/
    dell-bios-scan/psmodules), and `result.json` (structured per-component result).
  - `logs\history.jsonl` — one compact JSON line per run (queryable trail of every run's outcome).
- Per-component **timing** + **full exception capture** (message + ScriptStackTrace) via a uniform
  `Invoke-Component` runner; each component returns a structured `{status, detail, error}`.
- New query modes: `-Mode Errors` (last failed runs with error text + tail of the relevant component
  log) and `-Mode Tail` (tail of the most recent run.log). `Status` now shows per-component status,
  durations, and flags failures with a pointer to drill in.
- `keepRuns` config key (per-run log retention).

### Changed
- Reboot is decided/recorded (`rebootAction`) in `result.json`; transcript is stopped before reboot.

## [0.1.0] - 2026-06-27

### Added
- Initial release. Deterministic once-per-day update routine replacing flaky Windows Update timing.
- SYSTEM scheduled task `AutoUpdate` with three triggers (Daily 08:00 if awake, Boot+1h, Resume+1h),
  de-duplicated to once/day via `lastrun.json` stamp.
- Components (toggleable in `config.json`): Microsoft Defender signatures, Windows + Microsoft Update
  (PSWindowsUpdate, NVIDIA driver excluded to preserve the pinned 580.97), winget upgrades,
  Dell Command Update drivers/firmware (BIOS reported only, never auto-flashed), PowerShell modules.
  pip/npm stubs present but off by default.
- Coordinated end-of-run reboot (`rebootPolicy: always`, 120s abortable countdown).
- Logging to `logs\autoupdate.log` + `REPORT.md` digests + Application event log (source `AutoUpdate`).
  Failures also raised into SysSentry `ALERTS.md`.
- `Install.ps1` installs PSWindowsUpdate + registers Microsoft Update service, best-effort installs
  Dell Command Update, registers the task, and refreshes the SysSentry baseline.

[0.8.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.8.0
[0.7.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.7.0
[0.6.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.6.0
[0.5.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.5.0
[0.4.3]: https://github.com/pizzimenti/SunUp/releases/tag/v0.4.3
[0.4.2]: https://github.com/pizzimenti/SunUp/releases/tag/v0.4.2
[0.4.1]: https://github.com/pizzimenti/SunUp/releases/tag/v0.4.1
[0.4.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.4.0
[0.3.2]: https://github.com/pizzimenti/SunUp/releases/tag/v0.3.2
[0.3.1]: https://github.com/pizzimenti/SunUp/releases/tag/v0.3.1
[0.3.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.3.0
[0.2.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.2.0
[0.1.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.1.0
