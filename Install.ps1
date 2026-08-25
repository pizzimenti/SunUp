#Requires -RunAsAdministrator
<#
Deploys SunUp to C:\ProgramData\SunUp, ensures its dependencies (PSWindowsUpdate +
Microsoft Update service), registers the SYSTEM 'SunUp'
task with three triggers (Daily 08:00, Boot+1h, Resume+1h) and the interactive 'SunUp-Notify'
dialog task, plus the restart-toast and alert-toast tasks in the interactive session.

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
# The dialog, the tray and the restart toast all run as the interactive user and must read the
# payload + clear its pendingShow flag, so grant that account Modify on the notify subfolder only
# (rest stays admin-only).
#
# Worth being precise, because the comments here previously were not: those tasks run at RunLevel
# Highest, i.e. ELEVATED, not "non-elevated" as this file used to claim. $nUser is also
# $env:USERNAME of an already-elevated installer (#Requires -RunAsAdministrator at the top), so it
# is an administrator by construction. That means this grant does not hand anything to a lesser
# principal -- but it does mean notify\ is writable by the same account the elevated tasks run as,
# so nothing in there is a trustworthy place to keep a decision about what those tasks may do.
# See Get-ExplainMode in Show-RestartToast.ps1 for the one case where that mattered.
$nUser = "$env:USERDOMAIN\$env:USERNAME"
& icacls $Notify /grant "${nUser}:(OI)(CI)M" /T 2>&1 | Out-Null
Write-Host "Granted $nUser Modify on $Notify"
Copy-Item (Join-Path $PSScriptRoot 'SunUp.ps1')            $Bin -Force
Copy-Item (Join-Path $PSScriptRoot 'Status.ps1')          $Bin -Force
Copy-Item (Join-Path $PSScriptRoot 'Show-UpdateDialog.ps1') $Bin -Force
Copy-Item (Join-Path $PSScriptRoot 'SunUp-Tray.ps1')       $Bin -Force
# Run by Windows PowerShell 5.1 from a one-shot task, so it survives the Restart Manager shutdown
# that upgrading PowerShell 7 triggers. See the header of SelfHost.ps1.
Copy-Item (Join-Path $PSScriptRoot 'SelfHost.ps1')         $Bin -Force
# Runs as the interactive user: SYSTEM cannot see HKCU-registered packages at all.
Copy-Item (Join-Path $PSScriptRoot 'UserScope.ps1')        $Bin -Force
# OEM identification for the vendorUpdates policy. Dot-sourced by BOTH the engine and the user pass,
# so the two can never disagree about what this machine's vendor is.
Copy-Item (Join-Path $PSScriptRoot 'VendorProfiles.ps1')   $Bin -Force
# Reboot detection, timestamp handling and the restart decision. Dot-sourced by the engine, the tray,
# the summary dialog AND the restart toast, so no two of them can disagree about whether this machine
# needs restarting or whether it already has. Two copies of that question is what restarted this box
# three times on 2026-08-12.
Copy-Item (Join-Path $PSScriptRoot 'RebootState.ps1')      $Bin -Force
# The Windows Update policy SunUp's install ownership depends on. Shipped to bin so -Mode Status can
# report it on a deployed box, not only in a checkout.
Copy-Item (Join-Path $PSScriptRoot 'WuPolicy.ps1')         $Bin -Force
# Read-only hygiene checks (v0.21.0). Also runnable on its own from bin for an on-demand audit:
#   pwsh -File C:\ProgramData\SunUp\bin\Hygiene.ps1
Copy-Item (Join-Path $PSScriptRoot 'Hygiene.ps1')          $Bin -Force
# The restart toast and the protocol handler behind its buttons. Windows PowerShell 5.1 only -- the
# WinRT toast APIs do not project into pwsh 7.
Copy-Item (Join-Path $PSScriptRoot 'Show-RestartToast.ps1') $Bin -Force
Copy-Item (Join-Path $PSScriptRoot 'Invoke-ToastAction.ps1') $Bin -Force
# SunUp's own alert toasts (SysSentry, which used to render them, retired 2026-08-15).
Copy-Item (Join-Path $PSScriptRoot 'Show-AlertToast.ps1')  $Bin -Force
# Drop the old-named engine if it rode along in a migrated bin (Move-Item brought the whole tree).
Remove-Item (Join-Path $Bin "$OldName.ps1") -Force -ErrorAction SilentlyContinue

