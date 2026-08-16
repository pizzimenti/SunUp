<#
RebootState.ps1 -- the single source of truth for "does this machine actually need a restart?",
and for every timestamp SunUp writes to or reads from disk.

Dot-sourced by the engine (SunUp.ps1), the tray (SunUp-Tray.ps1), the summary dialog
(Show-UpdateDialog.ps1), the restart toast (Show-RestartToast.ps1), the user pass (UserScope.ps1)
and the tests. Before v0.16.0 the engine and the tray each carried their OWN copy of a
`Test-PendingReboot` that returned $true on any non-empty PendingFileRenameOperations value. That is
not a reboot signal.

PFRO is nothing more than a work queue for smss.exe: "perform these file operations before anything
else loads." Windows Update genuinely uses it to swap in-use system files, which is why it became a
conventional reboot proxy -- but ANY application can call MoveFileEx(path, NULL,
MOVEFILE_DELAY_UNTIL_REBOOT) to have a file it cannot unlink deleted at next boot, and that has
nothing to do with servicing. On this box Claude Code (a Bun-compiled binary) unpacks a bundled Rust
audio addon into %TEMP% and registers exactly such a delete-on-boot minutes after startup. The
registry value is therefore essentially never empty here, so:
  * `rebootPending` was stuck true across every run,
  * `rebootPolicy=always` would have rebooted the box on a temp-file deletion, and
  * the stale-reboot watchdog fired on 2026-08-04 and stayed latched, on a machine that had in fact
    rebooted twice since (2026-08-08 and 2026-08-11).

So this file does two things a boolean could not:
  * it CLASSIFIES each PFRO pair rather than trusting the value's mere existence, and
  * it reports WHY, so a pending state can be explained in a log line, a tray tooltip or Status
    output instead of merely asserted. A misclassification is then visible rather than silent.

ASCII ONLY, and deliberately so (v0.17.0). Show-RestartToast.ps1 dot-sources this file and runs
under WINDOWS POWERSHELL 5.1, because the WinRT toast APIs do not project into pwsh 7. 5.1 reads a
BOM-less file as ANSI, so a single non-ASCII character corrupts the parse -- and this file had ten
em dashes and an ellipsis, one of them inside a double-quoted string on what was line 212, which
made 5.1 fail with six errors. Exactly the failure already documented for SelfHost.ps1. Enforced by
tests\Test-SunUp.ps1, which parses this file with the real 5.1 parser. Use -- and ... instead.

Deliberately NOT consulted: the ConfigMgr/SCCM client (root\ccm\ClientSDK). This box has no
management agent, and probing a missing WMI namespace costs seconds on every tray refresh. Add it
to $script:SunUpRebootKeys' sibling checks in Get-RebootState if that ever changes.
#>

# ---- timestamps: ONE reader, ONE writer -------------------------------------
# Every timestamp bug this project has had is one bug: ConvertFrom-Json silently hands you a
# [datetime], not the string you wrote, and every operation that expects a string then coerces it
# back through the CURRENT CULTURE -- which drops the timezone marker.
#
#   '{"runEndUtc":"2026-08-12T15:04:43.8905354Z"}' | ConvertFrom-Json   -> [datetime] Kind=Utc
#   "$($that.runEndUtc)"                                                -> "08/12/2026 15:04:43"
#   [datetime]::Parse(that, RoundtripKind)                              -> Kind=Unspecified
#   .ToUniversalTime()                                                  -> 22:04:43Z  (+7h, WRONG)
#
# That is not hypothetical. On 2026-08-12 it restarted this box three times in seventy minutes:
# Show-UpdateDialog.ps1 re-parsed runEndUtc exactly that way, so "has the box booted since the run
# finished?" was permanently false, so it armed a five-minute countdown at every single logon.
# v0.13.2 had already fixed this same class in the stamp path and written a changelog entry about
# it -- but only there. The engine got the fix; the consumer was never revisited.
#
# So the answer is not another guarded reader. It is three things at once:
#
#   1. ONE WRITER, and it never emits 'Z'. Get-SunUpTimestamp writes local-with-offset, which
#      round-trips CORRECTLY EVEN THROUGH THE BUGGY PARSE ("08/12/2026 08:04:43" re-read as local
#      is the instant it was written). This is the layer that matters most, because it is the only
#      one that makes an already-deployed, un-upgraded consumer right rather than seven hours wrong
#      -- and "the fix landed in the engine, the consumer was missed" is this project's documented
#      history four releases running. Make the wire format survive a bad reader.
#   2. INTEGERS for the two values that gate a restart. An [int64] cannot be coerced into a date by
#      anything. See Get-SunUpEpoch and Test-SameBoot.
#   3. ONE READER, total over every shape JSON can produce. ConvertTo-UtcTime is the only place in
#      the entire product allowed to call [datetime]::Parse -- asserted by the test suite.
#
# Deliberately NOT applied to history.jsonl, result.json or run.log: those are read by humans
# during an incident, and an epoch integer there would trade the thing that makes them useful for a
# safety property they do not need.

