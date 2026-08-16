#Requires -RunAsAdministrator
<#
Upgrades the packages that own the process SunUp's engine runs in ("self-hosting" packages:
Microsoft.PowerShell, Microsoft.DesktopAppInstaller).

WHY THIS IS A SEPARATE SCRIPT, RUN BY A SEPARATE RUNTIME
--------------------------------------------------------
Upgrading Microsoft.PowerShell has Windows Installer's Restart Manager enumerate every process
holding files under the install target and shut them down. On 2026-07-28 that was measured
directly (Application log, Microsoft-Windows-RestartManager):

  10000  Starting session 0
  10010  Application 'C:\Program Files\PowerShell\7\pwsh.exe' (pid ...) cannot be restarted -
         Application SID does not match Conductor SID          [x5 -- every pwsh on the box]
  10002  Shutting down application or service 'PowerShell 7'
  1033   Installation success or error status: 0                [the MSI itself succeeded]

v0.11.0 tried to prevent this from inside the engine by passing
MSIRESTARTMANAGERCONTROL=Disable via winget's --custom. The events above are from that attempt:
RM ran anyway and killed the engine mid-run, exactly as it had on 2026-07-22 and 2026-07-27.
Whether winget dropped the property or Windows Installer ignored it across the major-upgrade
transaction was never established -- and does not matter, because the mitigation had no feedback
loop: a silent no-op was indistinguishable from success until the engine died.

So this script does not try to survive Restart Manager. It stays out of the blast radius:

  * it is WINDOWS POWERSHELL 5.1 (System32\WindowsPowerShell\v1.0\powershell.exe) -- a separate
    installation, so RM shutting down 'PowerShell 7' cannot reach it. KEEP IT 5.1-COMPATIBLE:
    no ternaries, no ?? / ?., no 'clean' blocks. It must never require the thing it upgrades.
    KEEP IT PURE ASCII, TOO: 5.1 reads a BOM-less file as ANSI, so a single smart dash or
    ellipsis corrupts the parse. (This bit during development -- em dashes broke it outright.)
  * it is launched by a one-shot SCHEDULED TASK, not as a child of the engine, so it does not
    die with its parent and does not inherit the engine's job object.
  * it WAITS for the engine to exit first (-WaitForPid), so the engine always reaches its reboot
    decision, its summary dialog and its lastrun stamp before anything can kill it.

Interactive pwsh terminals ARE still killed when PowerShell 7 upgrades. That is Restart Manager
and nothing short of a reboot-time install avoids it; it is accepted (see CHANGELOG v0.12.0).

This script never reboots the box. The engine owns the reboot decision, and by the time this
runs the engine has already made it. A reboot requirement discovered here is recorded in
selfhost.json and surfaced by the next run's stale-pending-reboot watchdog.
#>
param(
  # COMMA-SEPARATED, and a plain [string] on purpose. The engine launches this with powershell.exe
  # -File, and -File passes every argument as a literal string: it cannot bind an array at all.
  # "-Ids a,b" arrives as the single string "a,b", and "-Ids a b" binds only "a" and silently drops
  # the rest. Both were measured. So take one string and split it here.
  [Parameter(Mandatory = $true)][string]$Ids,
  [Parameter(Mandatory = $true)][string]$RunDir,
  [string]$MainLog    = 'C:\ProgramData\SunUp\logs\sunup.log',
  [string]$EvtSource  = 'SunUp',
  # One-shot task to delete when done.
  [string]$TaskName   = 'SunUp-SelfHost',
  # Launched directly rather than by a task (the user-scope handoff does that): nothing to clean up.
  [switch]$NoTask,
  # PID of the engine process to wait for. 0 = do not wait.
  [int]$WaitForPid    = 0,
  [int]$WaitTimeoutSec = 300,
  # Scheduled task to wait for as well. The user-scope pass (SunUp-User) runs under pwsh 7, squarely
  # inside the blast radius of the PowerShell upgrade this script performs: Restart Manager shuts
  # 'PowerShell 7' down and the pass dies mid-'winget upgrade', losing both its packages and its
  # record of them. Empty = nothing to wait for.
  [string]$WaitForTask = '',
  [int]$WaitTaskTimeoutSec = 2700,
  # Sleep this long before doing anything. Used when the engine handed off while an interactive
  # reboot countdown was on screen: if the user lets it run out the box restarts and this process
  # goes with it (packages simply stay on the list); if they postpone, the upgrade proceeds after.
  [int]$InitialDelaySec = 0,
  # File-name stem for this pass's log/json inside the run dir. The user-scope handoff passes
  # 'user-selfhost' so it cannot clobber the SYSTEM pass's records.
  [string]$Label = 'selfhost'
)