# The dialog and the toast dot-source bin\RebootState.ps1, and they can read it today only because
# bin inherits ProgramData's default Users:(OI)(CI)(RX) -- nothing ever asserted it. Assert it, so a
# tightened ACL upstream becomes a failed install rather than a dialog that silently degrades to
# making no restart decision at all. S-1-5-32-545 is BUILTIN\Users by SID, locale-independent.
#
# The grant is READ+EXECUTE only, deliberately: bin\ holds the scripts those elevated tasks run, so
# write access here would be a straight path to code execution with an administrator token.
& icacls $Bin /grant "*S-1-5-32-545:(OI)(CI)RX" 2>&1 | Out-Null
Write-Host "Asserted read+execute (never write) on $Bin for BUILTIN\Users."

# A payload written by v0.16.0 or earlier carries no runStamp, so nothing can prove whether its
# restart was already issued. Get-RestartDisplayState refuses to arm a countdown on one -- correct,
# but it also means the box would show a stale summary until the next run. Deleting it is cleaner:
# the only loss is one summary the user has almost certainly already seen.
$oldPayload = Join-Path $Notify 'latest-updates.json'
if (Test-Path $oldPayload) {
  $needsReset = $true
  try { $needsReset = -not ((Get-Content $oldPayload -Raw | ConvertFrom-Json).PSObject.Properties.Name -contains 'schemaVersion') } catch {}
  if ($needsReset) {
    Remove-Item $oldPayload -Force -ErrorAction SilentlyContinue
    Write-Host 'Removed a pre-v0.17.0 notify payload (no runStamp, so no restart could be proven against it).'
  }
}

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
  "vendorUpdates": "allow",
  "notify":        { "enabled": true, "historyDays": 30, "historyCollapse": true, "historyMaxRows": 500 },
  "windowsUpdate": { "enabled": true, "notTitle": "NVIDIA" },
  "winget":        { "enabled": true, "pinIds": [], "excludePattern": "NVIDIA|GeForce|Claude|Anthropic|ElementLabs|LM ?Studio|Spotify|Discord|Slack|Teams|VCLibs" },
  "defender":      { "enabled": true },
  "psModules":     { "enabled": true, "everyDays": 7 },
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
Full detail in `logs\sunup.log`; failures also surface as alert toasts (notify\alerts-history.md) and in the
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

