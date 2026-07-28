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
  [string]$TaskName   = 'SunUp-SelfHost',
  # PID of the engine process to wait for. 0 = do not wait.
  [int]$WaitForPid    = 0,
  [int]$WaitTimeoutSec = 300
)

$ErrorActionPreference = 'Continue'

$SelfLog = Join-Path $RunDir 'selfhost.log'
$SelfJson = Join-Path $RunDir 'selfhost.json'

$IdList = @($Ids -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Write-Both {
  param([string]$Level, [string]$Msg)
  $line = ('{0} [{1,-5}] selfhost: {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Msg)
  try { Add-Content -Path $MainLog -Value $line -Encoding UTF8 } catch {}
  try { Add-Content -Path $SelfLog -Value $line -Encoding UTF8 } catch {}
}
function Write-Raw {
  param($Lines)
  try { Add-Content -Path $SelfLog -Value ($Lines | Out-String) -Encoding UTF8 } catch {}
}
function Write-Evt {
  param([int]$Id, [string]$Type, [string]$Msg)
  try { Write-EventLog -LogName Application -Source $EvtSource -EventId $Id -EntryType $Type -Message $Msg -ErrorAction Stop } catch {}
}
function Raise-SysSentryAlert {
  param([string]$Msg)
  $f = 'C:\ProgramData\SysSentry\ALERTS.md'
  if (-not (Test-Path (Split-Path $f))) { return }
  try { Add-Content -Path $f -Value ('- {0} SunUp: {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm'), $Msg) -Encoding UTF8 } catch {}
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

$winget = Resolve-Winget
$results = @()
$rebootRequired = $false
$ok = 0; $fail = 0

if (-not $winget) {
  Write-Both 'ERROR' 'winget not found -- nothing upgraded'
  Write-Evt 2021 'Warning' 'SunUp self-host upgrade: winget not found.'
} else {
  # Exit codes that mean "installed OK, but a reboot is needed" (MSI 3010 + winget's own).
  $rebootCodes = @(3010, 0x8A150077, 0x8A150078, 0x8A150079)

  foreach ($id in $IdList) {
    Write-Raw ("--- upgrading {0} ---" -f $id)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # REBOOT=ReallySuppress stops the MSI restarting the box behind SunUp's back -- the engine owns
    # that decision. It only applies to MSI-family installers, so if winget rejects the argument
    # BEFORE installing anything, retry plain: a package left un-upgraded is worse than one
    # upgraded without the suppression. ("Starting package install" = install work began; a retry
    # then would rerun a partial install, so we don't.)
    $out  = & $winget upgrade --id $id -e --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --custom 'REBOOT=ReallySuppress' 2>&1
    $code = $LASTEXITCODE
    $txt  = $out | Out-String
    if ($code -ne 0 -and ($rebootCodes -notcontains $code) -and ($txt -notmatch 'Starting package install')) {
      Write-Both 'WARN' ("{0} exited 0x{1:X8} before installing anything -- retrying without --custom" -f $id, $code)
      Write-Raw '--- retry without installer args ---'
      $out2 = & $winget upgrade --id $id -e --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
      $code = $LASTEXITCODE
      $out  = @($out) + @('--- retry without installer args ---') + @($out2)
      $txt  = $out | Out-String
    }
    $sw.Stop()

    Write-Raw $out
    Write-Raw ("exit: 0x{0:X8}, {1}s" -f $code, [int]$sw.Elapsed.TotalSeconds)

    $isOk = ($code -eq 0 -or ($rebootCodes -contains $code))
    if ($isOk) {
      $ok++
      if ($rebootCodes -contains $code) { $rebootRequired = $true }
      Write-Both 'INFO' ("{0} upgraded (exit 0x{1:X8}, {2}s)" -f $id, $code, [int]$sw.Elapsed.TotalSeconds)
    } else {
      $fail++
      Write-Both 'WARN' ("{0} FAILED (exit 0x{1:X8}) -- see selfhost.log" -f $id, $code)
    }
    $results += (New-Object psobject -Property ([ordered]@{
      id         = $id
      exitCode   = ('0x{0:X8}' -f $code)
      ok         = $isOk
      durationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }))
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
try { $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $SelfJson -Encoding UTF8 } catch {
  Write-Both 'WARN' "could not write selfhost.json: $_"
}

if ($fail -gt 0) {
  $m = "SunUp self-host upgrade: $ok ok, $fail failed ($($IdList -join ', ')). See $SelfLog"
  Write-Evt 2021 'Warning' $m
  Raise-SysSentryAlert $m
} else {
  Write-Evt 2020 'Information' "SunUp self-host upgrade: $ok upgraded ($($IdList -join ', '))."
}
if ($rebootRequired) {
  # Recorded, not acted on. The next run's pending-reboot watchdog escalates it if it lingers.
  Write-Both 'INFO' 'a self-host package requires a reboot -- recorded; the engine owns the reboot decision.'
}

Write-Both 'INFO' ("done: {0} upgraded, {1} failed" -f $ok, $fail)

# Remove the one-shot task. Deleting a task while its own instance is running is permitted --
# the running instance finishes normally.
try { & schtasks.exe /delete /tn $TaskName /f | Out-Null } catch {}
exit ([int]($fail -gt 0))