$ErrorActionPreference = 'Continue'

$SelfLog  = Join-Path $RunDir ($Label + '.log')
$SelfJson = Join-Path $RunDir ($Label + '.json')

$IdList = @($Ids -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Write-Both {
  param([string]$Level, [string]$Msg)
  $line = ('{0} [{1,-5}] {2}: {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Label, $Msg)
  try { Add-Content -Path $MainLog -Value $line -Encoding UTF8 } catch {}
  try { Add-Content -Path $SelfLog -Value $line -Encoding UTF8 } catch {}
}
function Write-Raw {
  param($Lines)
  try { Add-Content -Path $SelfLog -Value ($Lines | Out-String) -Encoding UTF8 } catch {}
}
# Publish so a reader only ever sees this file WHOLE. The engine ingests these records on its next
# run, and Set-Content truncates its destination before writing: a reader that catches the file
# mid-write gets invalid JSON, treats the record as unreadable, and the run's upgrades, failures and
# reboot request are lost. Write to .tmp, prove it parses, then rename -- the rename is the publish.
# (Mirrors the engine's own Publish-JsonFile; kept local because this script must not depend on the
# engine being loadable.)
function Publish-Json {
  param($Object, [string]$Path)
  $tmp = $Path + '.tmp'
  try {
    ($Object | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
    $null = Get-Content $tmp -Raw -ErrorAction Stop | ConvertFrom-Json    # prove it is complete
    Move-Item -Path $tmp -Destination $Path -Force -ErrorAction Stop
    return $true
  } catch {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $false
  }
}
function Write-Evt {
  param([int]$Id, [string]$Type, [string]$Msg)
  try { Write-EventLog -LogName Application -Source $EvtSource -EventId $Id -EntryType $Type -Message $Msg -ErrorAction Stop } catch {}
}
function Raise-Alert {
  param([string]$Msg)
  # SunUp's own toast queue (SysSentry retired 2026-08-15; see the engine's Raise-Alert). Kept
  # self-contained like everything else in this file: the queue path and task name are duplicated
  # from the engine on purpose and must be kept in sync by hand.
  $q = 'C:\ProgramData\SunUp\notify\alerts.jsonl'
  try {
    $dir = Split-Path $q
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    (New-Object psobject -Property ([ordered]@{ ts = (Get-Date).ToString('o'); src = $Label; msg = "$Msg" }) |
      ConvertTo-Json -Compress) | Add-Content -Path $q -Encoding UTF8
  } catch {}
  try { Start-ScheduledTask -TaskName 'SunUp-Alerts' -ErrorAction Stop } catch {}
}
# Did winget get far enough that a retry would rerun a PARTIAL install? The retry below drops
# REBOOT=ReallySuppress, so it must fire ONLY when winget rejected that argument outright, before
# touching the installer. Testing for 'Starting package install' alone was too narrow: a failure
# mid-DOWNLOAD prints none of it, so a network blip or a CDN 5xx was misread as an argument
# rejection and retried WITHOUT the reboot suppression -- leaving the PowerShell MSI free to restart
# the box behind SunUp's back under /qn, the one thing that property exists to prevent. These are
# the three markers the engine's own Test-WingetArgsRejected checked before it was deleted.
function Test-InstallStarted {
  param([string]$Text)
  return ($Text -match '(?im)^\s*(Downloading\s+\S+|Starting package install|Successfully verified installer hash)')
}
# SYSTEM cannot see the per-user PATH shim for winget; mirror the engine's resolver.
function Resolve-Winget {
  $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($cmd -and (Test-Path $cmd.Source)) { return $cmd.Source }
  $exe = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' -ErrorAction SilentlyContinue |
         Sort-Object FullName | Select-Object -Last 1
  if ($exe) { return $exe.FullName }
  return $null
}

try { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null } catch {}

Write-Both 'INFO' ("starting for: {0}" -f ($IdList -join ', '))

# ---- sit out an interactive reboot countdown, if one is on screen ----------
# The engine hands off during a cancellable countdown rather than deferring the packages for a day
# on a reboot that may never happen. If the user lets the countdown run out, the box restarts and
# this process dies with it long before it touches winget -- which is the intended outcome.
if ($InitialDelaySec -gt 0) {
  Write-Both 'INFO' ("waiting {0}s for the interactive reboot countdown to resolve before upgrading" -f $InitialDelaySec)
  Start-Sleep -Seconds $InitialDelaySec
}

# ---- wait for the engine to finish -----------------------------------------
# The engine must complete its reboot decision, dialog and stamp BEFORE Restart Manager gets a
# chance to kill it. If the wait times out we proceed anyway: leaving the packages un-upgraded
# forever is worse than a late kill, and the engine's crashed-run detector reports it either way.
if ($WaitForPid -gt 0) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $WaitTimeoutSec) {
    $p = Get-Process -Id $WaitForPid -ErrorAction SilentlyContinue
    if (-not $p) { break }
    Start-Sleep -Seconds 2
  }
  $still = Get-Process -Id $WaitForPid -ErrorAction SilentlyContinue
  if ($still) {
    Write-Both 'WARN' ("engine pid {0} still alive after {1}s -- proceeding anyway (it may be killed by Restart Manager)" -f $WaitForPid, $WaitTimeoutSec)
  } else {
    Write-Both 'INFO' ("engine pid {0} exited after {1:N0}s -- safe to upgrade" -f $WaitForPid, $sw.Elapsed.TotalSeconds)
  }
}

# ---- wait for the user-scope pass as well ----------------------------------
# The engine exits within a second of starting SunUp-User, so waiting on the engine pid alone says
# nothing about that pass: it runs under pwsh 7 for minutes afterwards, and upgrading
# Microsoft.PowerShell here has Restart Manager shut 'PowerShell 7' down and kill it mid-'winget
# upgrade' -- no user-winget.json, no event, no alert, packages left half-upgraded. Two concurrent
# winget processes would also collide outright ("Another installation is already in progress").
if ($WaitForTask) {
  Start-Sleep -Seconds 5      # Start-ScheduledTask is async: let the task actually enter Running
  $tsw = [System.Diagnostics.Stopwatch]::StartNew()
  $state = ''
  while ($tsw.Elapsed.TotalSeconds -lt $WaitTaskTimeoutSec) {
    try { $state = "$((Get-ScheduledTask -TaskName $WaitForTask -ErrorAction Stop).State)" } catch { $state = '' }
    if ($state -ne 'Running') { break }
    Start-Sleep -Seconds 5
  }
  if ($state -eq 'Running') {
    Write-Both 'WARN' ("{0} was STILL running after {1}s -- upgrading anyway; Restart Manager may cut it off" -f $WaitForTask, $WaitTaskTimeoutSec)
  } else {
    Write-Both 'INFO' ("{0} is idle after {1:N0}s -- safe to upgrade" -f $WaitForTask, $tsw.Elapsed.TotalSeconds)
  }
}

# ---- stand down while a blocker process is running --------------------------
# 2026-08-15: this pass upgraded Microsoft.PowerShell while two Claude Code sessions sat in
# terminal pwsh tabs, and the MSI's Restart Manager closed both mid-conversation. Disabling
# RM from here measurably does not work (v0.11.0 passed MSIRESTARTMANAGERCONTROL=Disable via
# --custom; RM killed processes anyway; removed in v0.12.0) -- so the only real protection is
# to not run the installer while a session exists. Deferred, NOT failed: the engine hands
# these packages off again on its next run, and the alert tells the human what is waiting.
# The name list mirrors rebootBlockProcesses / Get-RebootBlockers (RebootState.ps1); this
# script stays self-contained by design, so keep the two defaults in sync by hand.
$blockersNow = @(Get-Process -Name @('claude') -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty ProcessName -Unique)
if ($blockersNow.Count -gt 0) {
  $blkList = $blockersNow -join ', '
  Write-Both 'INFO' ("DEFERRED: blocker process(es) running ({0}) -- upgrading {1} would let Restart Manager kill them. Nothing attempted; the next run retries." -f $blkList, ($IdList -join ', '))
  Write-Evt 2022 'Information' ("SunUp {0}: upgrade of {1} deferred -- {2} is running. Close or finish the session(s) and the next run will upgrade." -f $Label, ($IdList -join ', '), $blkList)
  Raise-Alert ("Upgrade of {0} deferred -- {1} is running. Finish or close the session(s); tomorrow's run retries." -f ($IdList -join ', '), $blkList)
  $payload = [ordered]@{
    finishedLocal  = (Get-Date).ToString('o')
    ids            = $IdList
    ok             = 0
    failed         = 0
    deferred       = $IdList
    rebootRequired = $false
    results        = @()
  }
  if (-not (Publish-Json $payload $SelfJson)) {
    Write-Both 'WARN' ("could not write {0} -- this pass's results will not reach the next engine run" -f $SelfJson)
  }
  if ($TaskName -and -not $NoTask) { try { & schtasks.exe /delete /tn $TaskName /f | Out-Null } catch {} }
  exit 0
}

$winget = Resolve-Winget
$results = @()
$rebootRequired = $false
$ok = 0; $fail = 0

if (-not $winget) {
  Write-Both 'ERROR' 'winget not found -- nothing upgraded'
  Write-Evt 2021 'Warning' 'SunUp self-host upgrade: winget not found.'
} else {
  # Exit codes that mean "installed OK, but a reboot is needed" (MSI 3010 + winget's own).
  # These hex literals compare correctly against $LASTEXITCODE as-is: PowerShell parses a
  # 32-bit hex literal by BIT PATTERN into a negative Int32 (0x8A150077 IS -1978335113),
  # exactly what GetExitCodeProcess hands back. Verified 2026-08-15; do not "fix" this with
  # unsigned conversions.
  $rebootCodes = @(3010, 0x8A150077, 0x8A150078, 0x8A150079)
  # "No applicable update found." Benign by construction: winget looked and had nothing to do,
  # usually because the OTHER scope's pass won the mutex race and upgraded first (measured
  # 2026-08-15: the user pass installed PowerShell 7.6.5 at 08:03:13, the SYSTEM pass then got
  # 0x8A15002B and recorded a FAILED that toasted the user with a failure that never happened).
  $benignCodes = @(0x8A15002B)

  # One SunUp winget pass at a time, machine-wide. The SYSTEM handoff and the interactive user's
  # handoff are this same script under two different principals, and winget refuses to run two
  # installs at once ("Another installation is already in progress"), which would surface as
  # spurious per-package failures. Global\ so it spans sessions; an AbandonedMutexException just
  # means the previous holder died, which is a lock we are free to take.
  # The DACL is explicit because the two holders are DIFFERENT PRINCIPALS: the SYSTEM handoff and the
  # interactive user's handoff are this same script run by each. A named mutex created with the
  # default constructor inherits the creator's token security, so a mutex created by SYSTEM can deny
  # the user's helper when it tries to open it -- and a swallowed failure there means both passes run
  # winget at once, which is the exact collision this lock exists to prevent. SYSTEM +
  # Administrators only: the user helper runs RunLevel Highest, and granting it more widely would let
  # any local account hold the lock and stall updates.
  $mutex = $null
  $haveMutex = $false
  try {
    $sec = New-Object System.Security.AccessControl.MutexSecurity
    foreach ($s in @('S-1-5-18', 'S-1-5-32-544')) {
      $sid = New-Object System.Security.Principal.SecurityIdentifier $s
      $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($sid,
        [System.Security.AccessControl.MutexRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow)))
    }
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, 'Global\SunUp-Winget', [ref]$createdNew, $sec)
  } catch {
    $mutex = $null
    Write-Both 'WARN' ("could not create the winget lock ({0}) -- this pass will not upgrade anything; see below" -f $_.Exception.Message)
  }
  if ($mutex) {
    try { $haveMutex = $mutex.WaitOne([timespan]::FromMinutes(60)) }
    catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
    catch { $haveMutex = $false }
  }
}

