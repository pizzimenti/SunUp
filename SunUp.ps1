#Requires -RunAsAdministrator
<#
SunUp — caldera's own daily update routine (replaces flaky Windows Update timing).
"SunUp": it runs at dawn (~08:00) so you start the day with fresh updates — and keeps
the "up" of Update/Upgrade. (Renamed from AutoUpdate in v0.5.0.)

Runs as SYSTEM via three Task Scheduler triggers (all on the SunUp task),
de-duplicated by a per-day stamp so the box updates exactly once per calendar day:
  * Daily 08:00  (only if the box is awake — the trigger never wakes it)
  * Boot   + 1h  (covers a cold boot where yesterday's run was missed)
  * Resume + 1h  (Power-Troubleshooter ID 1 — covers wake-from-sleep)
Whichever fires first does the work; the rest see the stamp and no-op.

Covers (config-toggled): Microsoft Defender signatures, Windows/Microsoft Update,
winget package upgrades, and PowerShell modules. One coordinated reboot at the end if
anything needs it. Nothing here is vendor- or hardware-specific: every component ships
with Windows or with winget, so this runs on any Windows box. (v0.14.0 removed the Dell
Command Update integration — see the CHANGELOG for why.)

LOGGING (the point of v0.2.0 — three tiers so failures are trivial to find):
  C:\ProgramData\SunUp\
    logs\sunup.log                   curated rolling timeline (rotated at 5MB x5)
    logs\history.jsonl               one compact JSON line per run (queryable trail)
    logs\runs\<yyyy-MM-dd_HHmmss>\   isolated per-run dir, kept for last 30 runs:
        run.log                        this run's curated timeline
        transcript.log                 full Start-Transcript capture (belt + suspenders)
        <component>.log                RAW output of each tool (defender/windowsupdate/
                                       winget/psmodules)
        result.json                    structured per-component result for this run
        running.json                   liveness marker (PID + process start) while the run is in
                                       flight; deleted once result.json is written
        incomplete.json                ONLY if the run was killed before writing result.json —
                                       written by the NEXT run when it reports the crash (evt 2011)
        user-winget.log/.json          ONLY if the per-user pass ran — written AFTER this run ends,
                                       by UserScope.ps1 as the interactive user (SYSTEM cannot see
                                       HKCU-registered packages at all)
        selfhost.log / selfhost.json   ONLY if self-hosting packages (PowerShell, winget itself)
                                       were upgraded — written AFTER this run ends, by SelfHost.ps1
                                       under Windows PowerShell 5.1; see its header for why
  Plus Application event log (source SunUp) + SysSentry ALERTS.md on failure.

Query: Status.ps1, or  SunUp.ps1 -Mode Errors  /  -Mode Tail.
Companion to ProcWatch (realtime CPU) and SysSentry (security drift).
#>
param(
  # Run = do the update; Status = overview; Errors = last failures + log pointers; Tail = last run.log tail.
  [ValidateSet('Run','Status','Errors','Tail')][string]$Mode = 'Run',
  # Bypass the once-per-day stamp (manual on-demand run / re-run after a failure).
  [switch]$Force
)

$ErrorActionPreference = 'Continue'
$script:Version = '0.16.0'

# One name to rule them all — every path, task name, event source, and the dialog title
# derive from $Name, so a future rename is a one-line change (and a half-rename is impossible).
$Name          = 'SunUp'
$TaskName      = $Name                 # SYSTEM engine task
$NotifyTask    = "$Name-Notify"        # interactive dialog task
$SelfHostTask  = "$Name-SelfHost"      # one-shot task for packages that own the engine's own runtime
$UserTask      = "$Name-User"          # interactive task for per-user (HKCU) packages SYSTEM can't see
$Root          = "C:\ProgramData\$Name"
$LogDir        = Join-Path $Root 'logs'
$LogFile       = Join-Path $LogDir ("{0}.log" -f $Name.ToLower())
$HistoryFile   = Join-Path $LogDir 'history.jsonl'
$RunsDir       = Join-Path $LogDir 'runs'
$ReportFile    = Join-Path $Root 'REPORT.md'
$ConfigFile    = Join-Path $Root 'config.json'
$StampFile     = Join-Path $Root 'lastrun.json'
$PSModStamp    = Join-Path $Root 'psmodules-lastrun.json'       # psModules runs weekly, not daily
$NotifyDir     = Join-Path $Root 'notify'                       # user-writable (Install grants Modify)
$NotifyPayload = Join-Path $NotifyDir 'latest-updates.json'     # drives the dialog; carries pendingShow
$EvtSource     = $Name
$SysSentryAlerts = 'C:\ProgramData\SysSentry\ALERTS.md'

$script:RunDir = $null   # set in Run mode once we create the per-run dir
$script:RunLog = $null
$script:SelfHostPending = @()   # self-hosting packages Comp-Winget handed off (see the end of Run mode)

# OEM update policy, resolved in Run mode. Defaults to "block nothing" so every component can read it
# unconditionally — and so a missing VendorProfiles.ps1 degrades to today's behaviour rather than to
# an exception mid-run. Resolve-VendorPolicy reports the degradation; it is never silent.
$script:VendorPolicy = @{ block = $false; vendor = $null; wuTitle = ''; winget = ''; note = '' }
$VendorProfileScript = Join-Path $PSScriptRoot 'VendorProfiles.ps1'
if (Test-Path $VendorProfileScript) { . $VendorProfileScript }

# Reboot detection, shared verbatim with the tray so the two can never disagree about whether this
# box needs restarting (before v0.16.0 they each had their own copy, and both were wrong the same
# way). See RebootState.ps1 for why a bare PendingFileRenameOperations check is not a reboot signal.
$RebootStateScript = Join-Path $PSScriptRoot 'RebootState.ps1'
if (Test-Path $RebootStateScript) { . $RebootStateScript }
else {
  # Degraded, not fatal — same principle as VendorProfiles above: a partially-updated bin must not
  # take down a whole run. The fallback keeps only the signals that need no classification, so it
  # errs toward under-reporting rather than resurrecting the temp-file false positive.
  function Get-RebootState {
    param([bool]$RunRequired = $false, [bool]$HandoffRequired = $false)
    $src = [System.Collections.Generic.List[string]]::new()
    foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                   'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
      if (Test-Path $p) { $src.Add('degraded') ; break }
    }
    if ($RunRequired)     { $src.Add('run') }
    if ($HandoffRequired) { $src.Add('handoff') }
    [pscustomobject]@{ Required = ($src.Count -gt 0); Sources = @($src); Labels = @('Restart needed')
                       Reasons = @('RebootState.ps1 is missing — reduced detection'); Advisory = @()
                       CheckedUtc = (Get-Date).ToUniversalTime() }
  }
}

# ---- config -----------------------------------------------------------------
$DefaultConfig = [ordered]@{
  # ifRequired = reboot only when a component THIS run actually reported reboot=true (the smart default);
  # always = reboot on any OS-level pending flag (blunt — a PnP/driver PendingFileRename trips it);
  # never = never auto-reboot, just flag a genuine pending state for a human.
  rebootPolicy       = 'ifRequired'
  rebootDelaySeconds = 120           # headless (no user logged in) restart grace
  # Watchdog for the ifRequired blind spot: if an OS reboot flag stays pending across runs without
  # any run requiring it, alert once after this many days so a genuinely-needed reboot can't sit
  # forever unnoticed. 0 disables. (Under rebootPolicy=always this never triggers — the flag clears.)
  pendingRebootAlertDays = 3
  rebootGraceInteractiveSec = 300    # countdown the dialog shows when a user IS logged in
  keepRuns           = 30            # how many per-run log dirs to retain
  # Win11 summary dialog after a run. The dialog also lists the past `historyDays` of updates
  # (greyed out, below the current run); historyCollapse keeps only the latest per package so
  # daily Defender-signature bumps don't flood the list.
  notify             = [ordered]@{ enabled = $true; historyDays = 30; historyCollapse = $true; historyMaxRows = 500 }
  # OEM driver/firmware/utility updates, on whatever machine this happens to be.
  #   allow (default) — no change; the OEM's updates arrive like any other.
  #   block           — identify this machine's OEM at run time (see VendorProfiles.ps1) and exclude
  #                     its updates from BOTH delivering paths: Windows Update titles and winget ids.
  # Deliberately not "run the OEM's own updater": v0.14.0 deleted that for Dell after it delivered
  # nothing in 34 runs while carrying the project's most security-sensitive code.
  vendorUpdates      = 'allow'
  windowsUpdate      = [ordered]@{ enabled = $true; notTitle = 'NVIDIA' }
  # Skip pinned drivers, self-updating Claude, load-bearing per-user/Electron apps whose uninstaller
  # refuses to run while the app is open (LM Studio :1234 API, Spotify, etc.), and UWP *framework*
  # packages (VCLibs) that winget can't deploy — they fail 0x8A15005C "extract" every run and are
  # serviced by the Store/dependent apps, not winget, so attempting them is pure noise.
  # selfHostPattern: packages that own the process SunUp itself is running in. Upgrading one of these
  # has Windows Installer's Restart Manager terminate the engine mid-run. Since v0.12.0 they are not
  # upgraded by the engine at all — they are handed to SelfHost.ps1, run by a one-shot task under
  # Windows PowerShell 5.1 after the engine exits. See Comp-Winget and SelfHost.ps1's header.
  # selfHostInstallerArgs is RETAINED but UNUSED: v0.11.0 passed it via winget's --custom to disable
  # Restart Manager and it demonstrably did not work (2026-07-28: RM ran and killed the engine
  # anyway). Kept only so an existing config.json carrying it still loads.
  # userScope: run the per-user (HKCU) pass via SunUp-User. SHARES excludePattern with this pass on
  # purpose — one policy, one place to change it. Set false to run machine scope only.
  winget             = [ordered]@{
    enabled = $true; pinIds = @(); userScope = $true
    excludePattern        = 'NVIDIA|GeForce|Claude|Anthropic|ElementLabs|LM ?Studio|Spotify|Discord|Slack|Teams|VCLibs'
    selfHostPattern       = 'Microsoft\.PowerShell|Microsoft\.DesktopAppInstaller'
    selfHostInstallerArgs = 'MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress'
  }
  defender           = [ordered]@{ enabled = $true }
  psModules          = [ordered]@{ enabled = $true; everyDays = 7 }   # PSGallery modules: weekly, not daily (slow + rarely changes)
  pip                = [ordered]@{ enabled = $false }
  npm                = [ordered]@{ enabled = $false }
}