# ---- Windows Update policy: SunUp owns install timing -----------------------
# SunUp installs Windows updates itself, which only means something if Windows is not also installing
# them on its own schedule -- and `windowsUpdate.notTitle` (the NVIDIA pin) exists ONLY on SunUp's
# path, because Windows Update has no per-title exclusion at all. So the policy is a prerequisite of
# the design, not a preference.
#
# It was applied by hand on 2026-08-12 and lived nowhere but README prose until v0.20.0, which meant
# every box except this one ran a configuration the product was never tested against. Asserting it
# here is the whole point; WuPolicy.ps1 carries the reasoning and the values.
$wuPolicyScript = Join-Path $PSScriptRoot 'WuPolicy.ps1'
if (Test-Path $wuPolicyScript) {
  . $wuPolicyScript
  Write-Host 'Windows Update policy (SunUp owns install timing, Windows notifications suppressed):'
  Set-SunUpWuPolicy | ForEach-Object { Write-Host $_ }
  $st = Get-SunUpWuPolicyState
  if (-not $st.OwnsInstalls) {
    Write-Warning "Windows Update policy did not take: $($st.Summary). Windows may install updates behind SunUp, and notTitle exclusions will not be enforced."
  }
} else {
  Write-Warning 'WuPolicy.ps1 missing — Windows Update policy NOT asserted. Windows may install updates on its own schedule and notTitle exclusions will not be enforced.'
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
  -Description 'caldera daily update routine (WU/winget/Defender/PS modules). Daily 08:00 if awake; else +1h after boot/resume. Once per day via lastrun.json stamp.' | Out-Null
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

# ---- restart toast: the "Restarting Soon" notification and its countdown -----
# WINDOWS POWERSHELL 5.1, not $pwsh. The WinRT toast APIs have no projection in .NET Core, so
# [Windows.UI.Notifications.ToastNotificationManager] simply does not resolve under pwsh 7. Same
# carve-out SelfHost.ps1 makes, different reason. Never change this to $pwsh.
$RestartTask = "$Name-Restart"
$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$rAction    = New-ScheduledTaskAction -Execute $ps51 -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Bin\Show-RestartToast.ps1`""
$rPrincipal = New-ScheduledTaskPrincipal -UserId $nUser -LogonType Interactive -RunLevel Highest
# IgnoreNew, not Parallel: two countdowns for one run would race to restart the box. Never times
# out -- it owns a countdown the user is allowed to pause indefinitely.
$rSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
# No AtLogon trigger, deliberately. The summary dialog handles logon; a toast that re-armed a
# countdown at every sign-in is precisely the 2026-08-12 failure, and while the restart record now
# makes that impossible, not having the trigger at all is a second lock on the same door.
Register-ScheduledTask -TaskName $RestartTask -Action $rAction -Principal $rPrincipal -Settings $rSettings -Force `
  -Description 'Shows the SunUp "Restarting Soon" toast and owns the restart countdown (Restart now / Pause). Windows PowerShell 5.1 because the toast APIs are WinRT-only. Fired on demand by the engine; exits 2 if a toast cannot be shown so the caller falls back to the summary dialog.' | Out-Null
Write-Host "Registered task '$RestartTask' (interactive, on-demand, WinPS 5.1) as $nUser."

# ---- alert toast task: SunUp's own voice, in the interactive session --------
# Drains notify\alerts.jsonl into persistent toasts. SYSTEM has no desktop and pwsh has no WinRT,
# so this is the same interactive + WinPS 5.1 shape as the restart toast. AtLogon so alerts queued
# while signed out surface at the next sign-in; on-demand via Start-ScheduledTask from any writer.
# RunLevel Limited: showing a notification needs no privilege, so it gets none.
$AlertsTask = "$Name-Alerts"
$aAction    = New-ScheduledTaskAction -Execute $ps51 -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Bin\Show-AlertToast.ps1`""
$aPrincipal = New-ScheduledTaskPrincipal -UserId $nUser -LogonType Interactive -RunLevel Limited
# IgnoreNew is safe BECAUSE the queue is the source of truth: a start dropped while an instance is
# live costs nothing -- the live instance (or the next fire) drains what was queued.
$aSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
$aLogon     = New-ScheduledTaskTrigger -AtLogOn -User $nUser
Register-ScheduledTask -TaskName $AlertsTask -Action $aAction -Principal $aPrincipal -Settings $aSettings -Trigger $aLogon -Force `
  -Description 'Drains SunUp''s alert queue (notify\alerts.jsonl) into persistent desktop toasts. Windows PowerShell 5.1 because the toast APIs are WinRT-only. Fired on demand by any Raise-Alert writer; AtLogon catches alerts queued while signed out.' | Out-Null
Write-Host "Registered task '$AlertsTask' (interactive, on-demand + AtLogon, WinPS 5.1) as $nUser."

# ---- sunup: protocol, so the toast's buttons can reach us -------------------
# A toast button can activate three ways: "foreground" and "background" both require a COM activator
# registered under a CLSID, which an unpackaged script cannot sanely provide; "system" only
# dismisses. "protocol" is the one that works for a script. HKCU, so no elevation and no machine-wide
# footprint; Uninstall.ps1 removes it.
$proto = 'HKCU:\Software\Classes\sunup'
try {
  New-Item -Path $proto -Force | Out-Null
  New-ItemProperty -Path $proto -Name '(Default)'    -Value 'URL:SunUp Protocol' -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $proto -Name 'URL Protocol' -Value ''                   -PropertyType String -Force | Out-Null
  New-Item -Path "$proto\shell\open\command" -Force | Out-Null
  $protoCmd = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" "%1"' -f $ps51, (Join-Path $Bin 'Invoke-ToastAction.ps1')
  New-ItemProperty -Path "$proto\shell\open\command" -Name '(Default)' -Value $protoCmd -PropertyType String -Force | Out-Null
  Write-Host 'Registered the sunup: protocol (the restart toast buttons activate through it).'
} catch { Write-Host "WARNING: could not register the sunup: protocol ($_) - the toast buttons will not respond." }

# ---- user-scope winget task: the packages SYSTEM structurally cannot see -----
# winget resolves installed packages PER USER, so anything registered under HKCU is invisible to
# the SYSTEM engine — not skipped, absent. Measured 2026-07-28: the two lists were disjoint, and
# six of the user's packages (Deno, yt-dlp FFmpeg, fzf, ripgrep, Rufus, Sysinternals) matched
# nothing in excludePattern, i.e. they had never been updated by SunUp at all.
# Same principal as the notify/tray tasks (Interactive, RunLevel Highest) — no new posture. Takes
# no arguments: it discovers the newest run dir itself, so this action can be registered once.
# On-demand only, no trigger: the engine starts it at the end of a run, and only when a user is
# logged on (an Interactive task cannot run otherwise).
$UserTask   = "$Name-User"
$uAction    = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Bin\UserScope.ps1`""
$uPrincipal = New-ScheduledTaskPrincipal -UserId $nUser -LogonType Interactive -RunLevel Highest
$uSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $UserTask -Action $uAction -Principal $uPrincipal -Settings $uSettings -Force `
  -Description 'Upgrades the per-user (HKCU) winget packages the SYSTEM engine cannot see. Shares winget.excludePattern with the engine. Fired on demand at the end of a run when a user is logged on.' | Out-Null
Write-Host "Registered task '$UserTask' (interactive, on-demand) as $nUser."

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
# Match the DEPLOYED PATH after -File, never the bare filename.
#
# This was `-like '*SunUp-Tray.ps1*'`, which force-killed any pwsh whose command line merely
# MENTIONED that name -- an admin's own shell inspecting the install, an editor, a script listing
# the deployed files. Measured 2026-08-12: a verification shell that happened to name the file was
# killed mid-install, and because it was this script's own caller, Install.ps1 died with it at exit
# 255, having registered every task but never reaching Start-ScheduledTask below. The tray was left
# stopped and the install looked like it had succeeded.
#
# The -ne $PID guard is belt and braces: with the path match this script can no longer match itself,
# but "never kill the process doing the killing" is worth stating rather than inferring.
$trayScript = Join-Path $Bin 'SunUp-Tray.ps1'
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
  Where-Object {
    $cl = "$($_.CommandLine)"
    $_.ProcessId -ne $PID -and (($cl -like "*-File `"$trayScript`"*") -or ($cl -like "*-File $trayScript*"))
  } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
try { Start-ScheduledTask -TaskName $TrayTask -ErrorAction Stop; Write-Host "Started '$TrayTask'." } catch { Write-Host "(tray will start at next logon)" }

# ---- remove the old AutoUpdate tasks/source now that SunUp's are live --------
Remove-OldInstall

Write-Host ''
Write-Host 'SunUp installed. Verify:  pwsh -File C:\ProgramData\SunUp\bin\Status.ps1'
Write-Host 'Dry run now (bypass day stamp): pwsh -File C:\ProgramData\SunUp\bin\SunUp.ps1 -Mode Run -Force'
exit 0   # success — don't let a sub-step's native exit code (e.g. the baseline tool) become ours