# No lock, no upgrade. Proceeding unserialized (what this did) undermines the only thing the lock is
# for: winget refuses to run two installs at once, so the concurrent pass fails with "Another
# installation is already in progress" and its packages go un-upgraded anyway -- with a spurious
# per-package failure to explain. A failed 60-minute wait means the other pass is STILL running, so a
# collision is the likely outcome, not a remote one. Reported as a failed handoff instead: the engine
# hands these packages off again on its next run, and the record says why this one did nothing.
if ($winget -and -not $haveMutex) {
  Write-Both 'ERROR' 'could not take the winget lock -- nothing upgraded this pass; the engine hands these packages off again next run'
  foreach ($id in $IdList) {
    $fail++
    $results += (New-Object psobject -Property ([ordered]@{
      id = $id; exitCode = '(no winget lock)'; ok = $false; durationSec = 0
    }))
  }
  if ($mutex) { try { $mutex.Dispose() } catch {} }
}
elseif ($winget) {
  try {
    foreach ($id in $IdList) {
      Write-Raw ("--- upgrading {0} ---" -f $id)
      $sw = [System.Diagnostics.Stopwatch]::StartNew()

      # RE-RESOLVE per package. Upgrading Microsoft.DesktopAppInstaller REPLACES the versioned
      # C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_<ver>_x64__8wekyb3d8bbwe folder
      # that this path points into -- and under SYSTEM that folder is the only path there is, since
      # there is no PATH shim. A path resolved before that upgrade is dangling for every package
      # after it.
      $winget   = Resolve-Winget
      $launched = $false
      $code     = 0
      $out      = @()

      # REBOOT=ReallySuppress stops the MSI restarting the box behind SunUp's back -- the engine owns
      # that decision. It only applies to MSI-family installers, so if winget rejects the argument
      # BEFORE installing anything, retry plain: a package left un-upgraded is worse than one
      # upgraded without the suppression. See Test-InstallStarted for what "before" means.
      if (-not $winget) {
        $out = @('winget.exe could not be resolved -- nothing attempted for this package')
      } else {
        try {
          $out = & $winget upgrade --id $id -e --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --custom 'REBOOT=ReallySuppress' 2>&1
          $code = $LASTEXITCODE
          $launched = $true
        } catch {
          # A dangling winget path raises CommandNotFoundException, which 2>&1 does NOT capture and
          # which leaves $LASTEXITCODE at the PREVIOUS package's value -- so this used to be recorded
          # as "upgraded (exit 0x00000000)" for a package winget never even saw, every run, forever.
          $out = @("launch failed: $($_.Exception.Message)")
        }
      }
      $txt = $out | Out-String

      if ($launched -and $code -ne 0 -and ($rebootCodes -notcontains $code) -and ($benignCodes -notcontains $code) -and -not (Test-InstallStarted $txt)) {
        Write-Both 'WARN' ("{0} exited 0x{1:X8} before installing anything -- retrying without --custom" -f $id, $code)
        Write-Raw '--- retry without installer args ---'
        try {
          $out2 = & $winget upgrade --id $id -e --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
          $code = $LASTEXITCODE
          $out  = @($out) + @('--- retry without installer args ---') + @($out2)
        } catch {
          $launched = $false
          $out = @($out) + @("retry launch failed: $($_.Exception.Message)")
        }
        $txt = $out | Out-String
      }
      $sw.Stop()

      Write-Raw $out
      if ($launched) { Write-Raw ("exit: 0x{0:X8}, {1}s" -f $code, [int]$sw.Elapsed.TotalSeconds) }
      else           { Write-Raw ("NOT LAUNCHED, {0}s" -f [int]$sw.Elapsed.TotalSeconds) }

      $isBenign = ($launched -and ($benignCodes -contains $code))
      $isOk = ($launched -and ($code -eq 0 -or ($rebootCodes -contains $code) -or $isBenign))
      if ($isOk) {
        $ok++
        if ($rebootCodes -contains $code) { $rebootRequired = $true }
        if ($isBenign) { Write-Both 'INFO' ("{0} already up to date (exit 0x{1:X8}) -- nothing to install; a peer pass likely upgraded it first" -f $id, $code) }
        else           { Write-Both 'INFO' ("{0} upgraded (exit 0x{1:X8}, {2}s)" -f $id, $code, [int]$sw.Elapsed.TotalSeconds) }
      } else {
        $fail++
        if ($launched) { Write-Both 'WARN' ("{0} FAILED (exit 0x{1:X8}) -- see {2}" -f $id, $code, $SelfLog) }
        else           { Write-Both 'WARN' ("{0} FAILED: winget could not be launched -- see {1}" -f $id, $SelfLog) }
      }
      $exitText = '(not launched)'
      if ($launched) { $exitText = ('0x{0:X8}' -f $code) }
      $results += (New-Object psobject -Property ([ordered]@{
        id         = $id
        exitCode   = $exitText
        ok         = $isOk
        durationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
      }))
    }
  } finally {
    if ($haveMutex) { try { $mutex.ReleaseMutex() } catch {} }
    if ($mutex) { try { $mutex.Dispose() } catch {} }
  }
}

