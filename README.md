# AutoUpdate — caldera's own daily update routine

Windows Update's built-in scheduling on this box is unreliable, so AutoUpdate replaces it
with a deterministic, logged, once-per-day routine that patches **everything** safe to patch
unattended. Companion to [ProcWatch](../ProcWatch) (realtime CPU) and
[SysSentry](../SysSentry) (security drift).

## When it runs

One scheduled task (`AutoUpdate`, runs as **SYSTEM**) with three triggers, de-duplicated to
**once per calendar day** by a stamp file (`lastrun.json`):

| Trigger | Fires | Purpose |
|---|---|---|
| Daily 08:00 | only if the box is **awake** (never wakes it) | the normal daily run |
| Boot + 1h | 1h after a cold boot | catches a day missed while powered off |
| Resume + 1h | 1h after wake-from-sleep (Power-Troubleshooter ID 1) | catches a day missed while asleep |

Whichever trigger fires first does the work and stamps the date; the others see the stamp and
no-op. So: it updates at 8am if the box is up, otherwise ~1h after it next wakes/boots — exactly
once a day. The +1h delay keeps updates from interrupting you the moment you sit down.

## What it updates (all toggleable in `config.json`)

1. **Microsoft Defender** signatures (`Update-MpSignature`)
2. **Windows + Microsoft Update** (PSWindowsUpdate, `-MicrosoftUpdate`) — **excludes any update
   titled `NVIDIA`** so the pinned GTX 1060 driver (580.97, last Pascal branch) is never replaced
3. **winget** packages (`winget upgrade --all`) — SYSTEM-scope packages; per-user apps
   (Spotify/Discord/Slack) self-update on their own. Holds back any exact IDs in `winget.pinIds`
4. **Dell Command Update** drivers/firmware/utilities — **BIOS is reported, never auto-flashed**
   (unattended BIOS flash = brick risk on power loss); BIOS availability is logged + alerted
5. **PowerShell modules** (`Update-Module`)
6. (pip / npm global — present but **off by default**; global upgrades can break toolchains)

After everything, a single **coordinated reboot** if anything left one pending
(`rebootPolicy: always`, with a 120s `shutdown /a`-able countdown). The box's Automatic services
(Tailscale, sshd) bring it back on the tailnet so mistral's reach is restored on boot.

## Layout

- Source: `C:\Users\user\Code\AutoUpdate` (this repo)
- Deployed: `C:\ProgramData\AutoUpdate\bin\{AutoUpdate.ps1,Status.ps1}`
- Outputs: `logs\autoupdate.log`, `REPORT.md` (digests), `config.json`, `lastrun.json`,
  `dell-bios-scan.log`. Application event log source `AutoUpdate`
  (2000 start, 2001 clean, 2005 reboot, 2010 errors).

## Manage

```powershell
pwsh -File C:\ProgramData\AutoUpdate\bin\Status.ps1                       # last run, stamp, next run, pending reboot
pwsh -File C:\ProgramData\AutoUpdate\bin\AutoUpdate.ps1 -Mode Run -Force  # run now, bypass the day stamp
```

Install / update / remove (elevated, from this repo):

```powershell
pwsh -File .\Install.ps1      # deploy + register task + refresh SysSentry baseline
pwsh -File .\Uninstall.ps1    # remove task (add -Purge to delete data + event source)
```

Failures surface in **SysSentry `ALERTS.md`** (triaged at session start) and the event log, so a
broken update run won't pass silently.

## Notes / limitations

- Runs as SYSTEM → sees machine-scope winget packages, not per-user ones (those self-update).
- The day stamp is set even if a component errors; errors are logged/alerted and you re-run with
  `-Force`. It won't auto-retry the same day.
- After changing the task or engine, follow the refresh-running-version flow: bump `VERSION` +
  `$script:Version`, update CHANGELOG, commit + tag, re-run `Install.ps1`, refresh SysSentry baseline.
