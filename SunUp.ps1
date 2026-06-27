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
winget package upgrades, Dell Command Update drivers/firmware (BIOS reported only),
and PowerShell modules. One coordinated reboot at the end if anything needs it.

LOGGING (the point of v0.2.0 — three tiers so failures are trivial to find):
  C:\ProgramData\SunUp\
    logs\sunup.log                   curated rolling timeline (rotated at 5MB x5)
    logs\history.jsonl               one compact JSON line per run (queryable trail)
    logs\runs\<yyyy-MM-dd_HHmmss>\   isolated per-run dir, kept for last 30 runs:
        run.log                        this run's curated timeline
        transcript.log                 full Start-Transcript capture (belt + suspenders)
        <component>.log                RAW output of each tool (defender/windowsupdate/
                                       winget/dell-apply/dell-bios-scan/psmodules)
        result.json                    structured per-component result for this run
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
$script:Version = '0.6.0'

# One name to rule them all — every path, task name, event source, and the dialog title
# derive from $Name, so a future rename is a one-line change (and a half-rename is impossible).
$Name          = 'SunUp'
$TaskName      = $Name                 # SYSTEM engine task
$NotifyTask    = "$Name-Notify"        # interactive dialog task
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

# ---- config -----------------------------------------------------------------
$DefaultConfig = [ordered]@{
  rebootPolicy       = 'always'
  rebootDelaySeconds = 120           # headless (no user logged in) restart grace
  rebootGraceInteractiveSec = 300    # countdown the dialog shows when a user IS logged in
  keepRuns           = 30            # how many per-run log dirs to retain
  # Win11 summary dialog after a run. The dialog also lists the past `historyDays` of updates
  # (greyed out, below the current run); historyCollapse keeps only the latest per package so
  # daily Defender-signature bumps don't flood the list.
  notify             = [ordered]@{ enabled = $true; historyDays = 30; historyCollapse = $true; historyMaxRows = 500 }
  windowsUpdate      = [ordered]@{ enabled = $true; notTitle = 'NVIDIA' }
  # Skip pinned drivers, self-updating Claude, and load-bearing per-user/Electron apps whose
  # uninstaller refuses to run while the app is open (LM Studio :1234 API, Spotify, etc.).
  winget             = [ordered]@{ enabled = $true; pinIds = @(); excludePattern = 'NVIDIA|GeForce|Claude|Anthropic|ElementLabs|LM ?Studio|Spotify|Discord|Slack|Teams' }
  defender           = [ordered]@{ enabled = $true }
  psModules          = [ordered]@{ enabled = $true; everyDays = 7 }   # PSGallery modules: weekly, not daily (slow + rarely changes)
  dell               = [ordered]@{ enabled = $true; applyTypes = 'driver,firmware,utility'; reportTypes = 'bios' }
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

function Raise-SysSentryAlert { param($Msg)
  if (-not (Test-Path $SysSentryAlerts)) { return }
  try { "- **{0:yyyy-MM-dd HH:mm}** `[$($Name.ToUpper())`] {1}" -f (Get-Date), $Msg | Add-Content $SysSentryAlerts } catch {}
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
  if ($Cfg.windowsUpdate.notTitle) { $params.NotTitle = $Cfg.windowsUpdate.notTitle }
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
# Largest "/ N MB" total in winget's download chatter → download size in MB.
function Get-WingetSizeMB { param([string]$Text)
  $tot = 0.0
  foreach ($m in [regex]::Matches($Text, '/\s*(\d+(?:\.\d+)?)\s*(KB|MB|GB)')) {
    $v = [double]$m.Groups[1].Value
    switch ($m.Groups[2].Value) { 'KB' { $v /= 1024 } 'GB' { $v *= 1024 } }
    if ($v -gt $tot) { $tot = $v }
  }
  if ($tot -gt 0) { [math]::Round($tot, 1) } else { $null }
}

function Comp-Winget { param($Cfg)
  $winget = Resolve-Winget
  if (-not $winget) { return @{ status = 'error'; detail = 'winget not found'; error = 'winget.exe not resolvable' } }
  Write-CompLog 'winget' "winget: $winget"
  $listRaw = & $winget upgrade --include-unknown --accept-source-agreements 2>&1
  Write-CompLog 'winget' @('--- available ---') ; Write-CompLog 'winget' $listRaw
  $pending = Parse-WingetUpgrades ([string[]]($listRaw -split "`r?`n"))
  $excl = $Cfg.winget.excludePattern
  if ($excl) { $pending = @($pending | Where-Object { $_.name -notmatch $excl -and $_.id -notmatch $excl }) }
  if (@($pending).Count -eq 0) { return @{ status = 'ok'; detail = 'up to date' } }

  # Exit codes that mean "installed OK, but a reboot is needed" (MSI 3010 + winget's own).
  $rebootCodes = 3010, 0x8A150077, 0x8A150078, 0x8A150079
  $ok = 0; $fail = 0; $reboot = $false
  foreach ($p in $pending) {
    Write-CompLog 'winget' "--- upgrading $($p.id) ($($p.old) -> $($p.new)) ---"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $o  = & $winget upgrade --id $p.id -e --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    $sw.Stop(); $code = $LASTEXITCODE
    $txt = $o | Out-String
    Write-CompLog 'winget' $o ; Write-CompLog 'winget' "exit: 0x$($code.ToString('X8')), $([int]$sw.Elapsed.TotalSeconds)s"
    if ($code -eq 0 -or $code -in $rebootCodes) {
      $ok++
      if ($code -in $rebootCodes) { $reboot = $true; Write-Log INFO "winget: $($p.id) installed — reboot required" }
      Add-Update -Name $p.name -Source 'winget' -Old $p.old -New $p.new -DurationSec ([math]::Round($sw.Elapsed.TotalSeconds,1)) -SizeMB (Get-WingetSizeMB $txt)
    } else { $fail++; Write-Log WARN "winget: $($p.id) exit 0x$($code.ToString('X8'))" }
  }
  $detail = "$ok upgraded, $fail failed (of $(@($pending).Count))" + $(if ($reboot) { '; reboot required' } else { '' })
  if ($fail -gt 0) { return @{ status = 'warn'; detail = $detail; error = "see winget.log"; reboot = $reboot } }
  @{ status = 'ok'; detail = $detail; reboot = $reboot }
}

# Parse dcu-cli's `/scan -report` XML into per-update records. The report lists every APPLICABLE
# update with its name, AVAILABLE version, size (bytes), and type — everything we need for the table
# EXCEPT the currently-installed (old) version, which dcu-cli does not expose anywhere.
function Parse-DcuReport { param([string]$XmlPath)
  if (-not (Test-Path $XmlPath)) { return @() }
  try { [xml]$r = Get-Content $XmlPath -Raw } catch { return @() }
  $out = @()
  foreach ($u in $r.SelectNodes('//*[local-name()="update"]')) {
    $g = { param($n) ($u.ChildNodes | Where-Object { $_.LocalName -eq $n } | Select-Object -First 1).InnerText }
    $bytes = 0L; [void][long]::TryParse("$(& $g 'bytes')", [ref]$bytes)
    $out += [pscustomobject]@{
      release = "$(& $g 'release')"; name = "$(& $g 'name')"; version = "$(& $g 'version')"
      type    = "$(& $g 'type')";    category = "$(& $g 'category')"; urgency = "$(& $g 'urgency')"; bytes = $bytes
    }
  }
  $out
}

function Comp-Dell { param($Cfg)
  $dcu = @('C:\Program Files\Dell\CommandUpdate\dcu-cli.exe','C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe') |
         Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $dcu) { return @{ status = 'skip'; detail = 'dcu-cli not installed (hardware updates skipped)' } }

  # 1. Scan to an XML report FIRST — this is the only source of each update's name, available version
  #    and size (the apply output carries none of it). One scan covers all types; we partition into
  #    what we apply (driver/firmware/utility) vs BIOS (report-only).
  $reportDir = $script:RunDir
  $scanOut = & $dcu /scan -report="$reportDir" -silent 2>&1
  Write-CompLog 'dell-bios-scan' $scanOut
  $avail   = Parse-DcuReport (Join-Path $reportDir 'DCUApplicableUpdates.xml')
  $bios    = @($avail | Where-Object { "$($_.type)" -match 'BIOS' })
  $nonBios = @($avail | Where-Object { "$($_.type)" -notmatch 'BIOS' })   # driver/firmware/application = what we apply
  Write-CompLog 'dell-apply' "dcu-cli: $dcu`nApplying: $($Cfg.dell.applyTypes) (BIOS excluded). Scan found $($nonBios.Count) non-BIOS + $($bios.Count) BIOS applicable."

  # 2. Apply driver/firmware/utility (BIOS excluded), timing the batch.
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $apply = & $dcu /applyUpdates -updateType="$($Cfg.dell.applyTypes)" -autoSuspendBitLocker=enable -reboot=disable 2>&1
  $sw.Stop(); $applyCode = $LASTEXITCODE
  $applyDur = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  Write-CompLog 'dell-apply' $apply
  Write-CompLog 'dell-apply' "exit: $applyCode (${applyDur}s)"

  # 3. Interpret dcu-cli's exit code. 0 = applied (no reboot); 1 = applied (reboot required);
  #    5 = reboot pending from a PRIOR op (nothing applied now); 500 = no applicable updates;
  #    anything else = surface as a warning (see dell-apply.log).
  $applied = $applyCode -in 0, 1
  $reboot  = ($applyCode -eq 1)

  # 4. Record each applied update from the scan report: real name + available (new) version + size.
  #    When the apply installed our non-BIOS set (exit 0/1), those report entries ARE what installed.
  #    old stays "—" (dcu exposes no installed version); duration is the batch time (no per-driver timing).
  if ($applied) {
    foreach ($u in $nonBios) {
      $mb = if ($u.bytes -gt 0) { [math]::Round($u.bytes / 1MB, 1) } else { $null }
      Add-Update -Name $u.name -Source 'Dell' -Old '—' -New $u.version -DurationSec $applyDur -SizeMB $mb
    }
  }

  # 5. BIOS: report only — a human decides (unattended flash = brick risk on power loss).
  if ($bios.Count -gt 0) {
    Raise-SysSentryAlert ("Dell BIOS update available ({0}, not auto-applied): {1}" -f $bios.Count, (($bios | ForEach-Object { "$($_.name) $($_.version)" }) -join '; '))
  }

  # 6. Build the status line from the exit code.
  $applyDetail = switch ($applyCode) {
    0       { "applied $($nonBios.Count) driver/firmware update(s)" }
    1       { "applied $($nonBios.Count) driver/firmware update(s); reboot required" }
    5       { 'nothing applied (reboot pending from a prior op)' }
    500     { 'no applicable driver/firmware updates' }
    default { "dcu exit $applyCode (see dell-apply.log)" }
  }
  $biosDetail = if ($bios.Count -gt 0) { "; BIOS update AVAILABLE ($($bios.Count), not flashed)" } else { '; no BIOS update' }
  $status = if ($applyCode -in 0, 1, 5, 500) { 'ok' } else { 'warn' }
  $out = @{ status = $status; reboot = $reboot; detail = "$applyDetail$biosDetail" }
  if ($status -eq 'warn') { $out.error = "dcu-cli exit $applyCode — see dell-apply.log" }
  $out
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
# {when,name,source,old,new,durationSec,sizeMB}, newest-first, capped at MaxRows. Collapse keeps only
# the latest occurrence per name|source (so daily Defender-signature bumps don't flood the list).
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
      $rows.Add([ordered]@{ when = $run.date; name = $u.name; source = $u.source; old = $u.old; new = $u.new; durationSec = $u.durationSec; sizeMB = $u.sizeMB })
    }
  }
  if ($Collapse) {
    $rows = @($rows | Group-Object { "$($_.name)|$($_.source)" } | ForEach-Object { $_.Group | Sort-Object when | Select-Object -Last 1 })
  }
  @($rows | Sort-Object when -Descending | Select-Object -First $MaxRows)
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
$runStamp      = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
$script:RunDir = Join-Path $RunsDir $runStamp
New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
$script:RunLog = Join-Path $script:RunDir 'run.log'
try { Start-Transcript -Path (Join-Path $script:RunDir 'transcript.log') -Force | Out-Null } catch {}