$payload = [ordered]@{
  finishedLocal  = (Get-Date).ToString('o')
  ids            = $IdList
  ok             = $ok
  failed         = $fail
  rebootRequired = $rebootRequired
  results        = $results
}
if (-not (Publish-Json $payload $SelfJson)) {
  Write-Both 'WARN' ("could not write {0} -- this pass's results will not reach the next engine run" -f $SelfJson)
}

if ($fail -gt 0) {
  $m = "SunUp $Label upgrade: $ok ok, $fail failed ($($IdList -join ', ')). See $SelfLog"
  Write-Evt 2021 'Warning' $m
  Raise-Alert $m
} else {
  Write-Evt 2020 'Information' "SunUp $Label upgrade: $ok upgraded ($($IdList -join ', '))."
}
if ($rebootRequired) {
  # Recorded, not acted on. The next run's pending-reboot watchdog escalates it if it lingers.
  Write-Both 'INFO' 'a self-host package requires a reboot -- recorded; the engine owns the reboot decision.'
}

Write-Both 'INFO' ("done: {0} upgraded, {1} failed" -f $ok, $fail)

# Remove the one-shot task. Deleting a task while its own instance is running is permitted --
# the running instance finishes normally. Nothing to remove when launched directly (-NoTask).
if ($TaskName -and -not $NoTask) { try { & schtasks.exe /delete /tn $TaskName /f | Out-Null } catch {} }
exit ([int]($fail -gt 0))
