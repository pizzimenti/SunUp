<#
Upgrades the winget packages the SYSTEM engine structurally cannot see.

WHY THIS EXISTS
---------------
The engine runs as SYSTEM. winget resolves installed packages per user, so a package registered
under HKCU is invisible to it — not skipped, not failed, simply absent from `winget upgrade`.
Measured on caldera 2026-07-28: SYSTEM's list and the interactive user's list were DISJOINT.

  SYSTEM sees : VCLibs x2 (excluded), Microsoft.PowerShell, winghostty, VS Code
  bradley sees: Deno, yt-dlp.FFmpeg, junegunn.fzf, BurntSushi.ripgrep.MSVC, Rufus.Rufus,
                Microsoft.Sysinternals.Suite, ElementLabs.LMStudio

All seven of the user's are HKCU-registered. Six of them match nothing in excludePattern, so they
were never a policy decision — they had simply never been updated by SunUp at all (ripgrep sat at
15.1.0 against 15.2.0). The seventh, LM Studio, IS excluded on purpose.

That distinction matters, because excludePattern's comment reasons that per-user apps "are HKCU so
SYSTEM never sees them" — treating invisibility as equivalent to exclusion. True for apps that
self-update or refuse to install while running (Claude, Spotify, Discord, Slack, Teams, LM Studio);
false for ordinary CLI tools. This script covers the second group and still honours the first.

HOW IT RUNS
-----------
As the INTERACTIVE USER (same principal as SunUp-Notify / SunUp-Tray: Interactive, RunLevel
Highest), started on demand by the engine at the end of a run. No new security posture — it
follows the pattern those two tasks already established.

It takes no arguments: like the notify dialog, it discovers what it needs from disk (the newest
run dir), so the task's action can stay fixed and be registered once by Install.ps1.

POLICY IS SHARED, DELIBERATELY
------------------------------
excludePattern comes from the same config.json the engine reads, so an app excluded from the
machine pass is excluded here too, and there is exactly one place to change it. selfHostPattern is
honoured as well: those packages own a runtime, so this pass does not upgrade them in-process — it
hands them to SelfHost.ps1, launched here as a detached Windows PowerShell 5.1 process. They cannot
go to the SYSTEM handoff, because what shows up in THIS list is HKCU-registered and SYSTEM cannot
see it at all; saying they were "left to the SYSTEM handoff" simply meant nobody upgraded them.

This script never reboots. The engine owns that decision and has already made it by the time this
runs; a reboot requirement found here is recorded in user-winget.json and folded into the next
engine run (Import-DetachedResults), which acts on it.

KNOWN LIMITATION: the summary dialog's payload is written by the engine BEFORE this runs, so
packages upgraded here cannot appear in that run's dialog. The next run ingests user-winget.json
and shows them in its own dialog and history.
#>
param(
  # Normally discovered (newest run dir). Overridable for testing.
  [string]$RunDir = ''
)

$ErrorActionPreference = 'Continue'

$Name       = 'SunUp'
$Root       = "C:\ProgramData\$Name"
$LogFile    = Join-Path $Root 'logs\sunup.log'
$RunsDir    = Join-Path $Root 'logs\runs'
$ConfigFile = Join-Path $Root 'config.json'
$EvtSource  = $Name

if (-not $RunDir) {
  $latest = Get-ChildItem $RunsDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
  if (-not $latest) { return }   # no run to attach to; nothing sensible to do
  $RunDir = $latest.FullName
}
$UserLog  = Join-Path $RunDir 'user-winget.log'
$UserJson = Join-Path $RunDir 'user-winget.json'