$startUtc = (Get-Date).ToUniversalTime()
Write-Log INFO "===== $Name v$script:Version run start ($today, forced=$([bool]$Force)) — $runStamp ====="
Write-Evt 2000 Information "$Name run started ($today) — logs in $script:RunDir"

$results = [System.Collections.Generic.List[object]]::new()
if ($cfg.defender.enabled)      { $results.Add( (Invoke-Component 'defender'      { Comp-Defender }) ) }
if ($cfg.windowsUpdate.enabled) { $results.Add( (Invoke-Component 'windowsUpdate' { Comp-WindowsUpdate $cfg }) ) }
if ($cfg.winget.enabled)        { $results.Add( (Invoke-Component 'winget'        { Comp-Winget $cfg }) ) }
if ($cfg.dell.enabled)          { $results.Add( (Invoke-Component 'dell'          { Comp-Dell $cfg }) ) }
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

$rebootPending       = Test-PendingReboot                                  # global state (info/Status only)
$rebootRequiredByRun = @($results | Where-Object reboot).Count -gt 0        # did THIS run's updates ask for it?
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
  rebootPending       = $rebootPending
  rebootRequiredByRun = $rebootRequiredByRun
  rebootAction        = 'none'
  components          = $results
  updates             = @($script:Updates)
}
# Reboot when one is actually PENDING when checked — Chrome sets no pending flag (no prompt),
# Dell/WU drivers do (countdown). Ownership: user logged in → the dialog owns a cancellable
# countdown; headless → the engine reboots itself. policy=never never reboots.
$interactive      = Test-InteractiveUser
$graceInteractive = if ($cfg.rebootGraceInteractiveSec) { [int]$cfg.rebootGraceInteractiveSec } else { 300 }
$willReboot       = $rebootPending -and $cfg.rebootPolicy -eq 'always'
if ($willReboot)        { $result.rebootAction = if ($interactive) { 'dialog-countdown' } else { 'reboot' } }
elseif ($rebootPending) { $result.rebootAction = 'suppressed' }

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
  $msg = "$Name run $runStamp finished with errors: " + (($errors | ForEach-Object { $_.name }) -join ', ') + ". Drill in: $Name.ps1 -Mode Errors"
  Write-Evt 2010 Warning $msg
  Raise-SysSentryAlert $msg
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
  rebootRequired     = $willReboot          # dialog re-checks live pending state to flip pre/post
  rebootCountdownSec = $graceInteractive
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
  Write-Log INFO 'Reboot pending but rebootPolicy != always — leaving box up.'
  Raise-SysSentryAlert 'A reboot is pending (rebootPolicy=never) — reboot when convenient.'
}
else { Write-Log INFO 'No reboot required.' }

