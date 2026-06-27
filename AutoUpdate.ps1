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

Outputs (C:\ProgramData\AutoUpdate): logs\autoupdate.log, REPORT.md (run digests),
config.json (toggles + exclusions, reload each run), lastrun.json (the day stamp).
Companion to ProcWatch (realtime CPU) and SysSentry (security drift).
#>
param(
  [ValidateSet('Run','Status')][string]$Mode = 'Run',
  # Bypass the once-per-day stamp (manual on-demand run / re-run after a failure).
  [switch]$Force
)

$ErrorActionPreference = 'Continue'
$script:Version = '0.1.0'

$Root        = 'C:\ProgramData\AutoUpdate'
$LogFile     = Join-Path $Root 'logs\autoupdate.log'
$ReportFile  = Join-Path $Root 'REPORT.md'
$ConfigFile  = Join-Path $Root 'config.json'
$StampFile   = Join-Path $Root 'lastrun.json'
$EvtSource   = 'AutoUpdate'
$SysSentryAlerts = 'C:\ProgramData\SysSentry\ALERTS.md'

# ---- config -----------------------------------------------------------------
$DefaultConfig = [ordered]@{
  rebootPolicy       = 'always'      # 'always' | 'never'  (this box: always, per Bradley 2026-06-27)
  rebootDelaySeconds = 120           # courtesy countdown so an interactive user can `shutdown /a`
  windowsUpdate      = [ordered]@{ enabled = $true; notTitle = 'NVIDIA' }   # NVIDIA pinned at 580.97 — never let WU push a GPU driver
  winget             = [ordered]@{ enabled = $true; pinIds = @() }          # exact winget IDs to hold back (e.g. a winget-managed driver); Claude Code is native, not winget
  defender           = [ordered]@{ enabled = $true }
  psModules          = [ordered]@{ enabled = $true }
  dell               = [ordered]@{ enabled = $true; applyTypes = 'driver,firmware,utility'; reportTypes = 'bios' }
  pip                = [ordered]@{ enabled = $false }   # off: global pip upgrades can break toolchains
  npm                = [ordered]@{ enabled = $false }   # off: global npm upgrades can break toolchains
}

