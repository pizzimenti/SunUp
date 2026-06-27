#Requires -RunAsAdministrator
<#
AutoUpdate — caldera's own daily update routine (replaces flaky Windows Update timing).

Runs as SYSTEM via three Task Scheduler triggers (all on the AutoUpdate task),
de-duplicated by a per-day stamp so the box updates exactly once per calendar day:
  * Daily 08:00  (only if the box is awake — the trigger never wakes it)
  * Boot   + 1h  (covers a cold boot where yesterday's run was missed)
  * Resume + 1h  (Power-Troubleshooter ID 1 — covers wake-from-sleep)
Whichever fires first does the work; the rest see the stamp and no-op.

Covers (config-toggled): Microsoft Defender signatures, Windows/Microsoft Update,
winget package upgrades, Dell Command Update drivers/firmware (BIOS reported only),
and PowerShell modules. One coordinated reboot at the end if anything needs it.

LOGGING (the point of v0.2.0 — three tiers so failures are trivial to find):
  C:\ProgramData\AutoUpdate\
    logs\autoupdate.log              curated rolling timeline (rotated at 5MB x5)
    logs\history.jsonl               one compact JSON line per run (queryable trail)
    logs\runs\<yyyy-MM-dd_HHmmss>\   isolated per-run dir, kept for last 30 runs:
        run.log                        this run's curated timeline
        transcript.log                 full Start-Transcript capture (belt + suspenders)
        <component>.log                RAW output of each tool (defender/windowsupdate/
                                       winget/dell-apply/dell-bios-scan/psmodules)
        result.json                    structured per-component result for this run
  Plus Application event log (source AutoUpdate) + SysSentry ALERTS.md on failure.

Query: Status.ps1, or  AutoUpdate.ps1 -Mode Errors  /  -Mode Tail.
Companion to ProcWatch (realtime CPU) and SysSentry (security drift).
#>
param(
  # Run = do the update; Status = overview; Errors = last failures + log pointers; Tail = last run.log tail.
  [ValidateSet('Run','Status','Errors','Tail')][string]$Mode = 'Run',
  # Bypass the once-per-day stamp (manual on-demand run / re-run after a failure).
  [switch]$Force
)

$ErrorActionPreference = 'Continue'
$script:Version = '0.2.0'

$Root        = 'C:\ProgramData\AutoUpdate'
$LogDir      = Join-Path $Root 'logs'
$LogFile     = Join-Path $LogDir 'autoupdate.log'
$HistoryFile = Join-Path $LogDir 'history.jsonl'
$RunsDir     = Join-Path $LogDir 'runs'
$ReportFile  = Join-Path $Root 'REPORT.md'
$ConfigFile  = Join-Path $Root 'config.json'
$StampFile   = Join-Path $Root 'lastrun.json'
$EvtSource   = 'AutoUpdate'
$SysSentryAlerts = 'C:\ProgramData\SysSentry\ALERTS.md'

$script:RunDir = $null   # set in Run mode once we create the per-run dir
$script:RunLog = $null

# ---- config -----------------------------------------------------------------
$DefaultConfig = [ordered]@{
  rebootPolicy       = 'always'
  rebootDelaySeconds = 120
  keepRuns           = 30            # how many per-run log dirs to retain
  windowsUpdate      = [ordered]@{ enabled = $true; notTitle = 'NVIDIA' }
  winget             = [ordered]@{ enabled = $true; pinIds = @() }
  defender           = [ordered]@{ enabled = $true }
  psModules          = [ordered]@{ enabled = $true }
  dell               = [ordered]@{ enabled = $true; applyTypes = 'driver,firmware,utility'; reportTypes = 'bios' }
  pip                = [ordered]@{ enabled = $false }
  npm                = [ordered]@{ enabled = $false }
}

function Get-Config {
  if (Test-Path $ConfigFile) {
    try { return (Get-Content $ConfigFile -Raw | ConvertFrom-Json) } catch { Write-Log WARN "config.json unreadable ($_), using defaults" }
  }
  return ($DefaultConfig | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
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
function Flush-Report {
  if ($script:Report.Count -eq 0) { return }
  $header = "## Run $((Get-Date).ToString('yyyy-MM-dd HH:mm')) — AutoUpdate v$script:Version (log: $([IO.Path]::GetFileName($script:RunDir)))"
  @('', $header) + $script:Report | Add-Content $ReportFile
  $all = @(Get-Content $ReportFile)
  if ($all.Count -gt 900) { ($all[0..4] + '_…older entries trimmed…_' + $all[-850..-1]) | Set-Content $ReportFile }
}

function Raise-SysSentryAlert { param($Msg)
  if (-not (Test-Path $SysSentryAlerts)) { return }
  try { "- **{0:yyyy-MM-dd HH:mm}** `[AUTOUPDATE`] {1}" -f (Get-Date), $Msg | Add-Content $SysSentryAlerts } catch {}
}

# ---- per-day stamp ----------------------------------------------------------
function Get-Stamp { if (Test-Path $StampFile) { try { Get-Content $StampFile -Raw | ConvertFrom-Json } catch { $null } } else { $null } }
function Save-Stamp { param($Obj) try { $Obj | ConvertTo-Json -Depth 8 | Set-Content $StampFile } catch { Write-Log WARN "could not write stamp: $_" } }

# ---- winget path resolver (SYSTEM can't see the per-user PATH shim) ----------
function Resolve-Winget {
  $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($cmd -and (Test-Path $cmd.Source)) { return $cmd.Source }
  $exe = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' -ErrorAction SilentlyContinue |
         Sort-Object FullName | Select-Object -Last 1
  if ($exe) { return $exe.FullName }
  return $null
}

# ---- pending-reboot detection ----------------------------------------------
function Test-PendingReboot {
  $paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
  )
  foreach ($p in $paths) { if (Test-Path $p) { return $true } }
  $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
  if ($pfro) { return $true }
  return $false
}

# ---- component runner: uniform timing + error capture + raw log -------------
# Each component scriptblock writes its raw output via Write-CompLog and returns
# @{ status='ok'|'warn'|'error'|'skip'; detail='one-line summary' }.
function Invoke-Component { param([string]$Name, [scriptblock]$Body)
  Write-Log INFO "${Name}: starting…"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $r  = [ordered]@{ name = $Name; status = 'error'; detail = ''; error = $null; durationSec = 0; log = "$Name.log" }
  try {
    $res = & $Body
    if ($res) { $r.status = $res.status; $r.detail = "$($res.detail)"; if ($res.error) { $r.error = "$($res.error)" } }
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
  Update-MpSignature -ErrorAction Stop
  $after = (Get-MpComputerStatus -ErrorAction Stop).AntivirusSignatureVersion
  Write-CompLog 'defender' "Signature after:  $after"
  $detail = if ($before -eq $after) { "signatures current ($after)" } else { "signatures $before -> $after" }
  @{ status = 'ok'; detail = $detail }
}

function Comp-WindowsUpdate { param($Cfg)
  if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
    Write-CompLog 'windowsupdate' 'PSWindowsUpdate module not installed — run Install.ps1.'
    return @{ status = 'error'; detail = 'PSWindowsUpdate module missing'; error = 'module not installed' }
  }
  Import-Module PSWindowsUpdate -ErrorAction Stop
  $params = @{ MicrosoftUpdate = $true; AcceptAll = $true; Install = $true; IgnoreReboot = $true }
  if ($Cfg.windowsUpdate.notTitle) { $params.NotTitle = $Cfg.windowsUpdate.notTitle }
  $res = @(Get-WindowsUpdate @params -Verbose -ErrorAction Stop 4>&1)
  Write-CompLog 'windowsupdate' $res
  $items     = @($res | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties.Name -contains 'Result' })
  $installed = @($items | Where-Object Result -eq 'Installed').Count
  $failed    = @($items | Where-Object Result -eq 'Failed').Count
  if ($items.Count -eq 0) { return @{ status = 'ok'; detail = 'up to date' } }
  $detail = "$installed installed, $failed failed ($($items.Count) offered)"
  if ($failed -gt 0) { return @{ status = 'error'; detail = $detail; error = "$failed update(s) failed — see windowsupdate.log" } }
  @{ status = 'ok'; detail = $detail }
}

function Comp-Winget { param($Cfg)
  $winget = Resolve-Winget
  if (-not $winget) { return @{ status = 'error'; detail = 'winget not found'; error = 'winget.exe not resolvable' } }
  Write-CompLog 'winget' "winget: $winget"
  foreach ($id in @($Cfg.winget.pinIds)) {
    if ($id) { Write-CompLog 'winget' (& $winget pin add --id $id --accept-source-agreements 2>&1) }
  }
  Write-CompLog 'winget' '--- available upgrades ---'
  Write-CompLog 'winget' (& $winget upgrade --include-unknown --accept-source-agreements 2>&1)
  Write-CompLog 'winget' '--- applying --all ---'
  $out  = & $winget upgrade --all --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
  $code = $LASTEXITCODE
  Write-CompLog 'winget' $out
  Write-CompLog 'winget' "exit: 0x$($code.ToString('X8'))"
  # winget returns non-zero for benign cases (e.g. 0x8A15002B = no applicable upgrades).
  if ($code -eq 0) { return @{ status = 'ok'; detail = 'upgrades applied' } }
  @{ status = 'warn'; detail = "completed (exit 0x$($code.ToString('X8')))" }
}

function Comp-Dell { param($Cfg)
  $dcu = @('C:\Program Files\Dell\CommandUpdate\dcu-cli.exe','C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe') |
         Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $dcu) { return @{ status = 'skip'; detail = 'dcu-cli not installed (hardware updates skipped)' } }
  Write-CompLog 'dell-apply' "dcu-cli: $dcu`nApplying: $($Cfg.dell.applyTypes) (BIOS excluded)"
  $apply = & $dcu /applyUpdates -updateType="$($Cfg.dell.applyTypes)" -autoSuspendBitLocker=enable -reboot=disable 2>&1
  $applyCode = $LASTEXITCODE
  Write-CompLog 'dell-apply' $apply
  Write-CompLog 'dell-apply' "exit: $applyCode"
  # Report (don't apply) BIOS so a human can decide. Capture the scan's CONSOLE output
  # directly — dcu's -outputLog file isn't reliably created (v0.1.0 bug), but it always
  # prints "Number of applicable updates: N" to stdout.
  $scanOut = & $dcu /scan -updateType="$($Cfg.dell.reportTypes)" 2>&1
  Write-CompLog 'dell-bios-scan' $scanOut
  $m = [regex]::Match(($scanOut | Out-String), 'applicable updates?\D*(\d+)')
  $biosCount = if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }
  if ($biosCount -gt 0) {
    Raise-SysSentryAlert "Dell BIOS update available ($biosCount, not auto-applied) — review the run dir dell-bios-scan.log"
    return @{ status = 'ok'; detail = "drivers/firmware applied (exit $applyCode); BIOS update AVAILABLE ($biosCount, not flashed)" }
  }
  $biosDetail = if ($biosCount -eq 0) { 'no BIOS update' } else { 'BIOS scan inconclusive (see dell-bios-scan.log)' }
  @{ status = 'ok'; detail = "drivers/firmware applied (exit $applyCode); $biosDetail" }
}

