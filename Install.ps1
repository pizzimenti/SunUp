#Requires -RunAsAdministrator
<#
Deploys SunUp to C:\ProgramData\SunUp, ensures its dependencies (PSWindowsUpdate +
Microsoft Update service, Dell Command Update best-effort), registers the SYSTEM 'SunUp'
task with three triggers (Daily 08:00, Boot+1h, Resume+1h) and the interactive 'SunUp-Notify'
dialog task, and refreshes the SysSentry baseline so the tasks don't read as security drift.

If a previous 'AutoUpdate' install is detected (v0.4.x and earlier), it is migrated in place:
its data dir, logs, history and config are moved to the SunUp name and the old tasks/event
source are removed — idempotently, so re-running heals a partial migration.
#>
$ErrorActionPreference = 'Stop'

$Name    = 'SunUp'
$OldName = 'AutoUpdate'                  # previous name to migrate from
$Root    = "C:\ProgramData\$Name"
$Bin     = Join-Path $Root 'bin'
$Notify  = Join-Path $Root 'notify'
$Task    = $Name
$NotifyTask = "$Name-Notify"

# ---- migrate a previous AutoUpdate install (quiesce + move data) -------------
# Runs BEFORE the deploy. Quiesces+moves only here; old tasks/source are removed AFTER the new
# ones are registered (below), so there's never a window with zero working tasks.
function Invoke-RenameMigration {
  $oldRoot  = "C:\ProgramData\$OldName"
  $oldTasks = @($OldName, "$OldName-Notify")
  $hasOldTask = @($oldTasks | Where-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue }).Count -gt 0
  $present = (Test-Path $oldRoot) -or $hasOldTask -or [System.Diagnostics.EventLog]::SourceExists($OldName)
  if (-not $present) { return }
  Write-Host "Detected previous '$OldName' install — migrating to '$Name'…"
  # 1. Quiesce old tasks so a trigger can't fire mid-migration.
  foreach ($t in $oldTasks) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
      try { Stop-ScheduledTask    -TaskName $t -ErrorAction SilentlyContinue } catch {}
      try { Disable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
  }
  # 2. Move the data dir (atomic same-volume rename; preserves config/logs/history/notify/ACLs).
  if ((Test-Path $oldRoot) -and -not (Test-Path $Root)) {
    for ($i = 0; $i -lt 3; $i++) {
      try { Move-Item -LiteralPath $oldRoot -Destination $Root -ErrorAction Stop; break }
      catch {
        if ($i -eq 2) { throw "Could not move $oldRoot -> $Root ($_). Ensure no run is active, then re-run Install.ps1." }
        Start-Sleep -Seconds 2
      }
    }
    # Rename the old main log inside the moved dir (cosmetic — keeps the timeline under the new name).
    $oldLog = Join-Path $Root ("logs\{0}.log" -f $OldName.ToLower())
    $newLog = Join-Path $Root ("logs\{0}.log" -f $Name.ToLower())
    if ((Test-Path $oldLog) -and -not (Test-Path $newLog)) { try { Move-Item $oldLog $newLog -Force } catch {} }
    Write-Host "  moved $oldRoot -> $Root (config, logs, history preserved)"
  } elseif (Test-Path $Root) {
    Write-Host "  $Root already exists — leaving old $oldRoot in place for manual review (not clobbering)."
  }
}

# ---- remove the old install AFTER new tasks/source exist ---------------------
function Remove-OldInstall {
  foreach ($t in @($OldName, "$OldName-Notify")) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
      try { Unregister-ScheduledTask -TaskName $t -Confirm:$false; Write-Host "  removed old task '$t'" } catch {}
    }
  }
  if ([System.Diagnostics.EventLog]::SourceExists($OldName)) {
    try { Remove-EventLog -Source $OldName; Write-Host "  removed old event source '$OldName'" } catch {}
  }
}

Invoke-RenameMigration

New-Item -ItemType Directory -Force -Path $Bin, (Join-Path $Root 'logs'), $Notify | Out-Null
# The dialog runs as the non-elevated interactive user and must read the payload + clear its
# pendingShow flag, so grant that account Modify on the notify subfolder only (rest stays admin-only).
$nUser = "$env:USERDOMAIN\$env:USERNAME"
& icacls $Notify /grant "${nUser}:(OI)(CI)M" /T 2>&1 | Out-Null
Write-Host "Granted $nUser Modify on $Notify"
Copy-Item (Join-Path $PSScriptRoot 'SunUp.ps1')            $Bin -Force
Copy-Item (Join-Path $PSScriptRoot 'Status.ps1')          $Bin -Force
Copy-Item (Join-Path $PSScriptRoot 'Show-UpdateDialog.ps1') $Bin -Force
Copy-Item (Join-Path $PSScriptRoot 'SunUp-Tray.ps1')       $Bin -Force
# Drop the old-named engine if it rode along in a migrated bin (Move-Item brought the whole tree).
Remove-Item (Join-Path $Bin "$OldName.ps1") -Force -ErrorAction SilentlyContinue