function Get-Config {
  if (Test-Path $ConfigFile) {
    try { return (Get-Content $ConfigFile -Raw | ConvertFrom-Json) } catch { Write-Log WARN "config.json unreadable ($_), using defaults" }
  }
  return ($DefaultConfig | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
}

# ---- logging / reporting ----------------------------------------------------
function Write-Log { param($Level, $Msg)
  $line = "{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}" -f (Get-Date), $Level, $Msg
  try { Add-Content -Path $LogFile -Value $line } catch {}
  if ($Mode -eq 'Status') { Write-Host $line }
}

function Write-Evt { param([int]$Id, [string]$Type = 'Information', [string]$Msg)
  try { Write-EventLog -LogName Application -Source $EvtSource -EventId $Id -EntryType $Type -Message $Msg -ErrorAction Stop } catch {}
}

$script:Report = [System.Collections.Generic.List[string]]::new()
function Add-Report { param($Msg) $script:Report.Add($Msg) }

function Flush-Report {
  if ($script:Report.Count -eq 0) { return }
  $header = "## Run $((Get-Date).ToString('yyyy-MM-dd HH:mm')) — AutoUpdate v$script:Version"
  @('', $header) + $script:Report | Add-Content $ReportFile
  # Keep the digest from growing without bound (same idiom as SysSentry's REPORT.md).
  $all = @(Get-Content $ReportFile)
  if ($all.Count -gt 900) { ($all[0..4] + '_…older entries trimmed…_' + $all[-850..-1]) | Set-Content $ReportFile }
}

# Surface failures where the session-start triage already looks (SysSentry ALERTS.md).
function Raise-SysSentryAlert { param($Msg)
  if (-not (Test-Path $SysSentryAlerts)) { return }
  try { "- **{0:yyyy-MM-dd HH:mm}** `[AUTOUPDATE`] {1}" -f (Get-Date), $Msg | Add-Content $SysSentryAlerts } catch {}
}

# ---- per-day stamp ----------------------------------------------------------
function Get-Stamp { if (Test-Path $StampFile) { try { Get-Content $StampFile -Raw | ConvertFrom-Json } catch { $null } } else { $null } }
function Save-Stamp { param($Obj) try { $Obj | ConvertTo-Json -Depth 6 | Set-Content $StampFile } catch { Write-Log WARN "could not write stamp: $_" } }

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

# =====================  update components  ===================================

function Invoke-Defender {
  Write-Log INFO 'Defender: updating signatures…'
  try {
    $before = (Get-MpComputerStatus -ErrorAction Stop).AntivirusSignatureVersion
    Update-MpSignature -ErrorAction Stop
    $after = (Get-MpComputerStatus -ErrorAction Stop).AntivirusSignatureVersion
    $m = if ($before -eq $after) { "Defender signatures current ($after)" } else { "Defender signatures $before -> $after" }
    Write-Log INFO $m; Add-Report "- $m"; return 'ok'
  } catch { Write-Log ERROR "Defender: $_"; Add-Report "- [ERROR] Defender signature update failed: $_"; return 'error' }
}

function Invoke-WindowsUpdate { param($Cfg)
  Write-Log INFO 'WindowsUpdate: scanning…'
  if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
    Write-Log ERROR 'WindowsUpdate: PSWindowsUpdate module not installed (run Install.ps1).'
    Add-Report '- [ERROR] Windows Update skipped — PSWindowsUpdate module missing'; return 'error'
  }
  try {
    Import-Module PSWindowsUpdate -ErrorAction Stop
    $notTitle = $Cfg.windowsUpdate.notTitle
    # -MicrosoftUpdate widens scope to other MS products (Office, etc.). -IgnoreReboot:
    # we do ONE coordinated reboot at the end across all components. -NotTitle holds back
    # the pinned NVIDIA GPU driver so WU can't replace 580.97.
    $params = @{ MicrosoftUpdate = $true; AcceptAll = $true; Install = $true; IgnoreReboot = $true }
    if ($notTitle) { $params.NotTitle = $notTitle }
    $res = @(Get-WindowsUpdate @params -ErrorAction Stop)
    if ($res.Count -eq 0) { Write-Log INFO 'WindowsUpdate: nothing to install.'; Add-Report '- Windows Update: up to date'; return 'ok' }
    foreach ($u in $res) { Write-Log INFO ("WindowsUpdate: {0} -> {1}" -f $u.Title, $u.Result) }
    $installed = @($res | Where-Object Result -eq 'Installed').Count
    $failed    = @($res | Where-Object Result -eq 'Failed').Count
    Add-Report "- Windows Update: $installed installed, $failed failed ($($res.Count) offered)"
    if ($failed -gt 0) { return 'error' }
    return 'ok'
  } catch {
    Write-Log ERROR "WindowsUpdate: $_"; Add-Report "- [ERROR] Windows Update failed: $_"; return 'error'
  }
}

function Invoke-Winget { param($Cfg)
  $winget = Resolve-Winget
  if (-not $winget) { Write-Log ERROR 'winget: executable not found.'; Add-Report '- [ERROR] winget not found'; return 'error' }
  Write-Log INFO "winget: using $winget"
  try {
    # Hold back any configured exact IDs (e.g. a winget-managed driver). pin add on a
    # not-installed id just errors harmlessly. `winget upgrade --all` skips pinned packages.
    foreach ($id in @($Cfg.winget.pinIds)) {
      if ($id) { & $winget pin add --id $id --accept-source-agreements 2>&1 | Out-Null }
    }
    # Visibility: log what's available before applying.
    $avail = & $winget upgrade --include-unknown --accept-source-agreements 2>&1
    $avail | ForEach-Object { Write-Log INFO "winget: $_" }
    $out = & $winget upgrade --all --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    $out | ForEach-Object { Write-Log INFO "winget: $_" }
    $code = $LASTEXITCODE
    # winget returns non-zero for benign cases too (e.g. 0x8A15002B = no applicable upgrades).
    if ($code -eq 0) { Add-Report '- winget: upgrades applied'; return 'ok' }
    Write-Log WARN "winget: exit 0x$($code.ToString('X8'))"; Add-Report "- winget: completed (exit 0x$($code.ToString('X8')))"; return 'ok'
  } catch { Write-Log ERROR "winget: $_"; Add-Report "- [ERROR] winget failed: $_"; return 'error' }
}