function Comp-PSModules {
  $out = Update-Module -Force -Confirm:$false -ErrorAction Continue 2>&1
  Write-CompLog 'psmodules' $out
  @{ status = 'ok'; detail = 'Update-Module run' }
}

# =====================  query modes  =========================================
function Get-LatestRunDir { Get-ChildItem $RunsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1 }
function Get-LatestResult {
  $d = Get-LatestRunDir
  if ($d -and (Test-Path "$($d.FullName)\result.json")) { return (Get-Content "$($d.FullName)\result.json" -Raw | ConvertFrom-Json) }
  $null
}

if ($Mode -eq 'Status') {
  $stamp = Get-Stamp
  $task  = Get-ScheduledTask -TaskName 'AutoUpdate' -ErrorAction SilentlyContinue
  $info  = if ($task) { $task | Get-ScheduledTaskInfo } else { $null }
  $res   = Get-LatestResult
  Write-Host ""
  Write-Host "AutoUpdate v$script:Version — caldera"
  Write-Host ("  Task state    : {0}" -f ($(if ($task) { $task.State } else { 'NOT REGISTERED' })))
  if ($info) {
    Write-Host ("  Last task run : {0} (result 0x{1:X8})" -f $info.LastRunTime, $info.LastTaskResult)
    Write-Host ("  Next run      : {0}" -f $info.NextRunTime)
  }
  Write-Host ("  Last update   : {0}" -f $(if ($stamp) { $stamp.date } else { '(never)' }))
  Write-Host ("  Reboot now    : {0}" -f (Test-PendingReboot))
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
      Write-Host "  -> failures present. Drill in:  AutoUpdate.ps1 -Mode Errors" -ForegroundColor Yellow
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
$runStamp      = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
$script:RunDir = Join-Path $RunsDir $runStamp
New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
$script:RunLog = Join-Path $script:RunDir 'run.log'
try { Start-Transcript -Path (Join-Path $script:RunDir 'transcript.log') -Force | Out-Null } catch {}

$startUtc = (Get-Date).ToUniversalTime()
Write-Log INFO "===== AutoUpdate v$script:Version run start ($today, forced=$([bool]$Force)) — $runStamp ====="
Write-Evt 2000 Information "AutoUpdate run started ($today) — logs in $script:RunDir"

$results = [System.Collections.Generic.List[object]]::new()
if ($cfg.defender.enabled)      { $results.Add( (Invoke-Component 'defender'      { Comp-Defender }) ) }
if ($cfg.windowsUpdate.enabled) { $results.Add( (Invoke-Component 'windowsUpdate' { Comp-WindowsUpdate $cfg }) ) }
if ($cfg.winget.enabled)        { $results.Add( (Invoke-Component 'winget'        { Comp-Winget $cfg }) ) }
if ($cfg.dell.enabled)          { $results.Add( (Invoke-Component 'dell'          { Comp-Dell $cfg }) ) }
if ($cfg.psModules.enabled)     { $results.Add( (Invoke-Component 'psModules'     { Comp-PSModules }) ) }

$rebootPending = Test-PendingReboot
$errors  = @($results | Where-Object status -eq 'error')
$endUtc  = (Get-Date).ToUniversalTime()
$durSec  = [math]::Round(($endUtc - $startUtc).TotalSeconds, 1)

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
  rebootPending = $rebootPending
  rebootAction  = 'none'
  components    = $results
}
# decide reboot action now so it's recorded in result.json
if ($rebootPending) { $result.rebootAction = if ($cfg.rebootPolicy -eq 'always') { 'reboot' } else { 'suppressed' } }

