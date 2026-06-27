# Changelog

All notable changes to AutoUpdate. Format: [Keep a Changelog](https://keepachangelog.com/).

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