function Invoke-Dell { param($Cfg)
  $dcu = @('C:\Program Files\Dell\CommandUpdate\dcu-cli.exe','C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe') |
         Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $dcu) {
    Write-Log WARN 'Dell: dcu-cli not installed — hardware updates skipped (install Dell.CommandUpdate).'
    Add-Report '- Dell Command Update: not installed (hardware updates skipped)'; return 'skip'
  }
  Write-Log INFO "Dell: using $dcu"
  try {
    # Apply only the safe update types; BIOS is reported, never auto-flashed (brick risk on power loss).
    Write-Log INFO "Dell: applying $($Cfg.dell.applyTypes) (BIOS excluded)…"
    $apply = & $dcu /applyUpdates -updateType="$($Cfg.dell.applyTypes)" -autoSuspendBitLocker=enable -reboot=disable 2>&1
    $apply | ForEach-Object { Write-Log INFO "Dell: $_" }
    $applyCode = $LASTEXITCODE
    # Report (don't apply) BIOS so a human can decide.
    $biosLog = Join-Path $Root 'dell-bios-scan.log'
    & $dcu /scan -updateType="$($Cfg.dell.reportTypes)" -outputLog="$biosLog" 2>&1 | Out-Null
    $biosAvail = (Select-String -Path $biosLog -Pattern 'Number of applicable updates' -ErrorAction SilentlyContinue | Select-Object -Last 1).Line
    Add-Report "- Dell Command Update: drivers/firmware applied (exit $applyCode). BIOS scan: $($biosAvail ?? 'see dell-bios-scan.log')"
    if ($biosAvail -and $biosAvail -notmatch ': 0\b') {
      Raise-SysSentryAlert "Dell BIOS update available (not auto-applied) — review dell-bios-scan.log"
      Write-Log WARN "Dell: BIOS update available — $biosAvail"
    }
    # dcu exit 1 = success, reboot required; 5 = reboot required. Surface via pending-reboot at the end.
    return 'ok'
  } catch { Write-Log ERROR "Dell: $_"; Add-Report "- [ERROR] Dell Command Update failed: $_"; return 'error' }
}

function Invoke-PSModules {
  Write-Log INFO 'PSModules: updating installed gallery modules…'
  try {
    Update-Module -Force -ErrorAction Continue -Confirm:$false 2>&1 | ForEach-Object { Write-Log INFO "PSModules: $_" }
    Add-Report '- PowerShell modules: Update-Module run'; return 'ok'
  } catch { Write-Log WARN "PSModules: $_"; Add-Report "- PowerShell modules: $_"; return 'warn' }
}

