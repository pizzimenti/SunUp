<#
SunUp-Tray.ps1 — a persistent system-tray presence for SunUp.

Windows has no `systemctl`/service-manager face for a scheduled task, so this gives SunUp one:
a tray icon (sun; amber when a reboot is pending) with a right-click menu —
  * a header line: last run + result, next scheduled run
  * Run now            (triggers the SYSTEM SunUp task)
  * Show last summary   (re-opens the summary dialog)
  * Open logs folder
  * Auto-reboot On/Off  (toggles rebootPolicy in config.json — checkmark reflects state)
  * Exit
It refreshes on a timer and pops a balloon when a new run completes.

Runs as the interactive user (RunLevel Highest so it can trigger the SYSTEM task / edit config),
launched at logon by the SunUp-Tray task. Single-instance via a named mutex. Must run STA.
  -Validate   build the icon + menu, then exit 0 (no message loop) — for CI/parse checks.
#>
param([switch]$Validate)
$ErrorActionPreference = 'Stop'
$Name   = 'SunUp'
$Root   = "C:\ProgramData\$Name"
$Engine = Join-Path $Root 'bin\SunUp.ps1'
$Dialog = Join-Path $Root 'bin\Show-UpdateDialog.ps1'
$Cfg    = Join-Path $Root 'config.json'
$Stamp  = Join-Path $Root 'lastrun.json'
$Payload= Join-Path $Root 'notify\latest-updates.json'
$Logs   = Join-Path $Root 'logs'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# Single instance — if a tray is already running for this user, bail quietly.
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\SunUpTray')
if (-not $Validate -and -not $script:mutex.WaitOne(0)) { exit 0 }

# ---- state readers ----------------------------------------------------------
function Test-PendingReboot {
  try {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations) { return $true }
  } catch {}
  $false
}
function Get-RebootPolicy {
  try { (Get-Content $Cfg -Raw | ConvertFrom-Json).rebootPolicy } catch { 'always' }
}
function Get-LastRun {
  try { Get-Content $Stamp -Raw | ConvertFrom-Json } catch { $null }
}
function Get-NextRun {
  try { (Get-ScheduledTask -TaskName $Name -ErrorAction Stop | Get-ScheduledTaskInfo).NextRunTime } catch { $null }
}

# ---- icon (drawn at runtime; amber when a reboot is pending) -----------------
function New-SunIcon { param([bool]$Alert)
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $col = if ($Alert) { [System.Drawing.Color]::FromArgb(255, 170, 0) } else { [System.Drawing.Color]::FromArgb(255, 201, 64) }
  $brush = New-Object System.Drawing.SolidBrush $col
  $pen   = New-Object System.Drawing.Pen $col, 2.6
  for ($a = 0; $a -lt 360; $a += 45) {
    $r = [math]::PI * $a / 180
    $g.DrawLine($pen, (16 + 9.5 * [math]::Cos($r)), (16 + 9.5 * [math]::Sin($r)), (16 + 14.5 * [math]::Cos($r)), (16 + 14.5 * [math]::Sin($r)))
  }
  $g.FillEllipse($brush, 8, 8, 16, 16)
  $g.Dispose()
  $hicon = $bmp.GetHicon()
  $ico = [System.Drawing.Icon]::FromHandle($hicon)
  $bmp.Dispose()
  $ico
}
$script:iconNormal = New-SunIcon $false
$script:iconAlert  = New-SunIcon $true

# ---- tray icon + menu -------------------------------------------------------
$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = $script:iconNormal
$script:notify.Visible = $true
$script:lastSeenRun = $null

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miHeader   = $menu.Items.Add('SunUp');               $miHeader.Enabled = $false
$miNext     = $menu.Items.Add('');                    $miNext.Enabled   = $false
[void]$menu.Items.Add('-')
$miRun      = $menu.Items.Add('Run now')
$miSummary  = $menu.Items.Add('Show last summary')
$miLogs     = $menu.Items.Add('Open logs folder')
[void]$menu.Items.Add('-')
$miReboot   = $menu.Items.Add('Auto-reboot when needed')
[void]$menu.Items.Add('-')
$miExit     = $menu.Items.Add('Exit')
$script:notify.ContextMenuStrip = $menu