function Write-Both {
  param([string]$Level, [string]$Msg)
  $line = ('{0} [{1,-5}] userscope: {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Msg)
  try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
  try { Add-Content -Path $UserLog -Value $line -Encoding UTF8 } catch {}
}
function Write-Raw { param($Lines)
  try { Add-Content -Path $UserLog -Value ($Lines | Out-String) -Encoding UTF8 } catch {}
}
function Write-Evt { param([int]$Id, [string]$Type, [string]$Msg)
  try { Write-EventLog -LogName Application -Source $EvtSource -EventId $Id -EntryType $Type -Message $Msg -ErrorAction Stop } catch {}
}
# Publish so a reader only ever sees this file WHOLE. The engine ingests this record on its next run,
# and Set-Content truncates its destination before writing: a reader that catches the file mid-write
# gets invalid JSON, treats the record as unreadable, and this pass's upgrades, failures and reboot
# request are lost. Write to .tmp, prove it parses, then rename — the rename is the publish.
function Publish-Json { param($Object, [string]$Path)
  $tmp = "$Path.tmp"
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
function Raise-SysSentryAlert { param([string]$Msg)
  $f = 'C:\ProgramData\SysSentry\ALERTS.md'
  if (-not (Test-Path (Split-Path $f))) { return }
  try { Add-Content -Path $f -Value ('- {0} SunUp: {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm'), $Msg) -Encoding UTF8 } catch {}
}

# Parse winget's FIXED-WIDTH upgrade table by column position, taken from the header row.
# Deliberately a copy of the engine's Parse-WingetUpgrades rather than a shared import: this runs
# as a different user in a different process and must not depend on the engine being loadable.
#
# Do NOT be tempted to split on runs of 2+ spaces instead. winget pads each column to a fixed
# width, so any value that FILLS its column is followed by exactly one space and the naive split
# silently merges it with the next field. Measured against the real 2026-07-28 user-scope list, a
# split-based parser dropped 3 of 7 rows -- "Sysinternals Suite" and "LM Studio 0.4.16+2" fill the
# 18-char Name column, and yt-dlp's N-124716-... version fills the Version column. Worse, it failed
# by dropping rows, so the pass would have quietly upgraded a subset and reported success.
function Parse-Upgrades { param([string[]]$Lines)
  $sep = -1
  for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^\s*-{6,}') { $sep = $i; break } }
  if ($sep -lt 1) { return @() }
  $h = $Lines[$sep - 1]
  $iId = $h.IndexOf('Id'); $iVer = $h.IndexOf('Version'); $iAvail = $h.IndexOf('Available'); $iSrc = $h.IndexOf('Source')
  if ($iId -lt 0 -or $iVer -lt 0 -or $iAvail -lt 0) { return @() }
  $out = @()
  for ($i = $sep + 1; $i -lt $Lines.Count; $i++) {
    $ln = $Lines[$i]
    if ([string]::IsNullOrWhiteSpace($ln) -or $ln -match 'upgrades? available|package\(s\)|pinned') { continue }
    if ($ln.Length -lt $iAvail) { continue }
    $name = $ln.Substring(0, $iId).Trim()
    $id   = $ln.Substring($iId, $iVer - $iId).Trim()
    $old  = $ln.Substring($iVer, $iAvail - $iVer).Trim()
    $new  = if ($iSrc -gt $iAvail -and $ln.Length -ge $iSrc) { $ln.Substring($iAvail, $iSrc - $iAvail).Trim() } else { $ln.Substring($iAvail).Trim() }
    if ($id -and $old) { $out += [pscustomobject]@{ name = $name; id = $id; old = $old; new = $new } }
  }
  $out
}

# ---- config: SHARED policy, read from the engine's own config.json ----------
$excl = 'NVIDIA|GeForce|Claude|Anthropic|ElementLabs|LM ?Studio|Spotify|Discord|Slack|Teams|VCLibs'
$selfPat = 'Microsoft\.PowerShell|Microsoft\.DesktopAppInstaller'
$enabled = $true
# Test-Path + -ErrorAction Stop on purpose. Get-Content's "file not found" and "file in use" are
# NON-TERMINATING under $ErrorActionPreference='Continue', so the catch below never ran: $cfg was
# silently left $null, every check fell through to the built-in defaults, and an admin who set
# "userScope": false or "enabled": false had it ignored while the "could not read config" warning
# that was supposed to say so was never written. The engine's own Get-Config guards with Test-Path
# for exactly this reason, and the rest of the repo passes -ErrorAction Stop to Get-Content.
if (-not (Test-Path $ConfigFile)) {
  Write-Both 'WARN' "config not found at $ConfigFile - using built-in defaults"
} else {
  try {
    $cfg = Get-Content $ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $cfg -or -not $cfg.winget) { throw 'no winget section in config.json' }
    if ($cfg.winget.PSObject.Properties.Name -contains 'excludePattern' -and "$($cfg.winget.excludePattern)") { $excl = "$($cfg.winget.excludePattern)" }
    if ($cfg.winget.PSObject.Properties.Name -contains 'selfHostPattern' -and "$($cfg.winget.selfHostPattern)") { $selfPat = "$($cfg.winget.selfHostPattern)" }
    if ($cfg.winget.PSObject.Properties.Name -contains 'enabled') { $enabled = [bool]$cfg.winget.enabled }
    if ($cfg.winget.PSObject.Properties.Name -contains 'userScope') { $enabled = $enabled -and [bool]$cfg.winget.userScope }
  } catch { Write-Both 'WARN' "could not read config ($_) - using built-in defaults" }
}

