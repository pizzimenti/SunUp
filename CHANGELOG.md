# Changelog

All notable changes to AutoUpdate. Format: [Keep a Changelog](https://keepachangelog.com/).

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

[0.4.2]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.4.2
[0.4.1]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.4.1
[0.4.0]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.4.0
[0.3.2]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.3.2
[0.3.1]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.3.1
[0.3.0]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.3.0
[0.2.0]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.2.0
[0.1.0]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.1.0