# A timestamp SunUp persisted always describes something that already happened, so a value in the
# future is corruption, not data -- specifically it is the +offset signature of the bug above.
# Clamping self-heals a lastrun.json that a previous version already damaged (an ingestCursor seven
# hours ahead would otherwise consume-unread every detached helper record written in that window).
# The tolerance absorbs ordinary clock jitter and a run that straddles an NTP correction.
$script:SunUpFutureTolerance = [TimeSpan]::FromMinutes(5)

# LastBootUpTime is not perfectly stable to the tick across queries -- a clock adjustment can shift
# it by a second or two within one boot. Two readings inside this window are the same boot.
$script:SunUpBootTolerance = 120

$script:SunUpEpochOrigin = New-Object datetime 1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)

# Normalize ANY shape a timestamp can arrive in to a UTC [datetime]; $null when it cannot be read.
#   [datetime]        <- what ConvertFrom-Json actually hands you. THE GUARD. Never re-parse it.
#   [DateTimeOffset]  <- unambiguous by construction
#   [int]/[long]      <- epoch seconds
#   string            <- parsed round-trip; an offset or Z is honoured exactly. A string with
#                        NEITHER is culture-formatted wreckage from the bug above; local is the
#                        right guess (it is how the dominant local-with-offset fields degrade) and
#                        the future-clamp catches the case where it was really UTC.
function ConvertTo-UtcTime {
  param($Value, [switch]$AllowFuture)
  if ($null -eq $Value -or "$Value" -eq '') { return $null }
  $utc = $null
  if ($Value -is [datetime]) {
    $utc = $Value.ToUniversalTime()
  } elseif ($Value -is [System.DateTimeOffset]) {
    $utc = $Value.UtcDateTime
  } elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
    try { $utc = $script:SunUpEpochOrigin.AddSeconds([double]$Value) } catch { return $null }
  } else {
    try {
      $p = [datetime]::Parse("$Value", $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
      if ($p.Kind -eq [System.DateTimeKind]::Unspecified) {
        $p = [datetime]::SpecifyKind($p, [System.DateTimeKind]::Local)
      }
      $utc = $p.ToUniversalTime()
    } catch { return $null }
  }
  if ($null -eq $utc) { return $null }
  if (-not $AllowFuture) {
    $now = (Get-Date).ToUniversalTime()
    if ($utc -gt $now.Add($script:SunUpFutureTolerance)) { return $now }
  }
  $utc
}