# Show the dialog now if a user is logged in (covers every cycle, even 0 updates). Headless
# runs leave pendingShow=true so the SunUp-Notify logon trigger shows it at next sign-in
# (also how the post-reboot summary appears). StopExisting makes a newer cycle replace it.
if ($notifyEnabled -and $interactive) {
  try { Start-ScheduledTask -TaskName $NotifyTask -ErrorAction Stop; Write-Log INFO "Launched $NotifyTask dialog." }
  catch { Write-Log WARN "could not start ${NotifyTask}: $_" }
}

Write-Log INFO "===== $Name run end ($runStamp) ====="
try { Stop-Transcript | Out-Null } catch {}

# Headless reboot LAST (after logs/transcript flushed). Interactive reboot is the dialog's job.
if ($result.rebootAction -eq 'reboot') {
  $delay = [int]$cfg.rebootDelaySeconds
  & shutdown.exe /r /t $delay /c "${Name}: updates applied — rebooting in $([math]::Round($delay/60)) min. Run 'shutdown /a' to abort." /d p:2:4
}

# Explicit, meaningful exit code so Task Scheduler's LastTaskResult reflects the run —
# not a native exit code (e.g. Update-Module's access-denied on an in-use module) leaking through.
exit ([int]($errors.Count -gt 0))