function Get-Config {
  # Start from defaults, then overlay the file (2 levels deep) so a config written by an
  # older version still resolves keys added later (notify, excludePattern, keepRuns, …).
  $cfg = $DefaultConfig | ConvertTo-Json -Depth 6 | ConvertFrom-Json
  if (Test-Path $ConfigFile) {
    try {
      $file = Get-Content $ConfigFile -Raw | ConvertFrom-Json
      foreach ($p in $file.PSObject.Properties) {
        if ($p.Value -is [psobject] -and ($cfg.PSObject.Properties.Name -contains $p.Name) -and ($cfg.$($p.Name) -is [psobject])) {
          foreach ($sp in $p.Value.PSObject.Properties) { $cfg.$($p.Name) | Add-Member -NotePropertyName $sp.Name -NotePropertyValue $sp.Value -Force }
        } else {
          $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
      }
    } catch { Write-Log WARN "config.json unreadable ($_), using defaults" }
  }
  $cfg
}

# ---- logging ----------------------------------------------------------------
function Rotate-Log { param($Path, $MaxBytes = 5MB, $Keep = 5)
  if ((Test-Path $Path) -and (Get-Item $Path).Length -gt $MaxBytes) {
    for ($i = $Keep; $i -ge 1; $i--) {
      $src = if ($i -eq 1) { $Path } else { "$Path.$($i-1)" }
      if (Test-Path $src) { Move-Item $src "$Path.$i" -Force }
    }
  }
}

function Write-Log { param($Level, $Msg)
  $line = "{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}" -f (Get-Date), $Level, $Msg
  try { Add-Content -Path $LogFile -Value $line } catch {}
  if ($script:RunLog) { try { Add-Content -Path $script:RunLog -Value $line } catch {} }
  if ($Mode -ne 'Run') { Write-Host $line }
}

function Write-Evt { param([int]$Id, [string]$Type = 'Information', [string]$Msg)
  try { Write-EventLog -LogName Application -Source $EvtSource -EventId $Id -EntryType $Type -Message $Msg -ErrorAction Stop } catch {}
}

# Raw tool output goes to a per-component file inside the run dir.
function Get-CompLog { param($Name) Join-Path $script:RunDir "$Name.log" }
function Write-CompLog { param($Name, $Lines)
  $p = Get-CompLog $Name
  try { ($Lines | Out-String) | Add-Content -Path $p } catch {}
}

$script:Report = [System.Collections.Generic.List[string]]::new()
function Add-Report { param($Msg) $script:Report.Add($Msg) }

# Per-item updates that actually changed something — feeds the Win11 summary dialog.
$script:Updates = [System.Collections.Generic.List[object]]::new()
function Add-Update { param($Name, $Source, $Old, $New, $DurationSec, $SizeMB)
  $script:Updates.Add([ordered]@{ name=$Name; source=$Source; old=$Old; new=$New; durationSec=$DurationSec; sizeMB=$SizeMB })
}

# Is a real user logged into an interactive desktop? Decides who owns the reboot
# countdown: the interactive dialog (user present) vs. the headless engine (nobody to ask).
function Test-InteractiveUser {
  @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object SessionId -gt 0).Count -gt 0
}
function Flush-Report {
  if ($script:Report.Count -eq 0) { return }
  $header = "## Run $((Get-Date).ToString('yyyy-MM-dd HH:mm')) — $Name v$script:Version (log: $([IO.Path]::GetFileName($script:RunDir)))"
  @('', $header) + $script:Report | Add-Content $ReportFile
  $all = @(Get-Content $ReportFile)
  if ($all.Count -gt 900) { ($all[0..4] + '_…older entries trimmed…_' + $all[-850..-1]) | Set-Content $ReportFile }
}