$result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:RunDir 'result.json')
$result | ConvertTo-Json -Depth 8 -Compress | Add-Content $HistoryFile
# trim history to last 365 runs
$h = @(Get-Content $HistoryFile); if ($h.Count -gt 365) { $h[-365..-1] | Set-Content $HistoryFile }

# day stamp (marks today done so the other triggers no-op)
Save-Stamp ([ordered]@{ date = $today; runStamp = $runStamp; runDir = $script:RunDir; finishedLocal = (Get-Date).ToString('o'); rebootPending = $rebootPending })

$summary = ($results | ForEach-Object { "$($_.name)=$($_.status)" }) -join ', '
Write-Log INFO "Components: $summary  (total ${durSec}s)"
Add-Report "- Summary: $summary; rebootPending=$rebootPending; rebootAction=$($result.rebootAction); ${durSec}s"

if ($errors.Count -gt 0) {
  $msg = "AutoUpdate run $runStamp finished with errors: " + (($errors | ForEach-Object { $_.name }) -join ', ') + ". Drill in: AutoUpdate.ps1 -Mode Errors"
  Write-Evt 2010 Warning $msg
  Raise-SysSentryAlert $msg
} else {
  Write-Evt 2001 Information "AutoUpdate run $runStamp clean: $summary"
}

