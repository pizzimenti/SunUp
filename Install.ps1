#Requires -RunAsAdministrator
<#
Deploys AutoUpdate to C:\ProgramData\AutoUpdate, ensures its dependencies
(PSWindowsUpdate + Microsoft Update service, Dell Command Update best-effort),
registers the SYSTEM 'AutoUpdate' task with three triggers (Daily 08:00,
Boot+1h, Resume+1h), and refreshes the SysSentry baseline so the new task
doesn't read as security drift.
#>
$ErrorActionPreference = 'Stop'

$Root    = 'C:\ProgramData\AutoUpdate'
$Bin     = Join-Path $Root 'bin'
$Notify  = Join-Path $Root 'notify'
New-Item -ItemType Directory -Force -Path $Bin, (Join-Path $Root 'logs'), $Notify | Out-Null
# The dialog runs as the non-elevated interactive user and must read the payload + clear its
# pendingShow flag, so grant that account Modify on the notify subfolder only (rest stays admin-only).
$nUser = "$env:USERDOMAIN\$env:USERNAME"
& icacls $Notify /grant "${nUser}:(OI)(CI)M" /T 2>&1 | Out-Null
Write-Host "Granted $nUser Modify on $Notify"
Copy-Item (Join-Path $PSScriptRoot 'AutoUpdate.ps1')       $Bin -Force
Copy-Item (Join-Path $PSScriptRoot 'Status.ps1')          $Bin -Force
Copy-Item (Join-Path $PSScriptRoot 'Show-UpdateDialog.ps1') $Bin -Force

# ---- config (seed only; never clobber local edits on reinstall) -------------
$ConfigFile = Join-Path $Root 'config.json'
if (-not (Test-Path $ConfigFile)) {
@'
{
  "rebootPolicy": "always",
  "rebootDelaySeconds": 120,
  "rebootGraceInteractiveSec": 300,
  "keepRuns": 30,
  "notify":        { "enabled": true },
  "windowsUpdate": { "enabled": true, "notTitle": "NVIDIA" },
  "winget":        { "enabled": true, "pinIds": [], "excludePattern": "NVIDIA|GeForce|Claude|Anthropic|ElementLabs|LM ?Studio|Spotify|Discord|Slack" },
  "defender":      { "enabled": true },
  "psModules":     { "enabled": true },
  "dell":          { "enabled": true, "applyTypes": "driver,firmware,utility", "reportTypes": "bios" },
  "pip":           { "enabled": false },
  "npm":           { "enabled": false }
}
'@ | Set-Content $ConfigFile -Encoding UTF8
  Write-Host 'Seeded config.json'
}

# ---- REPORT.md --------------------------------------------------------------
$ReportFile = Join-Path $Root 'REPORT.md'
if (-not (Test-Path $ReportFile)) {
@'
# AutoUpdate REPORT — caldera

Per-run digests appended by `bin\AutoUpdate.ps1` (newest at bottom, trimmed to ~900 lines).
Full detail in `logs\autoupdate.log`; failures also surface in SysSentry ALERTS.md and the
Application event log (source AutoUpdate, IDs 2000=start 2001=clean 2005=reboot 2010=errors).

---
'@ | Set-Content $ReportFile -Encoding UTF8
}

# ---- event log source -------------------------------------------------------
if (-not [System.Diagnostics.EventLog]::SourceExists('AutoUpdate')) {
  New-EventLog -LogName Application -Source 'AutoUpdate'
  Write-Host 'Created Application event source: AutoUpdate'
}

# ---- PSWindowsUpdate + Microsoft Update service -----------------------------
if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
  Write-Host 'Installing PSWindowsUpdate from PSGallery…'
  try {
    Get-PackageProvider -Name NuGet -ForceBootstrap -ErrorAction SilentlyContinue | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module PSWindowsUpdate -Scope AllUsers -Force -AcceptLicense -ErrorAction Stop
    Write-Host 'PSWindowsUpdate installed.'
  } catch { Write-Warning "PSWindowsUpdate install failed: $_  (Windows Update component will be skipped until this is resolved.)" }
}
# Register the Microsoft Update service so -MicrosoftUpdate covers Office/other MS products too.
try {
  Import-Module PSWindowsUpdate -ErrorAction Stop
  Add-WUServiceManager -ServiceID '7971f918-a847-4430-9279-4a52d1efe18d' -Confirm:$false -ErrorAction Stop | Out-Null
  Write-Host 'Microsoft Update service registered.'
} catch { Write-Warning "Could not register Microsoft Update service: $_" }