# Refresh the dynamic bits (header, next run, auto-reboot checkmark, icon/tooltip).
function Update-Tray {
  $pending = Test-PendingReboot
  $lr = Get-LastRun
  $nr = Get-NextRun
  $lastTxt = if ($lr) { "Last run: $($lr.date)" } else { 'Last run: (never)' }
  $miHeader.Text = "SunUp — $lastTxt"
  $miNext.Text   = if ($nr) { "Next run: $($nr.ToString('ddd HH:mm'))" } else { 'Next run: (unscheduled)' }
  $miReboot.Checked = ((Get-RebootPolicy) -eq 'always')
  $script:notify.Icon = if ($pending) { $script:iconAlert } else { $script:iconNormal }
  $tip = "SunUp`n$lastTxt" + $(if ($pending) { "`nReboot pending" } else { '' })
  if ($tip.Length -gt 127) { $tip = $tip.Substring(0, 127) }   # NotifyIcon tooltip hard limit
  $script:notify.Text = $tip
}

# Balloon when a new run completes (detected by a changed payload runDate).
function Check-NewRun {
  try {
    if (-not (Test-Path $Payload)) { return }
    $p = Get-Content $Payload -Raw | ConvertFrom-Json
    if ($script:lastSeenRun -and $p.runDate -ne $script:lastSeenRun) {
      $n = @($p.items).Count
      $msg = if ($n -gt 0) { "$n update(s) installed" } else { 'Update check complete — nothing new' }
      $script:notify.BalloonTipTitle = 'SunUp'
      $script:notify.BalloonTipText  = $msg
      $script:notify.ShowBalloonTip(5000)
    }
    $script:lastSeenRun = $p.runDate
  } catch {}
}

# ---- actions ----------------------------------------------------------------
$miRun.Add_Click({
  try { Start-ScheduledTask -TaskName $Name -ErrorAction Stop
        $script:notify.BalloonTipTitle = 'SunUp'; $script:notify.BalloonTipText = 'Update run started…'; $script:notify.ShowBalloonTip(4000) }
  catch { [System.Windows.Forms.MessageBox]::Show("Couldn't start SunUp: $_", 'SunUp', 'OK', 'Warning') | Out-Null }
})
$miSummary.Add_Click({
  # Re-show the most recent summary: set pendingShow so the dialog displays, then trigger it.
  try {
    if (Test-Path $Payload) { $p = Get-Content $Payload -Raw | ConvertFrom-Json; $p.pendingShow = $true; $p | ConvertTo-Json -Depth 8 | Set-Content $Payload -Encoding UTF8 }
    Start-ScheduledTask -TaskName "$Name-Notify" -ErrorAction Stop
  } catch { [System.Windows.Forms.MessageBox]::Show("Couldn't open the summary: $_", 'SunUp', 'OK', 'Warning') | Out-Null }
})
$miLogs.Add_Click({ try { Start-Process explorer.exe $Logs } catch {} })
$miReboot.Add_Click({
  try {
    $c = Get-Content $Cfg -Raw | ConvertFrom-Json
    $c.rebootPolicy = if ($c.rebootPolicy -eq 'always') { 'never' } else { 'always' }
    $c | ConvertTo-Json -Depth 6 | Set-Content $Cfg -Encoding UTF8
    Update-Tray
    $script:notify.BalloonTipTitle = 'SunUp'
    $script:notify.BalloonTipText  = "Auto-reboot is now $(if ($c.rebootPolicy -eq 'always') { 'ON' } else { 'OFF' })"
    $script:notify.ShowBalloonTip(3000)
  } catch { [System.Windows.Forms.MessageBox]::Show("Couldn't update config: $_", 'SunUp', 'OK', 'Warning') | Out-Null }
})
$miExit.Add_Click({
  $script:notify.Visible = $false
  try { $script:timer.Stop() } catch {}
  [System.Windows.Forms.Application]::Exit()
})
# Double-click the icon → show last summary.
$script:notify.Add_MouseDoubleClick({ $miSummary.PerformClick() })
# Refresh dynamic items each time the menu opens.
$menu.Add_Opening({ Update-Tray })

# ---- timer (refresh + new-run balloon) --------------------------------------
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 45000   # 45s — well under the 5-min prompt-cache concerns elsewhere; cheap here
$script:timer.Add_Tick({ Update-Tray; Check-NewRun })

# Seed state, then run.
try { if (Test-Path $Payload) { $script:lastSeenRun = (Get-Content $Payload -Raw | ConvertFrom-Json).runDate } } catch {}
Update-Tray

if ($Validate) {
  Write-Host "validate OK: tray built (icon $($script:iconNormal.Width)px, $($menu.Items.Count) menu items)"
  $script:notify.Visible = $false; $script:notify.Dispose()
  exit 0
}

$script:timer.Start()
[System.Windows.Forms.Application]::Run()
# cleanup on exit
try { $script:notify.Dispose() } catch {}
try { $script:mutex.ReleaseMutex() } catch {}
