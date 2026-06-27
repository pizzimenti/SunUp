# Changelog

All notable changes to AutoUpdate. Format: [Keep a Changelog](https://keepachangelog.com/).

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

[0.1.0]: https://github.com/pizzimenti/AutoUpdate/releases/tag/v0.1.0