# ---- crashed-run detection --------------------------------------------------
# A run killed mid-flight (its host process terminated, power loss, a hard reset) is otherwise
# COMPLETELY SILENT: every alert path — result.json, history.jsonl, events 2001/2010, the SysSentry
# echo, the summary dialog — lives after the component loop, and lastrun.json is never stamped, so
# the next run just looks like a normal first-run-of-the-day. The 2026-07-22 run died that way
# (Restart Manager killed the engine during winget's own PowerShell 7 upgrade) and nothing reported
# it for five days. A dead run leaves a fingerprint: a run dir with run.log but no result.json.
# Flag each one ONCE (incomplete.json marks it handled) and name the last thing it logged, so the
# alert says where it stopped.
#
# "No result.json" alone is NOT proof of death — a run still in progress looks identical. The task is
# MultipleInstances=IgnoreNew, but that only serializes TASK-launched runs: the documented
# `SunUp.ps1 -Mode Run -Force` is a standalone process the scheduler never sees, so a manual run and
# a scheduled one really can overlap. Every run therefore drops a running.json liveness marker
# (PID + that process's start time, since PIDs get recycled) which Test-RunAlive checks before
# anything is called dead. A dir with no marker predates v0.10.0 or lost the race to write it —
# either way its owner is long gone, so it still counts as crashed.
# A run dir must belong to exactly ONE process. The stamp has second resolution, so a scheduled run
# and a manual `-Mode Run -Force` starting in the same second would otherwise be handed the same dir:
# interleaved logs, one running.json overwriting the other, and whichever finished first writing a
# result.json that makes the dir look complete even if its peer is killed later — the peer's crash
# would never be reported. So claim the dir by CREATING it: New-Item without -Force fails when it
# already exists, which makes the claim atomic against a peer racing us, and we fall back to a
# PID-qualified name (unique by definition) and then to a counter.
# Publish a JSON file so readers only ever see it WHOLE: serialize and parse-verify into a temp file,
# then rename over the destination. Every JSON file this engine writes carries meaning by its mere
# presence — result.json says "this run finished", running.json says "this process owns this run" —
# and Set-Content truncates its destination before writing, so a kill or I/O error partway through
# would leave a half-file that still satisfies Test-Path and lies to whoever reads it next. The
# rename is the publish. -ErrorAction Stop throughout, because $ErrorActionPreference is 'Continue'
# and a quiet non-terminating failure here would be reported as success.
# Returns $true only when the destination really exists afterwards.
function Publish-JsonFile { param($Object, [string]$Path)
  $tmp = "$Path.tmp"
  try {
    ($Object | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -ErrorAction Stop
    $null = Get-Content $tmp -Raw -ErrorAction Stop | ConvertFrom-Json    # prove it is complete and parseable
    Move-Item -Path $tmp -Destination $Path -Force -ErrorAction Stop
    return (Test-Path $Path)
  } catch {
    Write-Log ERROR "could not publish $([IO.Path]::GetFileName($Path)): $($_.Exception.Message)"
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $false
  }
}

function New-RunDirectory { param([string]$Base, [string]$Root)
  if (-not $Root) { $Root = $RunsDir }
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $candidates = @($Base, "${Base}_$PID") + (2..20 | ForEach-Object { "${Base}_${PID}_$_" })
  foreach ($c in $candidates) {
    try { return (New-Item -ItemType Directory -Path (Join-Path $Root $c) -ErrorAction Stop).FullName } catch { }
  }
  # Every candidate collided, which should be impossible — share the dir rather than skip the run.
  $p = Join-Path $Root $Base; New-Item -ItemType Directory -Force -Path $p | Out-Null; $p
}

function Test-RunAlive { param([string]$Dir)
  $marker = Join-Path $Dir 'running.json'
  if (-not (Test-Path $marker)) { return $false }
  try { $m = Get-Content $marker -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return $false }
  if (-not $m.pid) { return $false }
  $p = Get-Process -Id ([int]$m.pid) -ErrorAction SilentlyContinue
  if (-not $p) { return $false }                                             # owner is gone
  if ($m.processName -and "$($p.ProcessName)" -ne "$($m.processName)") { return $false }   # PID recycled
  try {
    if ($m.processStartUtc) {
      $claimed = [datetime]::Parse("$($m.processStartUtc)", $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
      # Same PID, same image, but started at a different moment = a recycled PID, not our run.
      if (($claimed - $p.StartTime.ToUniversalTime()).Duration().TotalSeconds -gt 2) { return $false }
    }
  } catch { }   # start time unreadable: PID and image still match, so assume ALIVE — never cry crash on a live peer
  $true
}

function Report-CrashedRuns {
  if (-not (Test-Path $RunsDir)) { return }
  $dirs = @(Get-ChildItem $RunsDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $script:RunDir } | Sort-Object Name)
  foreach ($d in $dirs) {
    $resultPath = Join-Path $d.FullName 'result.json'
    if (Test-Path $resultPath) { continue }                             # finished normally
    $marker = Join-Path $d.FullName 'incomplete.json'
    $stale  = $false
    # A marker means one of three things, and they must not be conflated: a COMPLETED report
    # (reported=true — nothing more to do), a report a peer is making RIGHT NOW (recent claim, leave
    # it alone), or an ABANDONED claim from a scanner that was itself killed between claiming and
    # reporting. The last one used to suppress the crash forever — the very failure mode this feature
    # exists to prevent, applied to itself — so a stale unreported claim is retaken after
    # $ClaimStaleMinutes. Worst case that re-reports a crash whose first report died in a millisecond
    # window: at-least-once beats never.
    $ClaimStaleMinutes = 15
    if (Test-Path $marker) {
      $reported = $false
      try { $reported = [bool]((Get-Content $marker -Raw -ErrorAction Stop | ConvertFrom-Json).reported) } catch { }
      if ($reported) { continue }
      $ageMin = try { ((Get-Date) - (Get-Item $marker).LastWriteTime).TotalMinutes } catch { 0 }
      if ($ageMin -lt $ClaimStaleMinutes) { continue }                  # a peer is mid-report; let it finish
      Write-Log WARN "re-taking an abandoned crash-report claim on $($d.Name) ($([int]$ageMin)m old, never reported)"
      $stale = $true
    }
    $rl = Join-Path $d.FullName 'run.log'
    if (-not (Test-Path $rl)) { continue }                              # dir made, nothing logged — nothing to say
    if (Test-RunAlive $d.FullName) {                                    # a concurrent manual run, still working
      Write-Log INFO "run $($d.Name) is still in progress (another SunUp process) — not treating it as crashed."
      continue
    }
    $last = try { @(Get-Content $rl -Tail 1 -ErrorAction Stop)[0] } catch { $null }
    # TAKE THE REPORT with a real lock: open the marker with FileShare::None, so the OS handle IS the
    # mutual exclusion. Earlier attempts built the lock out of file operations — create-if-absent for
    # a fresh claim, rename-to-lease for a stale retake — and each left a window where the marker did
    # not exist as itself, which a scanner arriving mid-take reads as "unclaimed". An exclusive handle
    # has no such window: the file is always present and always recognizable, exactly one process can
    # hold it, and Windows releases it automatically if we are killed. One mechanism covers the fresh
    # claim (OpenOrCreate creates it) and the retake (OpenOrCreate reopens it) identically.
    # A peer probing while we hold it fails to read, sees an unreported claim, and leaves it to us.
    $fs = $null
    $markerPreexisted = Test-Path $marker
    $abandonClaim     = $false
    try {
      $fs = [System.IO.File]::Open($marker, [System.IO.FileMode]::OpenOrCreate,
                                   [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch { continue }        # a peer holds the lock — it is reporting this one
    try {
      # Final completion check, as late as possible and under the lock: a live peer may have published
      # result.json and removed running.json in the window between the checks above and this take, in
      # which case it finished normally and there is nothing to report.
      if (Test-Path $resultPath) { $abandonClaim = $true; continue }
      $m = "Previous run $($d.Name) never finished — no result.json, so the engine was killed mid-run. Last log line: $last"
      Write-Log WARN $m
      Write-Evt 2011 Warning $m
      Raise-SysSentryAlert $m
      # reported=true is written LAST and is what turns a claim into a finished report: if we die
      # before this, the marker stays unreported and a later run retakes it rather than losing it.
      # Written through the locked handle — a temp-file-and-rename publish cannot replace a file we
      # are holding open, and here the lock matters more than the rename.
      $json  = [ordered]@{
        runStamp = $d.Name; detectedLocal = (Get-Date).ToString('o'); detectedByVersion = $script:Version
        lastLogLine = "$last"; reported = $true
      } | ConvertTo-Json -Depth 4
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
      $fs.SetLength(0); $fs.Write($bytes, 0, $bytes.Length); $fs.Flush()
    } catch {
      Write-Log WARN "could not complete the crash report for $($d.Name): $($_.Exception.Message)"
    } finally {
      $fs.Dispose()
      # If the run turned out to have finished, leave the dir exactly as we found it — an empty marker
      # we created for a completed run would be litter that reads like a claim.
      if ($abandonClaim -and -not $markerPreexisted) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }
    }
  }
}

function Raise-SysSentryAlert { param($Msg)
  if (-not (Test-Path $SysSentryAlerts)) { return }
  try { "- **{0:yyyy-MM-dd HH:mm}** `[$($Name.ToUpper())`] {1}" -f (Get-Date), $Msg | Add-Content $SysSentryAlerts } catch {}
}

# ---- per-day stamp ----------------------------------------------------------
function Get-Stamp { if (Test-Path $StampFile) { try { Get-Content $StampFile -Raw | ConvertFrom-Json } catch { $null } } else { $null } }

# Normalize a stamp timestamp to UTC whatever form it arrives in. ConvertFrom-Json parses an
# ISO-8601 string into a [datetime], so a value written as '…Z' comes BACK as a DateTime and
# interpolates as culture-formatted local wall time ("08/03/2026 06:18:05") — which never equals the
# round-trip string it was written from. Comparing those as strings made the stamp verification
# below report a phantom concurrent write on every single run: three writes and a misleading warning
# each time, which is precisely the kind of false signal this release exists to remove. Caught by
# running the engine, not by reading it.
function ConvertTo-UtcTime { param($Value)
  if ($null -eq $Value -or "$Value" -eq '') { return $null }
  if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
  try { return ([datetime]::Parse("$Value", $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime() }
  catch { return $null }
}
function Save-Stamp { param($Obj) try { $Obj | ConvertTo-Json -Depth 8 | Set-Content $StampFile } catch { Write-Log WARN "could not write stamp: $_" } }

# Save the stamp as a read-modify-write under the ingest lock, merging the two fields a CONCURRENT
# run can legitimately have advanced since we read it. The ingest mutex is released long before the
# stamp is written, so with a manual `-Mode Run -Force` overlapping a scheduled run: one run can scan
# before a detached reboot record exists, the other then ingests it and stamps
# handoffRebootPending=true, and the first — finishing last — would blank the flag with an
# unconditional write. The record is already marked ingested, so that reboot would be lost for good.
#   * handoffRebootPending is never cleared here on someone else's behalf. Only an observed boot
#     clears it (that is what $Booted means), so the merge is an OR.
#   * ingestCursor only ever moves forward: a peer that scanned more recently knows more than we do.
function Save-StampMerged { param($Obj, [bool]$Booted)
  $mx = $null; $have = $false
  try { $mx = New-Object System.Threading.Mutex($false, 'Global\SunUp-Ingest') } catch { $mx = $null }
  if ($mx) {
    try { $have = $mx.WaitOne([timespan]::FromSeconds(15)) }
    catch [System.Threading.AbandonedMutexException] { $have = $true }
    catch { $have = $false }
  }
  # NOT abandoned when the lock cannot be taken, unlike the ingest: this stamp also carries the
  # once-per-day gate, and skipping the write would have the next trigger re-run the entire update
  # pass. So it always writes — but it merges, writes, then VERIFIES, and retries if a concurrent
  # save landed in between. Bounded, because two engines could otherwise trade writes indefinitely.
  if (-not $have) { Write-Log WARN 'stamp: could not take the ingest lock — merging without it and verifying the result.' }
  try {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
      $onDisk = Get-Stamp
      if (-not $Booted -and $onDisk -and $onDisk.handoffRebootPending) { $Obj.handoffRebootPending = $true }
      $ours = ConvertTo-UtcTime $Obj.ingestCursor
      if ($onDisk -and $ours) {
        $theirs = ConvertTo-UtcTime $onDisk.ingestCursor
        if ($theirs -and $theirs -gt $ours) { $Obj.ingestCursor = $onDisk.ingestCursor; $ours = $theirs }
      }
      Save-Stamp $Obj
      # Compare as UTC instants, never as text: what comes back from ConvertFrom-Json is a [datetime]
      # whose string form is culture-formatted local time, so a string compare here always "differed".
      $after = Get-Stamp
      $lost  = [bool]($after -and (
                 (((-not $Booted) -and $Obj.handoffRebootPending) -and -not $after.handoffRebootPending) -or
                 ($ours -and ((ConvertTo-UtcTime $after.ingestCursor) -ne $ours))))
      if (-not $lost) { break }
      Write-Log WARN "stamp: a concurrent run rewrote it — merging again (attempt $attempt of 3)."
    }
  } finally {
    if ($have) { try { $mx.ReleaseMutex() } catch { } }
    if ($mx)   { try { $mx.Dispose() } catch { } }
  }
}

# ---- OEM update policy ------------------------------------------------------
# Resolved once per run and reported, never applied silently: a user who set `block` and got nothing
# blocked (unknown OEM, or the profile table failed to load) must be told, not left assuming.
# Returns @{ block=$bool; vendor=<profile or $null>; wuTitle=''; winget=''; note='' }.
function Resolve-VendorPolicy { param($Cfg)
  $out = @{ block = $false; vendor = $null; wuTitle = ''; winget = ''; note = '' }
  $mode = "$($Cfg.vendorUpdates)"
  if ($mode -ne 'block') { return $out }
  if (-not (Get-Command Get-SystemVendor -ErrorAction SilentlyContinue)) {
    $out.note = 'vendorUpdates=block but VendorProfiles.ps1 did not load — no OEM updates are being blocked'
    return $out
  }
  $v = Get-SystemVendor
  if (-not $v) {
    $mfr = try { "$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer)" } catch { 'unknown' }
    $out.note = "vendorUpdates=block but this machine's OEM ('$mfr') matches no profile — nothing is being blocked; add a row to VendorProfiles.ps1"
    return $out
  }
  $out.block = $true; $out.vendor = $v; $out.wuTitle = $v.wuTitle; $out.winget = $v.winget
  $out.note  = "vendorUpdates=block — $($v.name) updates excluded from Windows Update (title ~ '$($v.wuTitle)') and winget (id ~ '$($v.winget)')"
  $out
}

# Merge a vendor pattern into a configured exclusion pattern. Either may be empty; the result is a
# regex alternation, or '' when there is nothing to exclude at all.
function Join-ExcludePattern { param([string]$Configured, [string]$Vendor)
  @($Configured, $Vendor) | Where-Object { "$_".Trim() } | ForEach-Object { "$_" } | Join-String -Separator '|'
}

# ---- winget path resolver (SYSTEM can't see the per-user PATH shim) ----------
function Resolve-Winget {
  $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($cmd -and (Test-Path $cmd.Source)) { return $cmd.Source }
  $exe = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' -ErrorAction SilentlyContinue |
         Sort-Object FullName | Select-Object -Last 1
  if ($exe) { return $exe.FullName }
  return $null
}

# Pending-reboot detection lives in RebootState.ps1 (dot-sourced at the top) — `Get-RebootState`.
# It replaced a local Test-PendingReboot that answered $true for ANY PendingFileRenameOperations
# entry, including the delete-on-boot an application queues for its own temp files. That single
# boolean is why this box reported rebootPending=true continuously from 2026-08-04.

# ---- component runner: uniform timing + error capture + raw log -------------
# Each component scriptblock writes its raw output via Write-CompLog and returns
# @{ status='ok'|'warn'|'error'|'skip'; detail='one-line summary' }.
function Invoke-Component { param([string]$Name, [scriptblock]$Body)
  Write-Log INFO "${Name}: starting…"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $r  = [ordered]@{ name = $Name; status = 'error'; detail = ''; error = $null; reboot = $false; durationSec = 0; log = "$Name.log" }
  try {
    $res = & $Body
    if ($res) { $r.status = $res.status; $r.detail = "$($res.detail)"; if ($res.error) { $r.error = "$($res.error)" }; if ($res.reboot) { $r.reboot = $true } }
  } catch {
    $r.status = 'error'
    $r.error  = $_.Exception.Message
    $detail   = "EXCEPTION: $($_.Exception.Message)`n$($_ | Out-String)`nStack:`n$($_.ScriptStackTrace)"
    Write-CompLog $Name $detail
    Write-Log ERROR "$Name threw: $($_.Exception.Message)"
  } finally {
    $sw.Stop(); $r.durationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  }
  $lvl = switch ($r.status) { 'error' { 'ERROR' } 'warn' { 'WARN' } default { 'INFO' } }
  Write-Log $lvl ("{0}: {1} ({2}s) {3}" -f $Name, $r.status, $r.durationSec, $r.detail)
  Add-Report ("- {0}: **{1}** ({2}s) {3}{4}" -f $Name, $r.status, $r.durationSec, $r.detail, $(if ($r.error) { " — $($r.error)" } else { '' }))
  return [pscustomobject]$r
}

# =====================  update components  ===================================

function Comp-Defender {
  $before = (Get-MpComputerStatus -ErrorAction Stop).AntivirusSignatureVersion
  Write-CompLog 'defender' "Signature before: $before"
  # Time just the signature pull so the dialog's Duration column is populated (the component-level
  # timer in Invoke-Component covers before/after status calls too, so capture this span directly).
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Update-MpSignature -ErrorAction Stop
  $sw.Stop()
  $after = (Get-MpComputerStatus -ErrorAction Stop).AntivirusSignatureVersion
  Write-CompLog 'defender' "Signature after:  $after"
  # Size stays null (the Defender API exposes no signature-package download size → dialog shows "—").
  if ($before -ne $after) { Add-Update -Name 'Microsoft Defender signatures' -Source 'Defender' -Old "$before" -New "$after" -DurationSec ([math]::Round($sw.Elapsed.TotalSeconds,1)) -SizeMB $null }
  $detail = if ($before -eq $after) { "signatures current ($after)" } else { "signatures $before -> $after" }
  @{ status = 'ok'; detail = $detail }
}

function Comp-WindowsUpdate { param($Cfg)
  if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
    Write-CompLog 'windowsupdate' 'PSWindowsUpdate module not installed — run Install.ps1.'
    return @{ status = 'error'; detail = 'PSWindowsUpdate module missing'; error = 'module not installed' }
  }
  Import-Module PSWindowsUpdate -ErrorAction Stop
  # Snapshot the OS build (CurrentBuild.UBR) before/after so a Cumulative/Feature update can show a
  # real old->new (e.g. 26200.8737 -> 26200.9xxx) instead of a blank "old" column.
  $buildKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $beforeBuild = try { $b = Get-ItemProperty $buildKey -ErrorAction Stop; "$($b.CurrentBuildNumber).$($b.UBR)" } catch { $null }
  $params = @{ MicrosoftUpdate = $true; AcceptAll = $true; Install = $true; IgnoreReboot = $true }
  # The OEM's own driver/firmware arrives here as well as through its updater — WU titles them with
  # the publisher ("Dell Inc. - Firmware - 1.2.4") — so vendorUpdates=block filters this path too.
  $notTitle = Join-ExcludePattern "$($Cfg.windowsUpdate.notTitle)" $script:VendorPolicy.wuTitle
  if ($notTitle) { $params.NotTitle = $notTitle }
  $sw  = [System.Diagnostics.Stopwatch]::StartNew()
  $res = @(Get-WindowsUpdate @params -Verbose -ErrorAction Stop 4>&1)
  $sw.Stop(); $instDur = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  Write-CompLog 'windowsupdate' $res
  $afterBuild = try { $b = Get-ItemProperty $buildKey -ErrorAction Stop; "$($b.CurrentBuildNumber).$($b.UBR)" } catch { $null }
  $items     = @($res | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties.Name -contains 'Result' })
  $installed = @($items | Where-Object Result -eq 'Installed').Count
  $failed    = @($items | Where-Object Result -eq 'Failed').Count
  if ($items.Count -eq 0) { return @{ status = 'ok'; detail = 'up to date' } }
  # Duration is the batch install span (WU installs together; no per-update timing). For a single
  # installed update that's exact; for several it's the shared batch total — labeled as such in docs.
  $buildMoved = $beforeBuild -and $afterBuild -and ($beforeBuild -ne $afterBuild)
  foreach ($u in ($items | Where-Object Result -eq 'Installed')) {
    $mb = if ($u.Size) { try { [math]::Round(([double]$u.Size)/1MB,1) } catch { $null } } else { $null }
    $kb = if ($u.KB) { "$($u.KB)" } else { 'installed' }
    $title = "$($u.Title)"
    # OS-level updates carry the build transition; everything else shows its KB.
    if ($buildMoved -and $title -match 'Cumulative Update|Feature Update|Windows 1[01]|Servicing Stack') {
      Add-Update -Name $title -Source 'Windows Update' -Old $beforeBuild -New $afterBuild -DurationSec $instDur -SizeMB $mb
    } else {
      Add-Update -Name $title -Source 'Windows Update' -Old '—' -New $kb -DurationSec $instDur -SizeMB $mb
    }
  }
  # Did any update we just installed ask for a reboot? Prefer the per-update flag; fall
  # back to WU's post-install reboot status (the box's WU flag was clear before this run).
  $reboot = @($items | Where-Object { $_.PSObject.Properties.Name -contains 'RebootRequired' -and $_.RebootRequired }).Count -gt 0
  if (-not $reboot) { try { $reboot = [bool](Get-WURebootStatus -Silent -ErrorAction Stop) } catch {} }
  $detail = "$installed installed, $failed failed ($($items.Count) offered)" + $(if ($reboot) { '; reboot required' } else { '' })
  if ($failed -gt 0) { return @{ status = 'error'; detail = $detail; error = "$failed update(s) failed — see windowsupdate.log"; reboot = $reboot } }
  @{ status = 'ok'; detail = $detail; reboot = $reboot }
}

# Parse winget's fixed-width "upgrade" table into {name,id,old,new}. English headers
# (Name/Id/Version/Available/Source) — fine on this box.
function Parse-WingetUpgrades { param([string[]]$Lines)
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
# winget download size in MB. Under `--silent --disable-interactivity` winget prints NO "/ N MB"
# progress chatter (that only renders on an interactive console), so size can't be scraped from the
# install output — the reason winget rows showed "—" for size. But winget still logs a bare
# "Downloading <url>" line per artifact, and the real installer size is one HEAD away: we request
# each URL with Accept-Encoding: identity (identity forces the server off on-the-fly gzip, which
# otherwise omits Content-Length entirely — e.g. Google's CDN) and read Content-Length. Sum all
# artifacts, since an install may also pull dependencies. Runs AFTER the package already upgraded,
# so any failure here only blanks the size cell — never the update. Returns $null (→ "—") when there
# is no URL (msstore packages install via the Store), the server sends no length (chunked transfer),
# or a signed URL has expired: an honest "—" beats a fabricated number.
function Get-WingetDownloadSizeMB { param([string]$Text)
  $urls = @([regex]::Matches($Text, '(?im)^\s*Downloading\s+(https?://\S+)') |
           ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
  if ($urls.Count -eq 0) { return $null }
  $totalBytes = 0.0; $got = $false
  foreach ($u in $urls) {
    try {
      $req = [System.Net.HttpWebRequest]::Create($u)
      $req.Method            = 'HEAD'
      $req.AllowAutoRedirect = $true
      $req.Timeout           = 20000
      $req.Headers['Accept-Encoding'] = 'identity'
      $resp = $req.GetResponse()
      $len  = $resp.ContentLength
      $resp.Close()
      if ($len -gt 0) { $totalBytes += [double]$len; $got = $true }
      else { Write-CompLog 'winget' "size: no Content-Length for $u" }
    } catch {
      Write-CompLog 'winget' "size: HEAD failed for $u — $($_.Exception.Message)"
    }
  }
  if ($got) { [math]::Round($totalBytes / 1MB, 1) } else { $null }
}

# v0.10.x/v0.11.0 lived here: Test-WingetHasMsiInstaller (does this package publish an MSI-family
# installer, so Restart Manager properties can apply?) and Test-WingetArgsRejected (was the failure
# the args being rejected, so a retry without them is safe?). Both existed to pass
# MSIRESTARTMANAGERCONTROL=Disable as safely as possible. v0.12.0 removed them along with the whole
# approach: RM ran regardless of the property (measured 2026-07-28) and the engine no longer upgrades
# self-hosting packages at all. SelfHost.ps1 keeps a small inline version of the retry gate, for
# REBOOT=ReallySuppress only.

function Comp-Winget { param($Cfg)
  $winget = Resolve-Winget
  if (-not $winget) { return @{ status = 'error'; detail = 'winget not found'; error = 'winget.exe not resolvable' } }
  Write-CompLog 'winget' "winget: $winget"
  $listRaw  = & $winget upgrade --include-unknown --accept-source-agreements 2>&1
  $listCode = $LASTEXITCODE      # capture immediately — a non-zero list exit means a network/source
                                 # hiccup, which otherwise parses to zero rows and masquerades as "up to date".
  Write-CompLog 'winget' @('--- available ---') ; Write-CompLog 'winget' $listRaw
  Write-CompLog 'winget' ("list exit: 0x{0:X8}" -f ([int]$listCode))
  if ($listCode -ne 0) { Write-Log WARN "winget: upgrade-list exited 0x$(([int]$listCode).ToString('X8')) — result may be incomplete" }
  $pending = Parse-WingetUpgrades ([string[]]($listRaw -split "`r?`n"))
  # OEM utilities (Dell.CommandUpdate, Lenovo.Vantage, …) ship through winget, so vendorUpdates=block
  # covers this path as well as Windows Update.
  $excl = Join-ExcludePattern "$($Cfg.winget.excludePattern)" $script:VendorPolicy.winget
  $skipCount = 0
  if ($excl) {
    $skipped = @($pending | Where-Object { $_.name -match $excl -or $_.id -match $excl })
    $pending = @($pending | Where-Object { $_.name -notmatch $excl -and $_.id -notmatch $excl })
    $skipCount = $skipped.Count
    # Honest about what we drop: an excluded package is a deliberate skip, not a silent no-op.
    if ($skipCount -gt 0) {
      $ids = ($skipped | ForEach-Object { $_.id }) -join ', '
      Write-CompLog 'winget' "--- skipped $skipCount excluded package(s): $ids ---"
      Write-Log INFO "winget: skipped $skipCount excluded package(s): $ids"
    }
  }
  $skipNote = if ($skipCount -gt 0) { ", $skipCount skipped" } else { '' }
  if (@($pending).Count -eq 0) {
    # Distinguish a genuine "nothing to upgrade" (list exit 0) from an empty result caused by a failed
    # list (non-zero exit) — the latter must not masquerade as up-to-date in result.json/Status.
    if ($listCode -ne 0) {
      return @{ status = 'warn'; detail = "upgrade list incomplete (exit 0x$(([int]$listCode).ToString('X8')))$skipNote"; error = 'winget upgrade list exited non-zero' }
    }
    return @{ status = 'ok'; detail = "up to date$skipNote" }
  }

  # ---- self-hosting packages: NOT upgraded here --------------------------------
  # SunUp's engine runs under pwsh, so upgrading Microsoft.PowerShell has Windows Installer's
  # Restart Manager enumerate every process holding files under the install target and shut them
  # down — including the engine that asked for the install. That killed the runs of 2026-07-22 and
  # 2026-07-27 outright: no result.json, no reboot decision, no summary dialog, no day stamp.
  #
  # v0.11.0 tried to prevent that in place, by passing MSIRESTARTMANAGERCONTROL=Disable through
  # winget's --custom. It did not work. The 2026-07-28 run proved it: the args were applied (the
  # winget log shows them) and RM ran anyway, logging 10002 "Shutting down application or service
  # 'PowerShell 7'" and killing all five pwsh processes on the box while the MSI itself returned
  # success. Whether winget dropped the property or Windows Installer ignored it across the
  # major-upgrade transaction was never established — and doesn't matter: the mitigation had no
  # feedback loop, so a silent no-op looked exactly like success until the engine died.
  #
  # So the engine no longer tries to survive RM — it gets out of the blast radius. Self-hosting
  # packages are handed to SelfHost.ps1, run by a one-shot scheduled task under WINDOWS POWERSHELL
  # 5.1 (a separate install RM's "shut down PowerShell 7" cannot reach), which waits for this
  # process to exit first. The engine therefore always completes; the upgrade lands just after.
  $selfPat = "$($Cfg.winget.selfHostPattern)"
  $handoffNote = ''
  if ($selfPat) {
    $isSelfHost = { param($Pkg) $Pkg.id -match $selfPat -or $Pkg.name -match $selfPat }
    $deferred = @($pending | Where-Object { & $isSelfHost $_ })
    if ($deferred.Count -gt 0) {
      $pending = @($pending | Where-Object { -not (& $isSelfHost $_) })
      $script:SelfHostPending = $deferred
      $ids = ($deferred | ForEach-Object { $_.id }) -join ', '
      Write-CompLog 'winget' "--- handing $($deferred.Count) self-hosting package(s) to $SelfHostTask, which runs after this engine exits: $ids ---"
      Write-Log INFO "winget: handing $($deferred.Count) self-hosting package(s) to the detached helper: $ids"
      $handoffNote = "; $($deferred.Count) handed to the self-host helper"
    }
  }

  # Exit codes that mean "installed OK, but a reboot is needed" (MSI 3010 + winget's own).
  $rebootCodes = 3010, 0x8A150077, 0x8A150078, 0x8A150079
  $ok = 0; $fail = 0; $reboot = $false
  # Nothing here is self-hosting any more (those were split out above), so no --custom, no
  # Restart-Manager games and no retry-without-args dance: a plain silent upgrade per package.
  foreach ($p in $pending) {
    Write-CompLog 'winget' "--- upgrading $($p.id) ($($p.old) -> $($p.new)) ---"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $o  = & $winget upgrade --id $p.id -e --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    $code = $LASTEXITCODE
    $sw.Stop()
    $txt = $o | Out-String
    Write-CompLog 'winget' $o ; Write-CompLog 'winget' "exit: 0x$($code.ToString('X8')), $([int]$sw.Elapsed.TotalSeconds)s"
    if ($code -eq 0 -or $code -in $rebootCodes) {
      $ok++
      if ($code -in $rebootCodes) { $reboot = $true; Write-Log INFO "winget: $($p.id) installed — reboot required" }
      Add-Update -Name $p.name -Source 'winget' -Old $p.old -New $p.new -DurationSec ([math]::Round($sw.Elapsed.TotalSeconds,1)) -SizeMB (Get-WingetDownloadSizeMB $txt)
    } else { $fail++; Write-Log WARN "winget: $($p.id) exit 0x$($code.ToString('X8'))" }
  }
  $detail = "$ok upgraded, $fail failed (of $(@($pending).Count))$skipNote$handoffNote" + $(if ($reboot) { '; reboot required' } else { '' })
  if ($fail -gt 0) { return @{ status = 'warn'; detail = $detail; error = "see winget.log"; reboot = $reboot } }
  @{ status = 'ok'; detail = $detail; reboot = $reboot }
}

function Comp-PSModules {
  $out = Update-Module -Force -Confirm:$false -ErrorAction Continue 2>&1
  Write-CompLog 'psmodules' $out
  @{ status = 'ok'; detail = 'Update-Module run' }
}

# psModules is slow and PSGallery modules rarely change, so gate it to once every N days
# (default 7) via its own stamp — the rest of the run still happens daily.
function Test-PSModulesDue {
  param([int]$EveryDays)
  if ($EveryDays -le 1) { return $true }
  try {
    if (Test-Path $PSModStamp) {
      $last     = (Get-Content $PSModStamp -Raw | ConvertFrom-Json).date
      $lastDate = [datetime]::ParseExact($last, 'yyyy-MM-dd', $null)
      if (((Get-Date).Date - $lastDate).TotalDays -lt $EveryDays) { return $false }
    }
  } catch { return $true }   # unreadable stamp → treat as due
  $true
}
function Set-PSModulesStamp { @{ date = (Get-Date).ToString('yyyy-MM-dd') } | ConvertTo-Json | Set-Content $PSModStamp -Encoding UTF8 }

# ---- starting a scheduled task, and KNOWING that it started -----------------
# Start-ScheduledTask reports success without running anything when an instance of the task is
# already active and the task is registered -MultipleInstances IgnoreNew — which both handoff tasks
# are. The engine used to log "started …" and raise event 2020 unconditionally on that call, so a
# handoff that was silently dropped read exactly like one that ran: the
# silent-no-op-that-looks-like-success shape v0.12.0 exists to eliminate. So refuse to start over a
# live instance, then confirm the task really entered Running (or ran to completion) before claiming
# anything happened. Returns @{ ok = $bool; reason = '<why not>' }.
function Start-TaskVerified { param([string]$TaskName, [int]$TimeoutSec = 20)
  # Serialized machine-wide, because the confirmation below is only as good as the pre-check above it:
  # two engines can both pass that pre-check before either task enters Running, Task Scheduler starts
  # exactly one (IgnoreNew drops the other), and both then observe the SAME advanced LastRunTime and
  # both claim success — so one run's package set is never handed off while its log says it was.
  # Under the lock the loser's pre-check sees Running and it reports that honestly instead.
  $mx = $null; $haveStart = $false
  try { $mx = New-Object System.Threading.Mutex($false, 'Global\SunUp-TaskStart') } catch { $mx = $null }
  if ($mx) {
    try { $haveStart = $mx.WaitOne([timespan]::FromSeconds(30)) }
    catch [System.Threading.AbandonedMutexException] { $haveStart = $true }
    catch { $haveStart = $false }
  }
  if (-not $haveStart) {
    if ($mx) { try { $mx.Dispose() } catch { } }
    return @{ ok = $false; reason = 'another run holds the task-start lock, so this start could not be confirmed' }
  }
  try {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  if ($t.State -eq 'Running')  { return @{ ok = $false; reason = 'an instance is already running (MultipleInstances=IgnoreNew would silently drop this one)' } }
  if ($t.State -eq 'Disabled') { return @{ ok = $false; reason = 'the task is disabled' } }
  $before    = try { (Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop).LastRunTime } catch { $null }
  $startedAt = Get-Date
  Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    # LastRunTime must have moved, AND moved past OUR call. Accepting `State -eq 'Running'` proved
    # nothing on its own: an instance that entered Running between the pre-check and the start is
    # exactly the instance IgnoreNew dropped ours in favour of, and it looks identical from here.
    # (A manual `-Mode Run -Force` alongside a scheduled run really can produce two engines here.)
    $now = try { (Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop).LastRunTime } catch { $null }
    if ($now -and ((-not $before) -or ($now -gt $before)) -and ($now -ge $startedAt.AddSeconds(-2))) {
      return @{ ok = $true; reason = '' }
    }
    Start-Sleep -Milliseconds 500
  }
  @{ ok = $false; reason = "the task did not register a new run within ${TimeoutSec}s" }
  } finally {
    if ($haveStart) { try { $mx.ReleaseMutex() } catch { } }
    if ($mx)        { try { $mx.Dispose() } catch { } }
  }
}

# ---- fold in what the detached passes did after the LAST run ended ----------
# SelfHost.ps1 and UserScope.ps1 both finish after the engine that started them has exited, so their
# results cannot appear in that run's result.json — and until now nothing ever read the JSON they
# leave behind. That cost three separate silent failures: a successful PowerShell 7 upgrade never
# appeared in updates[], the dialog or the history; a FAILED one never appeared anywhere, so the run
# still reported winget=ok; and a winget "restart required" exit code was lost entirely, because the
# engine had already made its reboot decision and a winget-signalled reboot sets no OS pending flag
# for the stale-reboot watchdog to find either.
# So each run ingests the records written since it last looked, exactly once — ingested=true is
# written back through the same atomic publish everything else here uses.
# $Since = when the last run's ingest scan began (the cursor, carried in the stamp). A record written
# before that was already on disk while that run was deciding, so it is not news: it is marked
# consumed and named in the log rather than resurfacing days later as today's updates.
# $BootedUtc = the box's last boot. A reboot request from a helper that finished BEFORE that boot has
# already been satisfied — importing it would otherwise schedule a second, pointless restart.
function Import-DetachedResults { param($Since, $BootedUtc)
  # scanned = the records were actually examined. Every early return below leaves it false, and the
  # caller must then NOT advance the cursor: doing so would mark records that existed at the aborted
  # attempt's start time as stale on the next run and consume them unread — the very loss the cursor
  # exists to prevent, reintroduced by the abort path.
  $out = @{ upgraded = 0; failed = 0; reboot = $false; notes = @(); scanned = $false }
  if (-not (Test-Path $RunsDir)) { return $out }
  # ONE ingest at a time, machine-wide. Two engines really can run at once — the documented
  # `-Mode Run -Force` alongside a scheduled run, which the crash detector already has to reason
  # about — and read-count-then-mark is not atomic: both would count the same upgrade into their own
  # history and dialog, and both act on its reboot request. If the lock cannot be taken, ingest
  # NOTHING: every record keeps ingested=false and the next run picks it up, which is the safe
  # direction. (No explicit ACL here, unlike SelfHost.ps1's winget lock: both holders are the engine,
  # which is always SYSTEM or an elevated manual run — and .NET 5+ dropped the MutexSecurity ctor.)
  $mx = $null; $haveLock = $false
  try { $mx = New-Object System.Threading.Mutex($false, 'Global\SunUp-Ingest') } catch { $mx = $null }
  if (-not $mx) {
    # No lock means no protection, so do not ingest at all. Falling through here would have been a
    # fail-OPEN path in the very guard added to stop two engines double-counting the same record.
    Write-Log WARN 'handoff: could not create the ingest lock — leaving the detached records for the next run.'
    return $out
  }
  try { $haveLock = $mx.WaitOne([timespan]::FromSeconds(60)) }
  catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
  catch { $haveLock = $false }
  if (-not $haveLock) {
    Write-Log WARN 'handoff: another run holds the ingest lock — leaving the detached records for the next run.'
    try { $mx.Dispose() } catch { }
    return $out
  }
  try {
  $files = @(
    @{ name = 'selfhost.json';      source = 'winget (self-host)' }
    @{ name = 'user-winget.json';   source = 'winget (user scope)' }
    @{ name = 'user-selfhost.json'; source = 'winget (user self-host)' }
  )
  # EVERY retained run dir, not the newest few. A helper can finish long after its own run — it waits
  # for the engine, for the user-scope task, for a reboot countdown, for the winget lock — by which
  # time several `-Mode Run -Force` runs may have created newer dirs. Capping the search by count
  # would drop those records permanently; the $Since cursor below is what keeps old news out instead.
  $dirs = @(Get-ChildItem $RunsDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $script:RunDir } | Sort-Object Name -Descending)
  foreach ($d in $dirs) {
    foreach ($f in $files) {
      $p = Join-Path $d.FullName $f.name
      if (-not (Test-Path $p)) { continue }
      $j = try { Get-Content $p -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
      if (-not $j) { Write-Log WARN "handoff: $($d.Name)\$($f.name) is unreadable — whatever it recorded is lost."; continue }
      if ($j.ingested) { continue }
      # Older than the cursor = it predates this feature (or was already visible to a run that chose
      # not to act on it). Consume it so it cannot resurface, and say what was skipped.
      # The timestamp is when the record became VISIBLE (the file's write time), not the
      # finishedLocal the helper stamped inside it before serializing: those differ by the length of
      # the write, and a scan that caught the file mid-write skipped it as unreadable. Judging the
      # completed record by the earlier embedded time would then bury it as stale, unimported.
      # (The producers publish atomically now, which closes the mid-write window itself.)
      # UTC on both sides. In local time, the repeated hour after a daylight-saving fall-back gives a
      # file written AFTER the cursor a wall-clock stamp that reads as earlier, and this branch would
      # then consume a brand-new record unread — once a year, silently, which is the worst kind.
      $written = try { (Get-Item $p -ErrorAction Stop).LastWriteTimeUtc } catch { $null }
      if (-not $written) {
        try { $written = ([datetime]::Parse("$($j.finishedLocal)", $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime() } catch { }
      }
      $sinceUtc = if ($Since) { $Since.ToUniversalTime() } else { $null }
      if ($sinceUtc -and $written -and $written -le $sinceUtc) {
        Write-Log INFO "handoff: $($d.Name)\$($f.name) predates the last run ($written UTC) — marking it consumed without counting it."
        $j | Add-Member -NotePropertyName ingested -NotePropertyValue $true -Force
        [void](Publish-JsonFile $j $p)
        continue
      }
      foreach ($r in @($j.results)) {
        if (-not $r) { continue }
        if ($r.ok) {
          $out.upgraded++
          $label = if ("$($r.name)") { "$($r.name)" } else { "$($r.id)" }
          $old   = if ("$($r.old)")  { "$($r.old)" }  else { '—' }
          $new   = if ("$($r.new)")  { "$($r.new)" }  else { '—' }
          Add-Update -Name $label -Source $f.source -Old $old -New $new -DurationSec $r.durationSec -SizeMB $null
        } else {
          $out.failed++
          $out.notes += ("{0} failed (exit {1}, run {2})" -f "$($r.id)", "$($r.exitCode)", $d.Name)
        }
      }
      if ($j.rebootRequired) {
        $satisfied = $BootedUtc -and $written -and ($written -le $BootedUtc)   # both UTC, see above
        if ($satisfied) {
          Write-Log INFO "handoff: $($d.Name)\$($f.name) wanted a reboot, but the box has booted since it finished — already satisfied."
        } else {
          $out.reboot = $true
          $out.notes  += ("{0} needs a reboot (run {1})" -f $f.name, $d.Name)
        }
      }
      # Mark it consumed. A failed write would have the record ingested again next run and
      # double-counted, so it is reported rather than left to repeat quietly.
      $j | Add-Member -NotePropertyName ingested -NotePropertyValue $true -Force
      if (-not (Publish-JsonFile $j $p)) { Write-Log WARN "handoff: could not mark $($d.Name)\$($f.name) ingested — it may be counted again next run." }
    }
  }
  $out.scanned = $true      # only here: every record was looked at, so the cursor may advance
  } finally {
    if ($haveLock) { try { $mx.ReleaseMutex() } catch { } }
    if ($mx)       { try { $mx.Dispose() } catch { } }
  }
  $out
}

# =====================  query modes  =========================================
function Get-LatestRunDir { Get-ChildItem $RunsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1 }
function Get-LatestResult {
  $d = Get-LatestRunDir
  if ($d -and (Test-Path "$($d.FullName)\result.json")) { return (Get-Content "$($d.FullName)\result.json" -Raw | ConvertFrom-Json) }
  $null
}

# Past-N-day update history for the dialog. The dialog runs non-elevated and can't read logs\,
# so the engine (SYSTEM) reads history.jsonl here and the result is embedded in the notify payload.
# Each history.jsonl line is a full run object carrying date/runStamp/updates[]. Returns flat rows
# {when,stamp,name,source,old,new,durationSec,sizeMB}, newest-first, capped at MaxRows. Collapse
# keeps only the latest occurrence per name|source (so daily Defender-signature bumps don't flood
# the list). Sorts use stamp (full runStamp), not when (date only): same-day runs must not tie, or
# "latest" degrades to file order — which a late-imported detached result can put out of sequence.
function Get-UpdateHistory {
  param([int]$Days = 30, [bool]$Collapse = $true, [string]$ExcludeRunStamp, [int]$MaxRows = 500)
  if (-not (Test-Path $HistoryFile)) { return @() }
  $cutoff = (Get-Date).Date.AddDays(-$Days)
  $rows = [System.Collections.Generic.List[object]]::new()
  foreach ($line in (Get-Content $HistoryFile)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $run = try { $line | ConvertFrom-Json } catch { $null }
    if (-not $run) { continue }
    if ($ExcludeRunStamp -and $run.runStamp -eq $ExcludeRunStamp) { continue }   # current run is already in items[]
    $d = try { [datetime]::ParseExact("$($run.date)", 'yyyy-MM-dd', $null) } catch { continue }
    if ($d -lt $cutoff) { continue }
    foreach ($u in $run.updates) {
      # [pscustomobject], NOT a hashtable: Sort-Object property binding silently no-ops on
      # dictionary keys, which left this list in Group-Object's alphabetical order.
      $stamp = if ($run.runStamp) { "$($run.runStamp)" } else { "$($run.date)" }
      $rows.Add([pscustomobject]@{ when = $run.date; stamp = $stamp; name = $u.name; source = $u.source; old = $u.old; new = $u.new; durationSec = $u.durationSec; sizeMB = $u.sizeMB })
    }
  }
  if ($Collapse) {
    $rows = @($rows | Group-Object { "$($_.name)|$($_.source)" } | ForEach-Object { $_.Group | Sort-Object stamp | Select-Object -Last 1 })
  }
  @($rows | Sort-Object stamp -Descending | Select-Object -First $MaxRows)
}

if ($Mode -eq 'Status') {
  $stamp = Get-Stamp
  $task  = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  $info  = if ($task) { $task | Get-ScheduledTaskInfo } else { $null }
  $res   = Get-LatestResult
  Write-Host ""
  Write-Host "$Name v$script:Version — caldera"
  Write-Host ("  Task state    : {0}" -f ($(if ($task) { $task.State } else { 'NOT REGISTERED' })))
  if ($info) {
    Write-Host ("  Last task run : {0} (result 0x{1:X8})" -f $info.LastRunTime, $info.LastTaskResult)
    Write-Host ("  Next run      : {0}" -f $info.NextRunTime)
  }
  Write-Host ("  Last update   : {0}" -f $(if ($stamp) { $stamp.date } else { '(never)' }))
  # Fold in a carried run-signal reboot: an MSI 3010 / winget restart exit code sets no OS flag at
  # all, so the registry on its own would answer "no" for a box that really is waiting to restart.
  $rb = Get-RebootState -HandoffRequired ([bool]($stamp -and $stamp.handoffRebootPending))
  Write-Host ("  Reboot now    : {0}{1}" -f $rb.Required, $(if ($rb.Labels.Count) { " ($($rb.Labels -join ', '))" } else { '' }))
  foreach ($r in $rb.Reasons)  { Write-Host ("                    - {0}" -f $r) }
  foreach ($a in $rb.Advisory) { Write-Host ("                    ~ ignored: {0}" -f $a) }
  if ($res) {
    Write-Host ("  Last run      : {0}  ({1}s, forced={2})" -f $res.date, $res.durationSec, $res.forced)
    Write-Host  "  Components    :"
    foreach ($c in $res.components) {
      $flag = if ($c.status -in 'error','warn') { '  <<<' } else { '' }
      Write-Host ("    - {0,-14} {1,-6} {2,5}s  {3}{4}" -f $c.name, $c.status, $c.durationSec, $c.detail, $flag)
      if ($c.error) { Write-Host ("        error: {0}" -f $c.error) }
    }
    Write-Host ("  Run logs      : {0}" -f $res.runDir)
    if (@($res.components | Where-Object status -eq 'error').Count -gt 0) {
      Write-Host "  -> failures present. Drill in:  $Name.ps1 -Mode Errors" -ForegroundColor Yellow
    }
  }
  Write-Host ("  Main log      : {0}  (history: {1})" -f $LogFile, $HistoryFile)
  Write-Host ""
  return
}

if ($Mode -eq 'Errors') {
  if (-not (Test-Path $HistoryFile)) { Write-Host 'No history yet.'; return }
  $runs = Get-Content $HistoryFile | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} }
  $bad  = @($runs | Where-Object { $_.components | Where-Object status -eq 'error' })
  if ($bad.Count -eq 0) { Write-Host 'No failed runs on record. ✓'; return }
  Write-Host "`nFailed runs (most recent last):`n"
  foreach ($r in ($bad | Select-Object -Last 10)) {
    Write-Host ("=== {0}  (run {1}) ===" -f $r.date, $r.runStamp)
    foreach ($c in ($r.components | Where-Object status -eq 'error')) {
      Write-Host ("  [{0}] {1}" -f $c.name, $c.detail)
      if ($c.error) { Write-Host ("       {0}" -f $c.error) }
      $cl = Join-Path (Join-Path $RunsDir $r.runStamp) $c.log
      Write-Host ("       full output: {0}" -f $cl)
      if (Test-Path $cl) {
        Write-Host "       --- tail ---"
        Get-Content $cl -Tail 15 | ForEach-Object { Write-Host "       $_" }
      }
    }
    Write-Host ""
  }
  return
}

if ($Mode -eq 'Tail') {
  $d = Get-LatestRunDir
  if (-not $d) { Write-Host 'No runs yet.'; return }
  $rl = Join-Path $d.FullName 'run.log'
  Write-Host "`n--- $rl (tail) ---`n"
  if (Test-Path $rl) { Get-Content $rl -Tail 60 }
  return
}

# =====================  Run mode  ============================================
$cfg   = Get-Config
$today = (Get-Date).ToString('yyyy-MM-dd')
$stamp = Get-Stamp

if (-not $Force -and $stamp -and $stamp.date -eq $today) {
  # No run dir created in this path; log straight to the main log.
  Write-Log INFO "Already updated today ($today) — skipping. (-Force to override.)"
  return
}

# Set up this run's isolated log dir + rotate the main log + full transcript.
Rotate-Log $LogFile
$script:RunDir = New-RunDirectory ((Get-Date).ToString('yyyy-MM-dd_HHmmss'))   # claimed atomically; see the function
$runStamp      = Split-Path $script:RunDir -Leaf
$script:RunLog = Join-Path $script:RunDir 'run.log'
# Liveness marker, so the NEXT run can tell a dead run from one still working (see Test-RunAlive).
# Written before any component runs — a crash between here and result.json is what we want to catch.
# Start time goes in alongside the PID because PIDs are recycled, and a recycled PID would otherwise
# make a genuinely dead run look alive forever.
$script:RunMarker = Join-Path $script:RunDir 'running.json'
$markerOk = $false
try {
  $me = Get-Process -Id $PID -ErrorAction Stop
  $markerOk = Publish-JsonFile ([ordered]@{
    pid = $PID; processName = $me.ProcessName
    processStartUtc = $me.StartTime.ToUniversalTime().ToString('o')
    host = $env:COMPUTERNAME; startedLocal = (Get-Date).ToString('o')
  }) $script:RunMarker
} catch { }
if (-not $markerOk) {
  # Publish-JsonFile already logged why. Without a marker this run is indistinguishable from a dead
  # one, so say so plainly rather than leaving a path that points at nothing.
  $script:RunMarker = $null
  Write-Log WARN 'running.json could not be written — a concurrent run could mistake this live run for a crashed one.'
}
try { Start-Transcript -Path (Join-Path $script:RunDir 'transcript.log') -Force | Out-Null } catch {}

$startUtc = (Get-Date).ToUniversalTime()
Write-Log INFO "===== $Name v$script:Version run start ($today, forced=$([bool]$Force)) — $runStamp ====="
Write-Evt 2000 Information "$Name run started ($today) — logs in $script:RunDir"
# Never let crash DETECTION be the thing that crashes the run — that would recreate the exact silent
# failure it exists to report, one day later. Its internals are individually guarded; this is the belt.
try { Report-CrashedRuns } catch { Write-Log WARN "crashed-run check failed (continuing): $($_.Exception.Message)" }

# Resolve the OEM policy before any component runs, and say what it resolved to — including when it
# resolved to "nothing", which is the case a user who asked for blocking most needs to hear about.
$script:VendorPolicy = Resolve-VendorPolicy $cfg
if ($script:VendorPolicy.note) {
  if ($script:VendorPolicy.block) { Write-Log INFO  "vendor: $($script:VendorPolicy.note)" }
  else                            { Write-Log WARN  "vendor: $($script:VendorPolicy.note)" }
}

$results = [System.Collections.Generic.List[object]]::new()
if ($cfg.defender.enabled)      { $results.Add( (Invoke-Component 'defender'      { Comp-Defender }) ) }
if ($cfg.windowsUpdate.enabled) { $results.Add( (Invoke-Component 'windowsUpdate' { Comp-WindowsUpdate $cfg }) ) }
if ($cfg.winget.enabled)        { $results.Add( (Invoke-Component 'winget'        { Comp-Winget $cfg }) ) }
if ($cfg.psModules.enabled) {
  $psEvery = [int]$cfg.psModules.everyDays; if ($psEvery -le 0) { $psEvery = 7 }
  if (Test-PSModulesDue $psEvery) {
    $r = Invoke-Component 'psModules' { Comp-PSModules }
    $results.Add($r)
    if ($r.status -ne 'error') { Set-PSModulesStamp }   # only stamp a clean run, so a failure retries tomorrow
  } else {
    Write-Log INFO "psModules: not due (runs every $psEvery days) — skipping this run."
  }
}

# The detached passes started by the LAST run finished after its result.json was written. Fold them
# in HERE — before the reboot decision and before updates[] is built — so an upgrade they made shows
# up in this run's dialog and history, a failure they hit is reported, and a reboot they asked for is
# actually acted on instead of being dropped on the floor.
$lastRunEnd = $null
if ($stamp -and $stamp.finishedLocal) {
  try { $lastRunEnd = [datetime]::Parse("$($stamp.finishedLocal)", $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { }
}
# The cursor is the moment the LAST run's ingest scan began — not when that run finished. A helper
# that writes its JSON after the scan has passed its directory but before the stamp is saved has a
# timestamp inside that gap: measured against the run's end it looks old and would be consumed
# unread, losing its upgrades, failures and reboot request for good. Taken before the scan, the gap
# falls on the safe side and the record is simply picked up next time.
# Held and compared in UTC throughout: a local-time cursor is ambiguous across the repeated hour of a
# daylight-saving fall-back, where it would read a newer record as older. Stamps written by earlier
# versions carry a local offset, which round-trip parsing converts correctly.
$ingestCursor = $null
if ($stamp -and $stamp.ingestCursor) {
  $ingestCursor = ConvertTo-UtcTime $stamp.ingestCursor
} elseif ($lastRunEnd) {
  $ingestCursor = $lastRunEnd.ToUniversalTime()   # stamp written by a version before the cursor existed
}
$ingestScanAt = (Get-Date).ToUniversalTime()      # becomes the next run's cursor
# Read the boot time BEFORE ingesting: a record whose helper finished before the last boot has had
# its reboot request satisfied already, and re-importing it would schedule a second, pointless one.
$bootUtc = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() } catch { $null }
$detached = Import-DetachedResults $ingestCursor $bootUtc

# A reboot a detached pass asked for must NOT be consumed by the run that ingests it. Under the
# default ifRequired policy with a user logged in, that run only offers a cancellable countdown — if
# it is postponed the record is already marked ingested, and since a winget-signalled reboot sets no
# OS pending flag, the requirement would vanish for good. So it is carried in the stamp and only
# cleared once the box has actually booted since the last run finished.
$bootedSinceLastRun = [bool]($bootUtc -and $lastRunEnd -and ($bootUtc -gt $lastRunEnd.ToUniversalTime()))
$carriedReboot = [bool]($stamp -and $stamp.handoffRebootPending) -and -not $bootedSinceLastRun
if ($carriedReboot -and -not $detached.reboot) {
  Write-Log INFO 'handoff: a previous detached pass still needs a reboot and none has happened since — carrying it forward.'
}
$handoffReboot = [bool]($detached.reboot -or $carriedReboot)

if ($detached.upgraded -gt 0 -or $detached.failed -gt 0 -or $handoffReboot) {
  $dStatus = if ($detached.failed -gt 0) { 'warn' } else { 'ok' }
  $dDetail = "$($detached.upgraded) upgraded, $($detached.failed) failed since the last run" + $(if ($handoffReboot) { '; reboot required' } else { '' })
  $results.Add([pscustomobject]([ordered]@{
    name        = 'handoff'
    status      = $dStatus
    detail      = $dDetail
    error       = $(if ($detached.failed -gt 0) { ($detached.notes -join '; ') } else { $null })
    reboot      = $handoffReboot
    durationSec = 0
    log         = 'run.log'
  }))
  Write-Log $(if ($dStatus -eq 'warn') { 'WARN' } else { 'INFO' }) "handoff: $dDetail$(if ($detached.notes.Count) { " ($($detached.notes -join '; '))" })"
  Add-Report ("- handoff: **{0}** {1}" -f $dStatus, $dDetail)
}

$rebootRequiredByRun = @($results | Where-Object reboot).Count -gt 0        # did THIS run's updates ask for it?
# ONE classified verdict for the whole run. It folds the OS servicing signals together with this
# run's own component signals (an ingested handoff is already one of $results, so it arrives here
# through $rebootRequiredByRun rather than separately). Everything downstream — the policy switch,
# the watchdog, result.json, the dialog payload and the tray — keys off this, so they cannot drift.
$rebootState   = Get-RebootState -RunRequired $rebootRequiredByRun
$rebootPending = $rebootState.Required
# Log the reasoning, not just the verdict: when this says "reboot pending" a human must be able to
# find out WHAT is asking, and when it dismisses a signal that must be on the record too.
foreach ($r in $rebootState.Reasons)  { Write-Log INFO "reboot: $r" }
foreach ($a in $rebootState.Advisory) { Write-Log INFO "reboot: ignored — $a" }
if (-not $rebootPending) { Write-Log INFO 'reboot: nothing outstanding.' }
$errors  = @($results | Where-Object status -eq 'error')
$warns   = @($results | Where-Object status -eq 'warn')
$endUtc  = (Get-Date).ToUniversalTime()
$durSec  = [math]::Round(($endUtc - $startUtc).TotalSeconds, 1)

# ---- collapse exact-duplicate update rows within THIS run -------------------
# Some sources legitimately emit the SAME logical update more than once in one run: Windows
# Update offers an APO/driver package once per matching audio endpoint, so a single run showed
# three byte-identical "AudioProcessingObject Driver Update (1.0.4.7057)" rows (same
# name|source|old|new|size). That tripled updates[] in history.jsonl AND tripled the dialog's
# totalSizeMB (87 MB reported for 29 MB of actual bytes — WU downloads the package once).
# Collapse rows identical in name|source|old|new|sizeMB into one, annotate the count (×N), and
# keep a SINGLE representative size so the total reflects reality. Rows that merely share a name
# but differ in version or size stay separate (size is part of the key).
if ($script:Updates.Count -gt 1) {
  # Accumulate by composite key while preserving first-seen order (Group-Object would re-sort the
  # rows alphabetically, needlessly shuffling the dialog).
  $order  = [System.Collections.Generic.List[string]]::new()
  $groups = @{}
  foreach ($u in $script:Updates) {
    $key = "$($u.name)|$($u.source)|$($u.old)|$($u.new)|$($u.sizeMB)"
    if (-not $groups.ContainsKey($key)) { $groups[$key] = [System.Collections.Generic.List[object]]::new(); $order.Add($key) }
    $groups[$key].Add($u)
  }
  $deduped = [System.Collections.Generic.List[object]]::new()
  foreach ($key in $order) {
    $grp   = $groups[$key]
    $first = $grp[0]
    # NOT $name: PowerShell variable names are CASE-INSENSITIVE, and this block runs at SCRIPT
    # scope, so `$name` here is the same variable as the global $Name = 'SunUp' set at the top.
    # It silently renamed the product to the last collapsed update, which is why runs logged
    # "===== Google Chrome run end =====" (2026-07-18) and "Tailscale run ... clean" (2026-07-28)
    # in the event log. Only bit when a run had 2+ updates, so it looked random.
    $rowName = if ($grp.Count -gt 1) { "$($first.name) $([char]0x00D7)$($grp.Count)" } else { "$($first.name)" }
    $dur   = ($grp | ForEach-Object { $_.durationSec } | Where-Object { $_ -ne $null } | Measure-Object -Maximum).Maximum
    $deduped.Add([ordered]@{ name=$rowName; source=$first.source; old=$first.old; new=$first.new; durationSec=$dur; sizeMB=$first.sizeMB })
  }
  $script:Updates = $deduped
}

# ---- structured result + history trail --------------------------------------
$result = [ordered]@{
  date          = $today
  runStamp      = $runStamp
  runDir        = $script:RunDir
  startUtc      = $startUtc.ToString('o')
  endUtc        = $endUtc.ToString('o')
  durationSec   = $durSec
  version       = $script:Version
  forced        = [bool]$Force
  rebootPending       = $rebootPending
  rebootRequiredByRun = $rebootRequiredByRun
  rebootSources       = @($rebootState.Sources)   # cbs / windowsUpdate / pendingRename / run / …
  rebootReasons       = @($rebootState.Reasons)   # the same sentences the run log carries
  rebootIgnored       = @($rebootState.Advisory)  # signals seen and dismissed, kept for audit
  rebootAction        = 'none'
  components          = $results
  updates             = @($script:Updates)
}
# What triggers the reboot depends on rebootPolicy (see $DefaultConfig for the three values):
#   always     — anything Get-RebootState confirms ($rebootPending): OS servicing signals as well as
#                this run's own. No longer the blunt option it was — v0.16.0 stopped a queued temp-file
#                deletion from counting, which under this policy would have restarted the box for it
#   ifRequired — only when THIS run's components reported reboot=true ($rebootRequiredByRun)
#   never      — never auto-reboot
# Ownership: user logged in → the dialog owns a cancellable countdown; headless → the engine
# reboots itself. An unrecognized policy is treated as 'never' (fail safe: never surprise-reboot).
$interactive      = Test-InteractiveUser
$graceInteractive = if ($cfg.rebootGraceInteractiveSec) { [int]$cfg.rebootGraceInteractiveSec } else { 300 }
$willReboot       = switch ("$($cfg.rebootPolicy)") {
  'always'     { $rebootPending }
  'ifRequired' { $rebootRequiredByRun }
  default      { $false }
}
if ($willReboot)        { $result.rebootAction = if ($interactive) { 'dialog-countdown' } else { 'reboot' } }
elseif ($rebootPending) { $result.rebootAction = 'suppressed' }

# The marker may only be dropped once result.json is REALLY on disk. $ErrorActionPreference is
# 'Continue', so a transient lock or I/O error would let Set-Content fail quietly — and clearing the
# marker anyway would leave a run with neither file: a peer could then declare this live run crashed,
# or the next run could call a completed run killed. If the write fails the marker stays, and the run
# is reported as never-finished — which is the truth: its result was never persisted.
$resultPath    = Join-Path $script:RunDir 'result.json'
$resultWritten = Publish-JsonFile $result $resultPath
if (-not $resultWritten) { Write-Log WARN "result.json missing — keeping running.json so this run is reported as unfinished." }
elseif ($script:RunMarker)   { Remove-Item $script:RunMarker -Force -ErrorAction SilentlyContinue }
$result | ConvertTo-Json -Depth 8 -Compress | Add-Content $HistoryFile
# trim history to last 365 runs
$h = @(Get-Content $HistoryFile); if ($h.Count -gt 365) { $h[-365..-1] | Set-Content $HistoryFile }

# ---- stale pending-reboot watchdog (guards the ifRequired blind spot) --------
# When we leave a pending state that no run required, track how long it has persisted (carried in
# the stamp) and alert ONCE past pendingRebootAlertDays — so a genuinely-needed reboot can't sit
# forever unnoticed. The tracker resets when the state clears and, as of v0.16.0, when the box has
# BOOTED since the last run.
#
# That second reset is not a refinement; it is the difference between this watchdog working and not.
# The old code reset only on observing $rebootPending false, which quietly assumes a pending signal
# survives until a restart consumes it. A SELF-RENEWING signal breaks that assumption outright: it
# is re-armed minutes into every boot, no run ever catches it clear, and pendingSince ratchets
# backwards forever. That is precisely how this box came to report a 7-day-old pending reboot on
# 2026-08-11 despite having restarted on both 08-08 and 08-11 — and the alert, being once-only,
# then stayed latched. A boot satisfies every reboot outstanding before it, so anything still
# pending afterwards is by definition NEW and must be dated from the boot, not from before it.
$pendingSince = $null; $pendingAlerted = $false
if ($rebootPending -and -not $willReboot) {
  $carryTracker   = [bool]($stamp -and $stamp.pendingSince -and -not $bootedSinceLastRun)
  if (-not $carryTracker -and $bootedSinceLastRun -and $stamp -and $stamp.pendingSince) {
    Write-Log INFO 'reboot: the box has booted since the last run — the stale-reboot timer starts again from now.'
  }
  $pendingSince   = if ($carryTracker) { "$($stamp.pendingSince)" } else { (Get-Date).ToString('o') }
  $pendingAlerted = [bool]($carryTracker -and $stamp.pendingAlerted)
  $alertDays = if ($cfg.PSObject.Properties.Name -contains 'pendingRebootAlertDays') { [double]$cfg.pendingRebootAlertDays } else { 3 }
  if ($alertDays -gt 0 -and -not $pendingAlerted) {
    $ageDays = try { ((Get-Date) - [datetime]::Parse($pendingSince, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalDays } catch { 0 }
    if ($ageDays -ge $alertDays) {
      # Name what is asking. "A reboot is pending" with no attribution is what made the old alert
      # impossible to act on: there was no way to tell a real servicing hold from a false positive.
      $why = if ($rebootState.Labels.Count) { ' (' + ($rebootState.Labels -join ', ') + ')' } else { '' }
      $m = ("Reboot has been pending {0:N1} days but no run required it" -f $ageDays) + $why +
           " (rebootPolicy=$($cfg.rebootPolicy)) — reboot when convenient."
      Write-Log WARN $m; Write-Evt 2006 Warning $m; Raise-SysSentryAlert $m
      $pendingAlerted = $true
    }
  }
}

# day stamp (marks today done so the other triggers no-op; carries the pending-reboot watchdog state)
# ingestCursor: when THIS run's detached-result scan began (see above) — anything a helper wrote
# after that point is still unread and must stay ingestable. Advanced ONLY when the scan actually
# ran: an ingest aborted because a concurrent engine held the lock examined nothing, and moving the
# cursor anyway would have the next run write off every record that already existed as stale.
$nextCursor = if ($detached.scanned) { $ingestScanAt.ToString('o') } elseif ($stamp) { "$($stamp.ingestCursor)" } else { '' }
if (-not $detached.scanned) { Write-Log INFO 'handoff: ingest did not run — leaving the cursor where it was.' }
# handoffRebootPending: survives until a boot is actually observed, so postponing the dialog's
# countdown cannot lose a reboot a detached pass asked for.
Save-StampMerged ([ordered]@{ date = $today; runStamp = $runStamp; runDir = $script:RunDir; finishedLocal = (Get-Date).ToString('o'); rebootPending = $rebootPending; pendingSince = $pendingSince; pendingAlerted = $pendingAlerted; handoffRebootPending = $handoffReboot; ingestCursor = $nextCursor }) $bootedSinceLastRun

$summary = ($results | ForEach-Object { "$($_.name)=$($_.status)" }) -join ', '
Write-Log INFO "Components: $summary  (total ${durSec}s)"
Add-Report "- Summary: $summary; rebootPending=$rebootPending; rebootAction=$($result.rebootAction); ${durSec}s"

if ($errors.Count -gt 0) {
  $msg = "$Name run $runStamp finished with errors: " + (($errors | ForEach-Object { $_.name }) -join ', ') + ". Drill in: $Name.ps1 -Mode Errors"
  Write-Evt 2010 Warning $msg
  Raise-SysSentryAlert $msg
} elseif ($warns.Count -gt 0) {
  # A warn is a component that did LESS than it was asked to — an incomplete winget upgrade list, a
  # package the handoff failed to upgrade. Logging event 2001 "clean" for those made a partly blocked
  # update path indistinguishable from a healthy run in the event log.
  Write-Evt 2002 Warning ("$Name run $runStamp completed with warnings: " + (($warns | ForEach-Object { "$($_.name) — $($_.detail)" }) -join '; '))
} else {
  Write-Evt 2001 Information "$Name run $runStamp clean: $summary"
}

Flush-Report

# ---- run-dir retention ------------------------------------------------------
try {
  $keep = [int]$cfg.keepRuns; if ($keep -lt 1) { $keep = 30 }
  Get-ChildItem $RunsDir -Directory | Sort-Object Name -Descending | Select-Object -Skip $keep |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
} catch { Write-Log WARN "run-dir retention: $_" }

# ---- notify dialog payload (shown after EVERY cycle; pendingShow gates display) ----
$notifyEnabled = (-not ($cfg.PSObject.Properties.Name -contains 'notify')) -or $cfg.notify.enabled
$totalSize = ($script:Updates | ForEach-Object { $_.sizeMB } | Where-Object { $_ } | Measure-Object -Sum).Sum
# Past-Ndays history (greyed in the dialog). Built here — AFTER history.jsonl was appended/trimmed
# above — and excludes the current run (already in items[]). Config-tunable; defaults: 30d, collapsed.
$histDays     = if ($cfg.notify.historyDays)     { [int]$cfg.notify.historyDays }     else { 30 }
$histCollapse = if ($cfg.notify.PSObject.Properties.Name -contains 'historyCollapse') { [bool]$cfg.notify.historyCollapse } else { $true }
$histMaxRows  = if ($cfg.notify.historyMaxRows)  { [int]$cfg.notify.historyMaxRows }  else { 500 }
$history = @(Get-UpdateHistory -Days $histDays -Collapse $histCollapse -ExcludeRunStamp $runStamp -MaxRows $histMaxRows)
$payload = [ordered]@{
  title              = if (@($script:Updates).Count -gt 0) { 'Updates installed' } else { 'Update check complete' }
  runDate            = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  totalDurationSec   = $durSec
  totalSizeMB        = if ($totalSize) { [math]::Round($totalSize, 1) } else { $null }
  rebootRequired      = $willReboot         # engine's authoritative "a reboot is intended" signal
  rebootRequiredByRun = $rebootRequiredByRun # true = run-signal reboot (may set no OS pending flag)
  runEndUtc           = $endUtc.ToString('o') # dialog compares to LastBootUpTime to flip pre/post
  rebootCountdownSec  = $graceInteractive
  pendingShow        = $true                # dialog clears this once shown (gates the logon trigger)
  items              = @($script:Updates)
  history            = $history             # past-Ndays updates, greyed below the current run
}
try { New-Item -ItemType Directory -Force -Path $NotifyDir | Out-Null } catch {}
try { $payload | ConvertTo-Json -Depth 6 | Set-Content $NotifyPayload } catch { Write-Log WARN "notify payload: $_" }

# ---- coordinated reboot -----------------------------------------------------
if ($willReboot -and $interactive) {
  Write-Log INFO "Reboot pending; interactive user — the dialog owns a ${graceInteractive}s countdown (engine will NOT reboot out from under you)."
  Write-Evt 2005 Warning "${Name}: ${graceInteractive}s restart countdown handed to the user dialog."
}
elseif ($willReboot) {
  Write-Log INFO "Reboot pending — headless reboot in $($cfg.rebootDelaySeconds)s (no user logged in); summary shows at next logon."
  Write-Evt 2005 Warning "${Name}: headless reboot in $($cfg.rebootDelaySeconds)s."
}
elseif ($rebootPending) {
  # An OS pending flag is set but we're not rebooting. Two very different cases:
  if ("$($cfg.rebootPolicy)" -eq 'never') {
    # User opted out of auto-reboot entirely — a genuine pending state is worth a nudge.
    Write-Log INFO 'Reboot pending but rebootPolicy=never — leaving box up.'
    Raise-SysSentryAlert 'A reboot is pending (rebootPolicy=never) — reboot when convenient.'
  } else {
    # ifRequired: the flag is set (e.g. a PnP driver's PendingFileRename) but no component this run
    # demanded a reboot. That's benign background state — note it, don't nag SysSentry every day.
    Write-Log INFO 'OS reboot-pending flag set, but no component this run required a reboot (rebootPolicy=ifRequired) — not rebooting.'
  }
}
else { Write-Log INFO 'No reboot required.' }

# Show the dialog now if a user is logged in (covers every cycle, even 0 updates). Headless
# runs leave pendingShow=true so the SunUp-Notify logon trigger shows it at next sign-in
# (also how the post-reboot summary appears). StopExisting makes a newer cycle replace it.
if ($notifyEnabled -and $interactive) {
  try { Start-ScheduledTask -TaskName $NotifyTask -ErrorAction Stop; Write-Log INFO "Launched $NotifyTask dialog." }
  catch { Write-Log WARN "could not start ${NotifyTask}: $_" }
}

# ---- user-scope winget pass --------------------------------------------------
# winget resolves installed packages PER USER, so HKCU-registered packages are invisible to this
# SYSTEM process entirely. Hand them to SunUp-User, which runs as the interactive user and shares
# this run's excludePattern. Requires a logged-on user (an Interactive task cannot run without a
# session), so a headless run simply leaves them for the next run that has one.
# NOT started when this run is going to reboot: the pass routinely runs longer than the interactive
# countdown (rebootGraceInteractiveSec, 300s by default), so the box would restart on top of a live
# `winget upgrade` — a half-replaced install directory and no record of what was attempted. The
# self-host handoff below has always skipped itself for exactly this reason; this one never did.
$userScopeEnabled = $cfg.winget.enabled -and
                    (($cfg.winget.PSObject.Properties.Name -notcontains 'userScope') -or $cfg.winget.userScope)
$userTaskStarted  = $false
if ($userScopeEnabled) {
  if (-not $interactive) {
    Write-Log INFO "user-scope: no interactive session — skipping $UserTask this run (per-user packages need a logged-on user)."
  } elseif ($willReboot) {
    Write-Log INFO "user-scope: a reboot is due this run — skipping $UserTask rather than have it cut off mid-upgrade; the next run picks those packages up."
  } else {
    try {
      $uStart = Start-TaskVerified $UserTask
      if ($uStart.ok) {
        $userTaskStarted = $true
        Write-Log INFO "user-scope: started $UserTask (per-user winget packages SYSTEM cannot see)."
      } else {
        $m = "user-scope: $UserTask did NOT start — $($uStart.reason). Per-user packages are not being upgraded this run."
        Write-Log WARN $m; Write-Evt 2031 Warning $m
      }
    } catch { Write-Log WARN "user-scope: could not start ${UserTask}: $_" }
  }
} elseif ($cfg.winget.enabled) {
  Write-Log INFO 'user-scope: disabled in config (winget.userScope=false) — machine scope only this run.'
}

Write-Log INFO "===== $Name run end ($runStamp) ====="
try { Stop-Transcript | Out-Null } catch {}

# ---- self-host handoff ------------------------------------------------------
# Registered and started only now: everything above (reboot decision, day stamp, history, dialog,
# transcript) is already committed, so when Restart Manager kills this pwsh — and it will — the run
# is already complete. The helper waits for THIS process id to exit before touching winget, and for
# the user-scope pass as well when one is running: that pass runs under pwsh 7, squarely inside the
# blast radius of the PowerShell upgrade this helper is about to perform, and killing it mid-upgrade
# loses its packages and its record of them.
if (@($script:SelfHostPending).Count -gt 0) {
  $shIds = @($script:SelfHostPending | ForEach-Object { $_.id })
  # Skipped only for the HEADLESS reboot, which is unconditional and imminent. When a user is logged
  # in, $willReboot only means the dialog offers a CANCELLABLE countdown — deferring on that alone
  # cost a full day every time someone clicked Postpone, on the strength of a reboot that then never
  # happened. Instead the helper sleeps past the countdown and upgrades if the box is still up; if
  # the user does restart, it dies with the box and the next run hands the packages off again.
  if ($result.rebootAction -eq 'reboot') {
    Write-Log INFO "self-host: headless reboot imminent — NOT starting $SelfHostTask this run (would race the shutdown). Deferred to the next run: $($shIds -join ', ')"
  } else {
    $shDelay = if ($result.rebootAction -eq 'dialog-countdown') { $graceInteractive + 60 } else { 0 }
    $shWaitTask = if ($userTaskStarted) { $UserTask } else { '' }
    try {
      $shScript = Join-Path $PSScriptRoot 'SelfHost.ps1'
      if (-not (Test-Path $shScript)) { throw "helper not found at $shScript" }
      # Windows PowerShell 5.1 on purpose — a separate installation, so Restart Manager shutting
      # down 'PowerShell 7' cannot reach it. Never change this to pwsh.exe.
      $shExe  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
      $shArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Ids {1} -RunDir "{2}" -MainLog "{3}" -EvtSource "{4}" -TaskName "{5}" -WaitForPid {6} -WaitForTask "{7}" -InitialDelaySec {8}' -f `
                $shScript, ($shIds -join ','), $script:RunDir, $LogFile, $EvtSource, $SelfHostTask, $PID, $shWaitTask, $shDelay
      $shAction    = New-ScheduledTaskAction -Execute $shExe -Argument $shArgs
      $shPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
      # 3 hours, not 1: the helper may now sit through the dialog countdown and a full user-scope pass
      # before it starts its own upgrades, and a task killed at its time limit writes no record.
      $shSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                       -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
      Register-ScheduledTask -TaskName $SelfHostTask -Action $shAction -Principal $shPrincipal -Settings $shSettings -Force `
        -Description "$Name one-shot: upgrade packages that own the engine's own runtime, after the engine has exited. Self-deletes." | Out-Null
      $shStart = Start-TaskVerified $SelfHostTask
      if ($shStart.ok) {
        $waits = @("pid $PID") + $(if ($shWaitTask) { @("task $shWaitTask") } else { @() }) + $(if ($shDelay -gt 0) { @("a ${shDelay}s reboot-countdown grace") } else { @() })
        Write-Log INFO "self-host: started $SelfHostTask (Windows PowerShell 5.1, waits for $($waits -join ' + ')) for: $($shIds -join ', ')"
        Write-Evt 2020 Information "${Name}: handed $(@($shIds).Count) self-hosting package(s) to ${SelfHostTask}: $($shIds -join ', ')"
      } else {
        # The start was a no-op, so nothing was handed anywhere — say that, instead of logging a
        # handoff and raising 2020 for an upgrade that will never happen.
        $m = "self-host: $SelfHostTask did NOT start — $($shStart.reason). $($shIds -join ', ') left for the next run."
        Write-Log WARN $m; Write-Evt 2021 Warning $m; Raise-SysSentryAlert $m
      }
    } catch {
      $m = "self-host: could not start ${SelfHostTask}: $_ — $($shIds -join ', ') left for the next run."
      Write-Log WARN $m; Write-Evt 2021 Warning $m; Raise-SysSentryAlert $m
    }
  }
}

# Headless reboot LAST (after logs/transcript flushed). Interactive reboot is the dialog's job.
if ($result.rebootAction -eq 'reboot') {
  $delay = [int]$cfg.rebootDelaySeconds
  & shutdown.exe /r /t $delay /c "${Name}: updates applied — rebooting in $([math]::Round($delay/60)) min. Run 'shutdown /a' to abort." /d p:2:4
}

# Explicit, meaningful exit code so Task Scheduler's LastTaskResult reflects the run —
# not a native exit code (e.g. Update-Module's access-denied on an in-use module) leaking through.
exit ([int]($errors.Count -gt 0))
