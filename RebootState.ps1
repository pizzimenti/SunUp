<#
RebootState.ps1 — the single source of truth for "does this machine actually need a restart?"

Dot-sourced by the engine (SunUp.ps1), the tray (SunUp-Tray.ps1) and the tests. Before v0.16.0 the
engine and the tray each carried their OWN copy of a `Test-PendingReboot` that returned $true on any
non-empty PendingFileRenameOperations value. That is not a reboot signal.

PFRO is nothing more than a work queue for smss.exe: "perform these file operations before anything
else loads." Windows Update genuinely uses it to swap in-use system files, which is why it became a
conventional reboot proxy — but ANY application can call MoveFileEx(path, NULL,
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

Deliberately NOT consulted: the ConfigMgr/SCCM client (root\ccm\ClientSDK). This box has no
management agent, and probing a missing WMI namespace costs seconds on every tray refresh. Add it
to $script:SunUpRebootKeys' sibling checks in Get-RebootState if that ever changes.
#>

# ---- authoritative registry signals -----------------------------------------
# Presence of the KEY is the signal for all of these — none of them carry a meaningful value.
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
#   !         on the destination — MOVEFILE_REPLACE_EXISTING
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
  # A rename INTO a destination is a file being put in place — that is what servicing looks like.
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

# ---- boot-relative helper ---------------------------------------------------
# "Has the box restarted since <UTC instant>?" — used to retire a reboot that a run asked for.
# Returns $false when it cannot tell, which keeps a needed reboot visible rather than silently
# retiring it.
function Test-BootedSince {
  param($Utc)
  if (-not $Utc) { return $false }
  try {
    $t = if ($Utc -is [datetime]) { $Utc.ToUniversalTime() }
         else { [datetime]::Parse("$Utc", $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
    $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime()
    return ($boot -gt $t)
  } catch { return $false }
}

# ---- the verdict ------------------------------------------------------------
# Returns a structured state rather than a boolean:
#   Required   [bool]   a restart is genuinely outstanding
#   Sources    [string[]] signal keys that fired ('windowsUpdate', 'pendingRename', 'run', …)
#   Labels     [string[]] deduplicated short labels, for a tooltip
#   Reasons    [string[]] full sentences, for logs and Status
#   Advisory   [string[]] signals seen and DISMISSED, so the noise is on the record
#
# $RunRequired     — a component in the current run reported reboot=true (MSI 3010, winget's restart
#                    exit codes, a per-update WU RebootRequired). These set no OS flag at all, which
#                    is exactly why the OS registry alone was never a complete answer.
# $HandoffRequired — a detached helper asked for one and no boot has happened since.
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

  # PendingFileRenameOperations — classified, not merely counted.
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
      $advisory.Add("$dismissed queued file deletion(s) under a temp directory — application cleanup, not a restart requirement")
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