if (-not $enabled) { Write-Both 'INFO' 'winget user-scope pass disabled in config - nothing to do'; return }

Write-Both 'INFO' "starting (user=$env:USERNAME, run dir $(Split-Path $RunDir -Leaf))"

$winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
if (-not $winget) {
  Write-Both 'ERROR' 'winget not found in this user context - nothing upgraded'
  Write-Evt 2031 'Warning' 'SunUp user-scope pass: winget not found.'
  return
}

$listOut  = & $winget upgrade --include-unknown --accept-source-agreements 2>&1
$listCode = $LASTEXITCODE
Write-Raw '--- available (user scope) ---'
Write-Raw $listOut
Write-Raw "list exit: 0x$(([int]$listCode).ToString('X8'))"

# A non-zero list exit that parses to zero rows must NOT masquerade as "up to date" - that bug is
# why the engine logs its own list exit code (v0.8.0).
if ($listCode -ne 0) {
  $m = "user-scope upgrade list failed (exit 0x$(([int]$listCode).ToString('X8'))) - nothing attempted"
  Write-Both 'WARN' $m
  Write-Evt 2031 'Warning' "SunUp user-scope pass: $m"
  return
}

$all = @(Parse-Upgrades $listOut)
$skipped = @($all | Where-Object { $_.name -match $excl -or $_.id -match $excl })
$self    = @($all | Where-Object { ($_.name -match $selfPat -or $_.id -match $selfPat) -and $skipped -notcontains $_ })
$pending = @($all | Where-Object {
  -not ($_.name -match $excl     -or $_.id -match $excl) -and
  -not ($_.name -match $selfPat  -or $_.id -match $selfPat)
})

if ($skipped.Count) { Write-Both 'INFO' "skipped $($skipped.Count) excluded package(s): $(($skipped | ForEach-Object { $_.id }) -join ', ')" }

# ---- self-hosting packages: a REAL handoff, not a claimed one ----------------
# These own the runtime this pass runs in (pwsh 7) or winget itself, so upgrading one here has
# Restart Manager shut 'PowerShell 7' down and kill this process mid-pass. They cannot be left to the
# SYSTEM handoff either: what lands here is HKCU-registered, which SYSTEM cannot see at all -- the
# whole premise of this script. Logging "left N self-hosting package(s) to the SYSTEM handoff" (what
# this used to do) meant nobody upgraded them, ever, while the log said they were taken care of.
# So hand them off the way the engine does: the same helper, run by WINDOWS POWERSHELL 5.1 (a
# separate install, outside Restart Manager's blast radius) as THIS user (so HKCU is visible),
# waiting for this process to exit first. It writes user-selfhost.json, which the next engine run
# folds into its own results.
if ($self.Count) {
  $selfIds = ($self | ForEach-Object { $_.id }) -join ', '
  $helper  = Join-Path $PSScriptRoot 'SelfHost.ps1'
  if (-not (Test-Path $helper)) {
    $m = "cannot hand off $($self.Count) self-hosting package(s) - helper missing at $helper : $selfIds"
    Write-Both 'WARN' $m; Write-Evt 2031 'Warning' "SunUp user-scope pass: $m"; Raise-SysSentryAlert $m
  } else {
    try {
      $ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
      $hArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Ids {1} -RunDir "{2}" -MainLog "{3}" -EvtSource "{4}" -Label user-selfhost -NoTask -WaitForPid {5} -WaitTimeoutSec 3600' -f `
               $helper, (($self | ForEach-Object { $_.id }) -join ','), $RunDir, $LogFile, $EvtSource, $PID
      # -PassThru and a short look afterwards: Start-Process only reports that the HOST launched.
      # SelfHost.ps1 begins with #Requires -RunAsAdministrator, so a non-elevated child exits
      # immediately, writes no user-selfhost.json, and this would otherwise log a successful handoff
      # for an upgrade nobody performed - the very shape this release exists to remove. On the happy
      # path the helper is still waiting for this process's PID, so it cannot have exited.
      $proc = Start-Process -FilePath $ps51 -ArgumentList $hArgs -WindowStyle Hidden -PassThru
      Start-Sleep -Seconds 3
      if ($proc -and $proc.HasExited) {
        $m = "self-host helper exited immediately (code $($proc.ExitCode)) - $selfIds NOT upgraded (SelfHost.ps1 requires elevation)"
        Write-Both 'WARN' $m; Write-Evt 2031 'Warning' "SunUp user-scope pass: $m"; Raise-SysSentryAlert $m
      } else {
        Write-Both 'INFO' "handed $($self.Count) self-hosting package(s) to a detached Windows PowerShell 5.1 helper (it upgrades them once this pass exits): $selfIds"
      }
    } catch {
      $m = "could not start the self-host helper for $selfIds - $_"
      Write-Both 'WARN' $m; Write-Evt 2031 'Warning' "SunUp user-scope pass: $m"; Raise-SysSentryAlert $m
    }
  }
}