# ---- config (seed only; never clobber local edits on reinstall) -------------
$ConfigFile = Join-Path $Root 'config.json'
if (-not (Test-Path $ConfigFile)) {
@'
{
  "rebootPolicy": "ifRequired",
  "rebootDelaySeconds": 120,
  "rebootGraceInteractiveSec": 300,
  "pendingRebootAlertDays": 3,
  "keepRuns": 30,
  "notify":        { "enabled": true, "historyDays": 30, "historyCollapse": true, "historyMaxRows": 500 },
  "windowsUpdate": { "enabled": true, "notTitle": "NVIDIA" },
  "winget":        { "enabled": true, "pinIds": [], "excludePattern": "NVIDIA|GeForce|Claude|Anthropic|ElementLabs|LM ?Studio|Spotify|Discord|Slack|Teams|VCLibs" },
  "defender":      { "enabled": true },
  "psModules":     { "enabled": true, "everyDays": 7 },
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
# SunUp REPORT — caldera

Per-run digests appended by `bin\SunUp.ps1` (newest at bottom, trimmed to ~900 lines).
Full detail in `logs\sunup.log`; failures also surface in SysSentry ALERTS.md and the
Application event log (source SunUp, IDs 2000=start 2001=clean 2005=reboot 2010=errors).

---
'@ | Set-Content $ReportFile -Encoding UTF8
}

# ---- event log source -------------------------------------------------------
if (-not [System.Diagnostics.EventLog]::SourceExists($Name)) {
  New-EventLog -LogName Application -Source $Name
  Write-Host "Created Application event source: $Name"
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
$action    = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Bin\SunUp.ps1`" -Mode Run"
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

Register-ScheduledTask -TaskName $Task -Action $action -Principal $principal -Settings $settings `
  -Trigger @($tDaily, $tBoot, $tResume) -Force `
  -Description 'caldera daily update routine (WU/winget/Defender/Dell/PS modules). Daily 08:00 if awake; else +1h after boot/resume. Once per day via lastrun.json stamp.' | Out-Null
Write-Host "Registered task '$Task' (Daily 08:00, Boot+1h, Resume+1h)."

# ---- notify task: runs in the INTERACTIVE USER session to show the dialog ----
# On-demand only (no triggers besides AtLogon) — the SYSTEM engine fires it via Start-ScheduledTask.
# Interactive logon type = no stored password, runs in the user's desktop session; RunLevel Highest
# so the dialog can actually reboot (shutdown/Restart-Computer need an elevated token).
$nAction    = New-ScheduledTaskAction -Execute $pwsh -Argument "-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Bin\Show-UpdateDialog.ps1`""
$nPrincipal = New-ScheduledTaskPrincipal -UserId $nUser -LogonType Interactive -RunLevel Highest
# Parallel (StopExisting isn't exposed by this cmdlet) + the dialog closes any other open SunUp dialog
# on startup => a newer cycle replaces an open one. AtLogon trigger => post-reboot (and headless-run)
# summaries appear at sign-in (the dialog self-gates on the pendingShow flag).
$nSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
$nLogon     = New-ScheduledTaskTrigger -AtLogOn -User $nUser
Register-ScheduledTask -TaskName $NotifyTask -Action $nAction -Principal $nPrincipal -Settings $nSettings -Trigger $nLogon -Force `
  -Description 'Shows the SunUp summary dialog (and owns the restart countdown) in the interactive user session. Fired on demand by the engine; AtLogon shows a not-yet-seen cycle (e.g. post-reboot). Self-gates on notify\latest-updates.json pendingShow.' | Out-Null
Write-Host "Registered task '$NotifyTask' (interactive, on-demand + AtLogon) as $nUser."

# ---- tray task: persistent system-tray presence in the interactive session ---
# AtLogon, single-instance (IgnoreNew + the script's own mutex), never times out. RunLevel Highest
# so its "Run now" can trigger the SYSTEM SunUp task and its "Auto-reboot" toggle can edit config.json.
$TrayTask   = "$Name-Tray"
$trAction   = New-ScheduledTaskAction -Execute $pwsh -Argument "-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Bin\SunUp-Tray.ps1`""
$trPrincipal= New-ScheduledTaskPrincipal -UserId $nUser -LogonType Interactive -RunLevel Highest
$trSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$trLogon    = New-ScheduledTaskTrigger -AtLogOn -User $nUser
Register-ScheduledTask -TaskName $TrayTask -Action $trAction -Principal $trPrincipal -Settings $trSettings -Trigger $trLogon -Force `
  -Description 'SunUp system-tray presence (sun icon + menu: Run now / Show last summary / Open logs / Auto-reboot toggle). Logon-launched, single-instance, in the interactive user session.' | Out-Null
Write-Host "Registered task '$TrayTask' (interactive, AtLogon) as $nUser."
# (Re)start the tray now so it's present without waiting for the next logon. Stop any prior instance
# first so the new build takes over (the mutex would otherwise make the new one exit immediately).
try { Stop-ScheduledTask -TaskName $TrayTask -ErrorAction SilentlyContinue } catch {}
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*SunUp-Tray.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
try { Start-ScheduledTask -TaskName $TrayTask -ErrorAction Stop; Write-Host "Started '$TrayTask'." } catch { Write-Host "(tray will start at next logon)" }

# ---- remove the old AutoUpdate tasks/source now that SunUp's are live --------
Remove-OldInstall

# ---- refresh SysSentry baseline so the renamed tasks aren't flagged as drift ----
$sentry = 'C:\ProgramData\SysSentry\bin\Sentry.ps1'
if (Test-Path $sentry) {
  Write-Host 'Refreshing SysSentry baseline…'
  & $pwsh -NoProfile -ExecutionPolicy Bypass -File $sentry -Mode Baseline | Out-Null
}

Write-Host ''
Write-Host 'SunUp installed. Verify:  pwsh -File C:\ProgramData\SunUp\bin\Status.ps1'
Write-Host 'Dry run now (bypass day stamp): pwsh -File C:\ProgramData\SunUp\bin\SunUp.ps1 -Mode Run -Force'
exit 0   # success — don't let a sub-step's native exit code (e.g. the baseline tool) become ours
