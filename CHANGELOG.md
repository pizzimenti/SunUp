# Changelog

All notable changes to AutoUpdate. Format: [Keep a Changelog](https://keepachangelog.com/).

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

[0.2.0]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.2.0
[0.1.0]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.1.0