# THE canonical writer. Always local-with-offset, never 'Z', whatever it is handed -- so no caller
# can reintroduce the format that does not survive a careless read.
function Get-SunUpTimestamp {
  param($At)
  $d = $null
  if ($null -eq $At) { $d = Get-Date }
  elseif ($At -is [datetime]) { $d = $At }
  elseif ($At -is [System.DateTimeOffset]) { $d = $At.LocalDateTime }
  else { $u = ConvertTo-UtcTime $At; if ($null -eq $u) { return '' }; $d = $u }
  switch ($d.Kind) {
    ([System.DateTimeKind]::Utc)         { $d = $d.ToLocalTime() }
    ([System.DateTimeKind]::Unspecified) { $d = [datetime]::SpecifyKind($d, [System.DateTimeKind]::Local) }
  }
  $d.ToString('o')
}

# Epoch seconds, for the values that gate a restart. $null only when the input is unreadable.
function Get-SunUpEpoch {
  param($At)
  $utc = if ($null -eq $At) { (Get-Date).ToUniversalTime() } else { ConvertTo-UtcTime $At }
  if ($null -eq $utc) { return $null }
  [long][math]::Floor(($utc - $script:SunUpEpochOrigin).TotalSeconds)
}

# ---- boot identity ----------------------------------------------------------
# LastBootUpTime comes back Kind=Local, which is what a human-facing "came back up at" wants, so
# Get-BootLocal hands it over untouched -- no conversion is the point.
function Get-BootLocal {
  try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { $null }
}
function Get-BootUtc {
  $b = Get-BootLocal
  if ($null -eq $b) { return $null }
  $b.ToUniversalTime()
}
function Get-BootEpoch {
  $u = Get-BootUtc
  if ($null -eq $u) { return $null }
  [long][math]::Floor(($u - $script:SunUpEpochOrigin).TotalSeconds)
}

# "Is the box still on the boot it was on when this was recorded?"
#
# This is the comparison that decides whether a restart SunUp asked for has actually happened, and
# it is deliberately NOT a comparison of two clocks. Both sides are readings of the SAME counter,
# taken by SunUp itself, as integers: no parse, no culture, no offset, no DST, no second clock to
# disagree. Even if every timestamp on disk were mangled, this still answers correctly -- which is
# the whole point of not resting the restart decision on a timestamp again.
#
# $null (we cannot tell) reads as SAME boot, i.e. "the restart has not happened yet". That leaves a
# needed restart visible instead of silently retiring it, matching Test-BootedSince below.
function Test-SameBoot {
  param($RecordedEpoch, $CurrentEpoch)
  if ($null -eq $RecordedEpoch) { return $true }
  $cur = if ($null -eq $CurrentEpoch) { Get-BootEpoch } else { $CurrentEpoch }
  if ($null -eq $cur) { return $true }
  try { return ([math]::Abs([long]$cur - [long]$RecordedEpoch) -le $script:SunUpBootTolerance) }
  catch { return $true }
}

# ---- boot-relative helper ---------------------------------------------------
# "Has the box restarted since <instant>?" -- used to retire a reboot that a run asked for.
# Prefer Test-SameBoot where a recorded boot epoch exists; this is the answer for a bare timestamp.
# Returns $false when it cannot tell, which keeps a needed reboot visible rather than silently
# retiring it.
function Test-BootedSince {
  param($Utc)
  $t = ConvertTo-UtcTime $Utc
  if ($null -eq $t) { return $false }
  $boot = Get-BootUtc
  if ($null -eq $boot) { return $false }
  ($boot -gt $t)
}

# ---- authoritative registry signals -----------------------------------------
# Presence of the KEY is the signal for all of these -- none of them carry a meaningful value.
# `label` is the short form for a 127-char tray tooltip; `why` is the long form for logs/Status.
$script:SunUpRebootKeys = @(
  @{ key = 'cbs'
     path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
     label = 'Windows servicing'
     why = 'Component Based Servicing has a reboot pending' }
  @{ key = 'cbsInProgress'
     path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
     label = 'Windows servicing'
     why = 'Component Based Servicing is part-way through a reboot sequence' }
  @{ key = 'cbsPackages'
     path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
     label = 'Windows servicing'
     why = 'Component Based Servicing has packages waiting to be installed' }
  @{ key = 'windowsUpdate'
     path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
     label = 'Windows Update'
     why = 'Windows Update installed something that needs a restart' }
  @{ key = 'wuPostReboot'
     path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting'
     label = 'Windows Update'
     why = 'Windows Update has post-reboot reporting queued' }
)