# =====================  Status mode  =========================================
if ($Mode -eq 'Status') {
  $stamp = Get-Stamp
  $task  = Get-ScheduledTask -TaskName 'AutoUpdate' -ErrorAction SilentlyContinue
  $info  = if ($task) { $task | Get-ScheduledTaskInfo } else { $null }
  Write-Host ""
  Write-Host "AutoUpdate v$script:Version — caldera"
  Write-Host ("  Task state    : {0}" -f ($(if ($task) { $task.State } else { 'NOT REGISTERED' })))
  if ($info) {
    Write-Host ("  Last run      : {0} (result 0x{1:X8})" -f $info.LastRunTime, $info.LastTaskResult)
    Write-Host ("  Next run      : {0}" -f $info.NextRunTime)
  }
  if ($stamp) {
    Write-Host ("  Last update   : {0}" -f $stamp.date)
    Write-Host ("  Reboot pending: {0}" -f $stamp.rebootPending)
    Write-Host  "  Components    :"
    $stamp.components.PSObject.Properties | ForEach-Object { Write-Host ("    - {0,-14}: {1}" -f $_.Name, $_.Value) }
  } else { Write-Host "  Last update   : (never)" }
  Write-Host ("  Reboot now    : {0}" -f (Test-PendingReboot))
  Write-Host ("  Logs          : {0}" -f $LogFile)
  Write-Host ""
  return
}

# =====================  Run mode  ============================================
$cfg   = Get-Config
$today = (Get-Date).ToString('yyyy-MM-dd')
$stamp = Get-Stamp

if (-not $Force -and $stamp -and $stamp.date -eq $today) {
  Write-Log INFO "Already updated today ($today) — skipping. (-Force to override.)"
  return
}

Write-Log INFO "===== AutoUpdate v$script:Version run start ($today) ====="
Write-Evt 2000 Information "AutoUpdate run started ($today)"

$components = [ordered]@{}
if ($cfg.defender.enabled)      { $components.defender      = Invoke-Defender }
if ($cfg.windowsUpdate.enabled) { $components.windowsUpdate = Invoke-WindowsUpdate $cfg }
if ($cfg.winget.enabled)        { $components.winget        = Invoke-Winget $cfg }
if ($cfg.dell.enabled)          { $components.dell          = Invoke-Dell $cfg }
if ($cfg.psModules.enabled)     { $components.psModules     = Invoke-PSModules }

$rebootPending = Test-PendingReboot
$errors = @($components.GetEnumerator() | Where-Object { $_.Value -eq 'error' })

# Persist the day stamp (marks today done so the other triggers no-op).
Save-Stamp ([ordered]@{
  date          = $today
  finishedLocal = (Get-Date).ToString('o')
  version       = $script:Version
  components    = $components
  rebootPending = $rebootPending
})

$summary = ($components.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
Write-Log INFO "Components: $summary"
Add-Report "- Summary: $summary; rebootPending=$rebootPending"

if ($errors.Count -gt 0) {
  $msg = "AutoUpdate completed with errors: " + (($errors | ForEach-Object { $_.Key }) -join ', ')
  Write-Evt 2010 Warning $msg
  Raise-SysSentryAlert $msg
} else {
  Write-Evt 2001 Information "AutoUpdate completed cleanly: $summary"
}

Flush-Report

# ---- coordinated reboot -----------------------------------------------------
if ($rebootPending) {
  if ($cfg.rebootPolicy -eq 'always') {
    $delay = [int]$cfg.rebootDelaySeconds
    Write-Log INFO "Reboot pending — rebooting in $delay s (policy=always). Abort with: shutdown /a"
    Write-Evt 2005 Warning "AutoUpdate applied updates; rebooting in $delay s."
    # /d p:2:4 = Planned, Operating System, Recommended. The native warning notifies any logged-in user.
    & shutdown.exe /r /t $delay /c "AutoUpdate: updates applied — rebooting in $([math]::Round($delay/60)) min. Run 'shutdown /a' to abort." /d p:2:4
  } else {
    Write-Log INFO 'Reboot pending but rebootPolicy != always — leaving box up.'
    Write-Evt 2005 Warning 'AutoUpdate: reboot pending (policy=never). Manual reboot needed.'
    Raise-SysSentryAlert 'Reboot pending after updates (rebootPolicy=never) — reboot when convenient.'
  }
} else {
  Write-Log INFO 'No reboot required.'
}

Write-Log INFO "===== AutoUpdate run end ====="