if (-not $pending.Count) {
  Write-Both 'INFO' 'up to date - nothing to upgrade in user scope'
  [void](Publish-Json ([ordered]@{ finishedLocal=(Get-Date).ToString('o'); user=$env:USERNAME; ok=0; failed=0; skipped=$skipped.Count; rebootRequired=$false; results=@() }) $UserJson)
  Write-Evt 2030 'Information' 'SunUp user-scope pass: up to date.'
  return
}

$rebootCodes = @(3010, 0x8A150077, 0x8A150078, 0x8A150079)
$ok = 0; $fail = 0; $rebootRequired = $false; $results = @()

foreach ($p in $pending) {
  Write-Raw "--- upgrading $($p.id) ($($p.old) -> $($p.new)) ---"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $o    = & $winget upgrade --id $p.id -e --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
  $code = $LASTEXITCODE
  $sw.Stop()
  Write-Raw $o
  Write-Raw "exit: 0x$(([int]$code).ToString('X8')), $([int]$sw.Elapsed.TotalSeconds)s"

  $isOk = ($code -eq 0 -or $rebootCodes -contains $code)
  if ($isOk) {
    $ok++
    if ($rebootCodes -contains $code) { $rebootRequired = $true }
    Write-Both 'INFO' "$($p.id) $($p.old) -> $($p.new) ok ($([int]$sw.Elapsed.TotalSeconds)s)"
  } else {
    $fail++
    Write-Both 'WARN' "$($p.id) FAILED (exit 0x$(([int]$code).ToString('X8'))) - see user-winget.log"
  }
  $results += [ordered]@{ id=$p.id; name=$p.name; old=$p.old; new=$p.new; exitCode=('0x{0:X8}' -f [int]$code); ok=$isOk; durationSec=[math]::Round($sw.Elapsed.TotalSeconds,1) }
}

if (-not (Publish-Json ([ordered]@{
      finishedLocal  = (Get-Date).ToString('o')
      user           = $env:USERNAME
      ok             = $ok
      failed         = $fail
      skipped        = $skipped.Count
      rebootRequired = $rebootRequired
      results        = $results
    }) $UserJson)) {
  Write-Both 'WARN' "could not write $UserJson - this pass's results will not reach the next engine run"
}

if ($fail -gt 0) {
  $m = "SunUp user-scope pass: $ok upgraded, $fail failed. See $UserLog"
  Write-Evt 2031 'Warning' $m
  Raise-SysSentryAlert $m
} else {
  Write-Evt 2030 'Information' "SunUp user-scope pass: $ok upgraded, 0 failed."
}
if ($rebootRequired) { Write-Both 'INFO' 'a user-scope package requires a reboot - recorded; the engine owns the reboot decision.' }
Write-Both 'INFO' "done: $ok upgraded, $fail failed, $($skipped.Count) skipped"