# ---- PendingFileRenameOperations parsing ------------------------------------
# The value is a REG_MULTI_SZ of source/destination PAIRS. An empty destination means "delete the
# source at boot"; a non-empty one means "rename/replace into that path".
#
# Both halves can carry prefixes that are NOT part of the path:
#   \??\      NT object-manager prefix (and \\?\ is the Win32 long-path spelling of the same thing)
#   !         on the destination -- MOVEFILE_REPLACE_EXISTING
#   *  / *N   seen on real sources in the wild (the entry Claude Code leaves here reads
#             `*1\??\C:\Users\...\Temp\.<hash>-0.node`); strip it so the path can be classified
# Anything we cannot make sense of is left as-is and treated as significant further down.
function Expand-PfroPath {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
  $p = "$Raw".Trim()
  $p = [regex]::Replace($p, '^[!*]+\d*', '')
  $p = [regex]::Replace($p, '^(\\\?\?\\|\\\\\?\\)', '')
  $p
}

function ConvertFrom-PfroValue {
  param([string[]]$Value)
  $out = [System.Collections.Generic.List[object]]::new()
  if (-not $Value) { return @() }
  # Step by two. An odd-length value (a source with no destination element at all) is treated as a
  # delete, which is what smss.exe does with it.
  for ($i = 0; $i -lt $Value.Count; $i += 2) {
    $rawSrc = "$($Value[$i])"
    $rawDst = if ($i + 1 -lt $Value.Count) { "$($Value[$i + 1])" } else { '' }
    if ([string]::IsNullOrWhiteSpace($rawSrc)) { continue }   # REG_MULTI_SZ trailing null
    $out.Add([pscustomobject]@{
      Source      = Expand-PfroPath $rawSrc
      Destination = Expand-PfroPath $rawDst
      RawSource   = $rawSrc
      RawDest     = $rawDst
    })
  }
  @($out)
}

# Scratch locations whose contents are application housekeeping, never servicing payload.
# Matched by PATTERN, not against $env:TEMP: the engine runs as SYSTEM (whose TEMP is
# C:\Windows\TEMP) but the entries that matter here are usually under some *interactive* user's
# profile, which SYSTEM's environment knows nothing about.
function Test-PfroTempPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $p = $Path.Replace('/', '\')
  if ($p -match '(?i)^[a-z]:\\users\\[^\\]+\\appdata\\local\\temp\\')                    { return $true }
  if ($p -match '(?i)^[a-z]:\\users\\[^\\]+\\appdata\\local\\packages\\[^\\]+\\ac\\temp\\') { return $true }  # AppContainer temp
  if ($p -match '(?i)^[a-z]:\\windows\\(temp|serviceprofiles\\[^\\]+\\appdata\\local\\temp)\\') { return $true }
  if ($p -match '(?i)^[a-z]:\\temp\\')                                                   { return $true }
  $false
}

# Does this one pair represent work that a restart is genuinely required to complete?
# Fails OPEN on purpose: an unrecognised entry counts as significant. A spurious sunset icon costs a
# glance; a missed servicing reboot leaves the box half-patched.
function Test-PfroEntrySignificant {
  param($Entry)
  # A rename INTO a destination is a file being put in place -- that is what servicing looks like.
  if (-not [string]::IsNullOrWhiteSpace($Entry.Destination)) { return $true }
  # A pure delete out of a scratch directory is an app cleaning up after itself.
  if (Test-PfroTempPath $Entry.Source) { return $false }
  $true
}

function Get-PfroEntries {
  try {
    $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    ConvertFrom-PfroValue $v
  } catch { @() }
}