Flush-Report

# ---- run-dir retention ------------------------------------------------------
try {
  $keep = [int]$cfg.keepRuns; if ($keep -lt 1) { $keep = 30 }
  Get-ChildItem $RunsDir -Directory | Sort-Object Name -Descending | Select-Object -Skip $keep |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
} catch { Write-Log WARN "run-dir retention: $_" }

# ---- coordinated reboot -----------------------------------------------------
if ($rebootPending -and $cfg.rebootPolicy -eq 'always') {
  $delay = [int]$cfg.rebootDelaySeconds
  Write-Log INFO "Reboot pending — rebooting in $delay s (policy=always). Abort with: shutdown /a"
  Write-Evt 2005 Warning "AutoUpdate applied updates; rebooting in $delay s."
  try { Stop-Transcript | Out-Null } catch {}
  & shutdown.exe /r /t $delay /c "AutoUpdate: updates applied — rebooting in $([math]::Round($delay/60)) min. Run 'shutdown /a' to abort." /d p:2:4
}
elseif ($rebootPending) {
  Write-Log INFO 'Reboot pending but rebootPolicy != always — leaving box up.'
  Write-Evt 2005 Warning 'AutoUpdate: reboot pending (policy=never). Manual reboot needed.'
  Raise-SysSentryAlert 'Reboot pending after updates (rebootPolicy=never) — reboot when convenient.'
}
else { Write-Log INFO 'No reboot required.' }

Write-Log INFO "===== AutoUpdate run end ($runStamp) ====="
try { Stop-Transcript | Out-Null } catch {}

# Explicit, meaningful exit code so Task Scheduler's LastTaskResult reflects the run —
# not a native exit code (e.g. Update-Module's access-denied on an in-use module) leaking through.
exit ([int]($errors.Count -gt 0))