# ---- Dell Command Update (best-effort; enables the hardware component) -------
$dcu = @('C:\Program Files\Dell\CommandUpdate\dcu-cli.exe','C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe') |
       Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $dcu) {
  Write-Host 'Dell Command Update not found — attempting winget install (best-effort)…'
  foreach ($id in 'Dell.CommandUpdate.Universal','Dell.CommandUpdate') {
    try {
      winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { Write-Host "Installed $id"; break }
    } catch {}
  }
  Write-Host '(If install failed, hardware updates are simply skipped — set dell.enabled=false in config.json to silence.)'
}

# ---- scheduled task: SYSTEM, three triggers ---------------------------------
$pwsh      = (Get-Command pwsh).Source
$action    = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Bin\AutoUpdate.ps1`" -Mode Run"
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
# No -WakeToRun (won't wake the box → "only if awake"); no -StartWhenAvailable
# (a missed 08:00 is caught by the +1h Boot/Resume triggers, not run immediately on wake).
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew

# Trigger 1 — daily at 08:00 (runs only if the box is awake).
$tDaily = New-ScheduledTaskTrigger -Daily -At 08:00

# Trigger 2 — 1 hour after a cold boot (catches a day missed while powered off).
$tBoot = New-ScheduledTaskTrigger -AtStartup
$tBoot.Delay = 'PT1H'

# Trigger 3 — 1 hour after resume from sleep (Power-Troubleshooter, System log, EventID 1).
$evtClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$tResume  = New-CimInstance -CimClass $evtClass -ClientOnly
$tResume.Enabled      = $true
$tResume.Delay        = 'PT1H'
$tResume.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and (EventID=1)]]</Select></Query></QueryList>'

Register-ScheduledTask -TaskName 'AutoUpdate' -Action $action -Principal $principal -Settings $settings `
  -Trigger @($tDaily, $tBoot, $tResume) -Force `
  -Description 'caldera daily update routine (WU/winget/Defender/Dell/PS modules). Daily 08:00 if awake; else +1h after boot/resume. Once per day via lastrun.json stamp.' | Out-Null
Write-Host "Registered task 'AutoUpdate' (Daily 08:00, Boot+1h, Resume+1h)."

# ---- notify task: runs in the INTERACTIVE USER session to show the dialog ----
# On-demand only (no triggers) — the SYSTEM engine fires it via Start-ScheduledTask.
# Interactive logon type = no stored password, runs in the user's desktop session;
# if nobody's logged in it simply doesn't run (no one to show UI to).
$nAction    = New-ScheduledTaskAction -Execute $pwsh -Argument "-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Bin\Show-UpdateDialog.ps1`""
$nPrincipal = New-ScheduledTaskPrincipal -UserId $nUser -LogonType Interactive -RunLevel Limited
# Parallel (StopExisting isn't exposed by this cmdlet) + the dialog closes any other open
# AutoUpdate dialog on startup => a newer cycle replaces an open one. AtLogon trigger => post-reboot
# (and headless-run) summaries appear at sign-in (the dialog self-gates on the pendingShow flag).
$nSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
$nLogon     = New-ScheduledTaskTrigger -AtLogOn -User $nUser
Register-ScheduledTask -TaskName 'AutoUpdate-Notify' -Action $nAction -Principal $nPrincipal -Settings $nSettings -Trigger $nLogon -Force `
  -Description 'Shows the AutoUpdate summary dialog (and owns the restart countdown) in the interactive user session. Fired on demand by the engine; AtLogon shows a not-yet-seen cycle (e.g. post-reboot). Self-gates on notify\latest-updates.json pendingShow.' | Out-Null
Write-Host "Registered task 'AutoUpdate-Notify' (interactive, on-demand + AtLogon) as $nUser."

# ---- refresh SysSentry baseline so the new task isn't flagged as drift ------
$sentry = 'C:\ProgramData\SysSentry\bin\Sentry.ps1'
if (Test-Path $sentry) {
  Write-Host 'Refreshing SysSentry baseline…'
  & $pwsh -NoProfile -ExecutionPolicy Bypass -File $sentry -Mode Baseline
}

Write-Host ''
Write-Host 'AutoUpdate installed. Verify:  pwsh -File C:\ProgramData\AutoUpdate\bin\Status.ps1'
Write-Host 'Dry run now (bypass day stamp): pwsh -File C:\ProgramData\AutoUpdate\bin\AutoUpdate.ps1 -Mode Run -Force'