# ---- the restart record, and the decision it gates --------------------------
# notify\restart-state.json records that a restart was ISSUED, for which run, and which boot the
# machine was on when it was issued. It lives in notify\ because that is the directory the engine
# grants the interactive user Modify on, and the dialog and the 5.1 toast host both write it. It is
# a SEPARATE file from latest-updates.json on purpose: that one has three unlocked
# read-modify-write writers, and the one fact that has to survive a reboot does not belong in the
# file most likely to lose an update.
#
# Note what this file is NOT. It is a record of what happened, held somewhere the interactive user
# can write, so it must never be read as a statement of what anything is PERMITTED to do -- only as
# evidence about a restart, cross-checked against the boot counter, which no file can forge. Policy
# lives in config.json, which only an administrator can change.
#
# These live here, not in the dialog, because the toast host needs the identical answer. Two
# implementations of one question is the bug this release exists to remove -- it is what the dialog
# and the tray had, and the dialog's copy is what restarted the box three times.
function Get-RestartRecord {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return $null }
  try { Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

# Publish by rename, and report honestly whether it landed. The caller is required to treat $false
# as "do not restart" -- see the callers for why that is not optional.
function Save-RestartRecord {
  param([string]$Path, $Record)
  try {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp"
    ($Record | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
    $null = Get-Content $tmp -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json   # prove it is whole
    Move-Item -Path $tmp -Destination $Path -Force -ErrorAction Stop
    return (Test-Path $Path)
  } catch { return $false }
}

# Build the record a restart is about to be issued under. Read the boot epoch HERE, at the moment of
# issuing -- not from whatever the run armed minutes ago; it is the boot we are actually leaving
# that has to be recorded.
function New-RestartRecord {
  param([string]$RunStamp, [string]$RequestedBy, [string]$Trigger, [string]$Method, [string]$Version = '0.17.0')
  [ordered]@{
    schemaVersion      = 1
    runStamp           = "$RunStamp"
    requestedBy        = "$RequestedBy"
    trigger            = "$Trigger"
    outcome            = 'issued'
    executedLocal      = (Get-SunUpTimestamp)
    executedEpoch      = (Get-SunUpEpoch)
    bootAtRequestEpoch = (Get-BootEpoch)
    bootAtRequestLocal = (Get-SunUpTimestamp (Get-BootLocal))
    method             = "$Method"
    sunupVersion       = "$Version"
  }
}

# PURE. No CIM, no file I/O, no UI -- everything it needs is passed in, so the restart decision can
# be exercised headlessly. That is not tidiness: this decision has been wrong in production twice,
# and until v0.17.0 it was top-level script code inside a WPF file, which is why its only test was
# "the file parses".
#
# Modes:
#   countdown       a restart is expected and has not been issued -- the ONLY mode that can restart
#   postReboot      it was issued and the box has since come back
#   awaitingRestart it was issued and the box is STILL ON THE SAME BOOT: an aborted or blocked
#                   shutdown. Real, and previously indistinguishable from "restart needed" -- so it
#                   re-armed and tried again. Now it offers a manual button and retries nothing.
#   none            nothing outstanding
function Get-RestartDisplayState {
  param(
    $Data,                            # the notify payload
    $Record        = $null,           # restart-state.json, or $null
    $BootEpoch     = $null,           # current boot identity
    [bool]$BootedSinceRun = $false,   # Test-BootedSince($Data.runEnd), computed by the caller
    $BootLocal     = $null,           # display only; already Kind=Local from CIM
    [switch]$Demo
  )
  $out = [ordered]@{
    Mode = 'none'; CountdownSec = 0; ExecutedLocal = $null; BootedLocal = $BootLocal
    DowntimeSec = $null; Trigger = $null
  }
  $out.CountdownSec = if ($Data -and $Data.rebootCountdownSec -and [int]$Data.rebootCountdownSec -gt 0) { [int]$Data.rebootCountdownSec } else { 300 }
  if (-not $Data) { return [pscustomobject]$out }
  if ($Demo) { $out.Mode = 'countdown'; return [pscustomobject]$out }
  if (-not [bool]$Data.rebootRequired) { return [pscustomobject]$out }

  # A payload written by v0.16.0 or earlier has no runStamp, so no record can be tied to it and
  # there is NO WAY TO PROVE a restart was not already issued for it. It may therefore never arm a
  # countdown. The costs are wholly asymmetric: showing a summary when a restart is still needed
  # costs one more day of the stale-reboot nag; arming a countdown on an unprovable payload IS the
  # incident. This is also the upgrade path -- the degraded state lasts exactly one run cycle.
  $hasStamp = ($Data.PSObject.Properties.Name -contains 'runStamp') -and "$($Data.runStamp)"
  if (-not $hasStamp) {
    if ($BootedSinceRun) { $out.Mode = 'postReboot' }
    return [pscustomobject]$out
  }

  $sameRun = $Record -and ("$($Record.runStamp)" -eq "$($Data.runStamp)")
  $issued  = [bool]($sameRun -and "$($Record.outcome)" -eq 'issued')
  if ($issued) {
    $out.ExecutedLocal = $Record.executedLocal
    $out.Trigger       = "$($Record.trigger)"
    if (Test-SameBoot $Record.bootAtRequestEpoch $BootEpoch) {
      $out.Mode = 'awaitingRestart'
    } else {
      $out.Mode = 'postReboot'
      $ex = ConvertTo-UtcTime $Record.executedLocal
      $bk = ConvertTo-UtcTime $BootLocal
      if ($ex -and $bk -and $bk -gt $ex) { $out.DowntimeSec = [int]($bk - $ex).TotalSeconds }
    }
  } elseif ($BootedSinceRun) {
    $out.Mode = 'postReboot'     # a boot happened, whoever caused it; the requirement is satisfied
  } else {
    $out.Mode = 'countdown'
  }
  [pscustomobject]$out
}

# "9:09:45 AM" for something that happened today, with the day when it did not. This is the sentence
# a person reads after their machine restarted under them, not a log line. Always local -- the
# record stores an offset, and this is where that pays off. Empty string when unreadable, so a
# caller can decide what to say instead of printing a placeholder.
function Format-LocalStamp {
  param($Value)
  $u = ConvertTo-UtcTime $Value
  if ($null -eq $u) { return '' }
  $l = $u.ToLocalTime()
  if ($l.Date -eq (Get-Date).Date) { $l.ToString('h:mm:ss tt') } else { $l.ToString('ddd d MMM, h:mm:ss tt') }
}

# ---- servicing vs everything else -------------------------------------------
# Which Sources mean "Windows servicing has work outstanding that only a restart can finish", as
# opposed to a run signal, a staged rename, or a queued temp-file deletion.
#
# The engine asks this BEFORE running its Windows Update pass. An update that is installed but
# waiting on a restart is reported by the WU agent as NOT installed, so it gets offered again and
# reinstalled -- finished work, redone, which then manufactures a restart request. See the pre-flight
# block in SunUp.ps1 for the 2026-08-12 measurements.
#
# 'pendingRename' is deliberately NOT here. A Node/Electron app queuing a delete-on-boot for its own
# temp file must never suppress the update pass; that is the false positive v0.16.0 exists to
# disarm, and it is exactly what the 2026-08-11 run's pending state turned out to be.
# 'run' and 'handoff' are not here either: those describe work THIS engine just did, not a
# pre-existing hold.
$script:SunUpServicingSignals = @('cbs', 'cbsInProgress', 'cbsPackages', 'windowsUpdate', 'wuPostReboot')

function Get-ServicingSignals {
  param([string[]]$Sources)
  if (-not $Sources) { return @() }
  @($Sources | Where-Object { $script:SunUpServicingSignals -contains $_ })
}

# ---- what a restart actually buys you ---------------------------------------
# Reasons[] above says what fired, in SunUp's vocabulary. This says what it MEANS, in a normal
# person's. They are different jobs and neither substitutes for the other: "Component Based
# Servicing has a reboot pending" is precise and tells you nothing about whether it matters, and a
# notification asking someone to stop what they are doing has to answer "or else what?".
#
# Written to a rule: no CVE numbers, no KB numbers, no "servicing stack", no "mitigations". Say what
# is still running, what is still exposed, or what will not take effect -- in terms of the machine
# in front of the person reading it.
#
# Accuracy over drama. A Windows security update almost never makes a feature UNAVAILABLE until you
# restart; what it does is leave the old, vulnerable code running. Saying "X will stop working"
# would be easier to write and false, and a notification that overstates its case once gets ignored
# forever after. Where nothing is genuinely lost, the sentence says what is still exposed instead.
$script:SunUpConsequences = [ordered]@{
  cbs           = 'Windows has new system files staged but is still running the old ones. They can only be swapped in while the machine is starting up.'
  cbsInProgress = 'Windows is part-way through installing an update. It stays in that half-applied state until the machine restarts.'
  cbsPackages   = 'Windows has update packages waiting that can only be installed during startup.'
  windowsUpdate = 'The security fixes are installed but not switched on yet. Until the machine restarts it is still running the code they were meant to fix.'
  wuPostReboot  = 'Windows Update needs a restart to finish checking that the last update applied cleanly.'
  pendingRename = 'Files that were locked while in use are queued to be replaced during startup. Until then the old versions are the ones actually running.'
  run           = 'An update installed in this run could not finish while Windows was running, and said so itself.'
  handoff       = 'An update installed in the background could not finish while Windows was running, and no restart has happened since.'
  computerRename = "The computer's new name does not take effect until it restarts."
  domainJoin    = 'The staged domain join does not complete until the machine restarts.'
}

# Returns plain sentences for the signals that fired, in table order, deduplicated. Never empty when
# a restart is genuinely pending -- an unrecognised source still gets an honest generic line rather
# than a blank space, because "restart required" with no reason is what this exists to stop.
function Get-RebootConsequence {
  param([string[]]$Sources)
  $out = [System.Collections.Generic.List[string]]::new()
  if (-not $Sources -or @($Sources).Count -eq 0) { return @() }
  foreach ($k in $script:SunUpConsequences.Keys) {
    if ($Sources -contains $k) {
      $s = $script:SunUpConsequences[$k]
      if (-not $out.Contains($s)) { $out.Add($s) }
    }
  }
  if ($out.Count -eq 0) {
    $out.Add('Windows reported that it needs to restart to finish applying an update.')
  }
  @($out)
}

# ---- processes a restart must not interrupt ---------------------------------
# 2026-08-15: SunUp's 08:00 run upgraded PowerShell while two Claude Code sessions sat in
# terminal tabs; Restart Manager closed them mid-conversation. A reboot would have done the
# same, only worse -- so every UNATTENDED restart path (engine decision, toast countdown
# expiry, dialog countdown expiry) now asks this first. A user clicking "Restart now" is not
# unattended and is never blocked: the person who owns those sessions is the one clicking.
#
# Returns the DISPLAY NAMES of blocker processes currently running (empty array = clear to
# restart). $Names comes from config (rebootBlockProcesses) where config is loaded; callers
# without config use the default, which must therefore stay in sync with $DefaultConfig.
function Get-RebootBlockers {
  param([string[]]$Names = @('claude'))
  if (-not $Names -or @($Names).Count -eq 0) { return @() }
  @(Get-Process -Name $Names -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty ProcessName -Unique)
}

# ---- the verdict ------------------------------------------------------------
# Returns a structured state rather than a boolean:
#   Required   [bool]   a restart is genuinely outstanding
#   Sources    [string[]] signal keys that fired ('windowsUpdate', 'pendingRename', 'run', ...)
#   Labels     [string[]] deduplicated short labels, for a tooltip
#   Reasons    [string[]] full sentences, for logs and Status
#   Advisory   [string[]] signals seen and DISMISSED, so the noise is on the record
#
# $RunRequired     -- a component in the current run reported reboot=true (MSI 3010, winget's
#                     restart exit codes, a per-update WU RebootRequired). These set no OS flag at
#                     all, which is exactly why the OS registry alone was never a complete answer.
# $HandoffRequired -- a detached helper asked for one and no boot has happened since.
function Get-RebootState {
  param(
    [bool]$RunRequired     = $false,
    [bool]$HandoffRequired = $false
  )
  $sources  = [System.Collections.Generic.List[string]]::new()
  $labels   = [System.Collections.Generic.List[string]]::new()
  $reasons  = [System.Collections.Generic.List[string]]::new()
  $advisory = [System.Collections.Generic.List[string]]::new()

  foreach ($sig in $script:SunUpRebootKeys) {
    $hit = $false
    try { $hit = Test-Path $sig.path } catch { $hit = $false }
    if ($hit) {
      $sources.Add($sig.key); $reasons.Add($sig.why)
      if (-not $labels.Contains($sig.label)) { $labels.Add($sig.label) }
    }
  }

  # A rename queued for the machine account: the new name only takes effect at boot.
  try {
    $active  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
    $pendingN = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'       -Name ComputerName -ErrorAction Stop).ComputerName
    if ($active -and $pendingN -and ($active -ne $pendingN)) {
      $sources.Add('computerRename')
      if (-not $labels.Contains('Rename')) { $labels.Add('Rename') }
      $reasons.Add("A rename to '$pendingN' takes effect at the next restart (currently '$active')")
    }
  } catch { }

  # A domain join/leave staged by netdom or an unattend file.
  try {
    $nl = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -ErrorAction Stop
    $names = @($nl.PSObject.Properties.Name)
    if ($names -contains 'JoinDomain' -or $names -contains 'AvoidSpnSet') {
      $sources.Add('domainJoin')
      if (-not $labels.Contains('Domain join')) { $labels.Add('Domain join') }
      $reasons.Add('A domain join is staged and completes at the next restart')
    }
  } catch { }

  # PendingFileRenameOperations -- classified, not merely counted.
  $pfro = @(Get-PfroEntries)
  if ($pfro.Count -gt 0) {
    $significant = @($pfro | Where-Object { Test-PfroEntrySignificant $_ })
    if ($significant.Count -gt 0) {
      $sources.Add('pendingRename')
      if (-not $labels.Contains('File replacement')) { $labels.Add('File replacement') }
      $sample = ($significant | Select-Object -First 3 | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_.Destination)) { "delete $($_.Source)" } else { "$($_.Source) -> $($_.Destination)" } }) -join '; '
      $more = if ($significant.Count -gt 3) { " (+$($significant.Count - 3) more)" } else { '' }
      $reasons.Add("$($significant.Count) file operation(s) are queued for the next boot: $sample$more")
    }
    $dismissed = $pfro.Count - $significant.Count
    if ($dismissed -gt 0) {
      $advisory.Add("$dismissed queued file deletion(s) under a temp directory -- application cleanup, not a restart requirement")
    }
  }

  if ($RunRequired) {
    $sources.Add('run')
    if (-not $labels.Contains('Updates installed')) { $labels.Add('Updates installed') }
    $reasons.Add("An update installed in this run reported that it needs a restart")
  }
  if ($HandoffRequired) {
    $sources.Add('handoff')
    if (-not $labels.Contains('Updates installed')) { $labels.Add('Updates installed') }
    $reasons.Add('An update installed by a detached helper needs a restart and none has happened since')
  }

  [pscustomobject]@{
    Required   = ($sources.Count -gt 0)
    Sources    = @($sources)
    Labels     = @($labels)
    Reasons    = @($reasons)
    Advisory   = @($advisory)
    CheckedUtc = (Get-Date).ToUniversalTime()
  }
}
