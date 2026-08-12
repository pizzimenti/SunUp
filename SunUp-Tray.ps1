<#
SunUp-Tray.ps1 — a persistent system-tray presence for SunUp.

Windows has no `systemctl`/service-manager face for a scheduled task, so this gives SunUp one:
a tray icon (a full sun; a sun setting behind the horizon when a restart is needed) with a
right-click menu —
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
# Reboot detection is shared verbatim with the engine (RebootState.ps1, deployed alongside this
# script in bin\). The tray used to carry its own copy, which reported a pending reboot for ANY
# queued file operation — an application deleting its own temp file included — so on this box the
# icon sat in its alert state permanently and stopped meaning anything. See RebootState.ps1.
$RebootStateScript = Join-Path $PSScriptRoot 'RebootState.ps1'
if (Test-Path $RebootStateScript) { . $RebootStateScript }
else {
  # Degraded: show the state only for reboots SunUp itself knows it caused. Better a missed OS
  # signal than a permanently-lit icon, which is the failure mode being retired here.
  function Get-RebootState { param([bool]$RunRequired = $false, [bool]$HandoffRequired = $false)
    [pscustomobject]@{ Required = ($RunRequired -or $HandoffRequired); Sources = @(); Labels = @('Updates installed')
                       Reasons = @(); Advisory = @(); CheckedUtc = (Get-Date).ToUniversalTime() } }
  # This used to be `{ $false }` -- a constant, which is not a degraded answer but a wrong one: it
  # says "the box has never booted since anything", so a reboot the run asked for could never be
  # retired and the sunset icon stayed lit for good. Degrading the DETECTION is acceptable here;
  # degrading the RETIREMENT re-creates the permanently-lit icon v0.16.0 existed to remove.
  function ConvertTo-UtcTime { param($Value, [switch]$AllowFuture)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [long] -or $Value -is [int]) { return (New-Object datetime 1970,1,1,0,0,0,([System.DateTimeKind]::Utc)).AddSeconds([double]$Value) }
    try {
      $p = [datetime]::Parse("$Value", $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
      if ($p.Kind -eq [System.DateTimeKind]::Unspecified) { $p = [datetime]::SpecifyKind($p, [System.DateTimeKind]::Local) }
      return $p.ToUniversalTime()
    } catch { return $null }
  }
  function Test-BootedSince { param($Utc)
    $t = ConvertTo-UtcTime $Utc
    if ($null -eq $t) { return $false }
    try { ((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() -gt $t) } catch { $false }
  }
}

function Get-RebootPolicy {
  try { (Get-Content $Cfg -Raw | ConvertFrom-Json).rebootPolicy } catch { 'ifRequired' }
}
function Get-LastRun {
  try { Get-Content $Stamp -Raw | ConvertFrom-Json } catch { $null }
}
function Get-NextRun {
  try { (Get-ScheduledTask -TaskName $Name -ErrorAction Stop | Get-ScheduledTaskInfo).NextRunTime } catch { $null }
}
function Get-Payload {
  try { Get-Content $Payload -Raw | ConvertFrom-Json } catch { $null }
}

# The reboots SunUp itself causes never reach the registry: an MSI 3010 or a winget restart exit
# code is recorded in the run payload and nowhere else. So the tray reading only the registry meant
# the one case where a restart was certainly needed — SunUp having just installed something that
# asked for one — was the case the icon could not show. Both halves are folded in here.
# A restart the run asked for is retired by an actual boot, sharing one implementation with the
# dialog rather than mirroring it; Test-BootedSince answers $false when it cannot tell, so the state
# stays visible on doubt. (Mirroring is exactly what failed: the dialog's copy of this test was the
# 2026-08-12 restart loop, and this one was right the whole time because it went through the
# shared reader. Two implementations of one question is the bug, not the drift between them.)
function Get-TrayRebootState {
  $runOutstanding = $false
  $p = Get-Payload
  # runEnd is v0.17.0's local-with-offset field; runEndUtc is the v0.16.0 spelling, still honoured
  # so a tray that outlives an engine upgrade reads the older payload correctly rather than blindly.
  if ($p -and $p.rebootRequired) {
    $runEndValue = if ($p.PSObject.Properties.Name -contains 'runEnd') { $p.runEnd } else { $p.runEndUtc }
    $runOutstanding = -not (Test-BootedSince $runEndValue)
  }
  $lr = Get-LastRun
  if ($lr -and $lr.handoffRebootPending) { $runOutstanding = $true }
  Get-RebootState -HandoffRequired $runOutstanding
}

# ---- icons (drawn at runtime; no asset files to deploy) ---------------------
# Two states that differ in SHAPE, not merely in hue: a full sun when there is nothing outstanding,
# and a sun setting behind the horizon when a restart is needed. The previous pair were both full
# suns separated by one shade of amber (255,201,64 vs 255,170,0) — a distinction that survives
# neither the 16px the tray actually renders at nor a light/dark taskbar behind it.
function ConvertTo-TrayIcon {
  param([System.Drawing.Bitmap]$Bmp)
  $h = $Bmp.GetHicon()
  $ico = [System.Drawing.Icon]::FromHandle($h)
  $Bmp.Dispose()
  $ico
}

function New-SunIcon {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $col   = [System.Drawing.Color]::FromArgb(255, 201, 64)
  $brush = New-Object System.Drawing.SolidBrush $col
  $pen   = New-Object System.Drawing.Pen $col, 2.6
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
  for ($a = 0; $a -lt 360; $a += 45) {
    $r = [math]::PI * $a / 180
    $g.DrawLine($pen, (16 + 9.5 * [math]::Cos($r)), (16 + 9.5 * [math]::Sin($r)), (16 + 14.5 * [math]::Cos($r)), (16 + 14.5 * [math]::Sin($r)))
  }
  $g.FillEllipse($brush, 8, 8, 16, 16)
  $pen.Dispose(); $brush.Dispose(); $g.Dispose()
  ConvertTo-TrayIcon $bmp
}

# Sunset: the disc sits ON the horizon with everything below it clipped away, rays fanning upward
# only, amber falling to dusk orange down the face. The clip is what sells the shape — an unclipped
# disc with a rule drawn across it just reads as a sun with a line through it.
function New-SunsetIcon {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $horizon = 22.0; $cx = 16.0; $cy = 22.0; $rad = 8.0
  $warm = [System.Drawing.Color]::FromArgb(255, 176, 59)
  $dusk = [System.Drawing.Color]::FromArgb(232, 93, 42)

  $g.SetClip((New-Object System.Drawing.RectangleF 0, 0, 32, $horizon))
  $disc = New-Object System.Drawing.RectangleF ($cx - $rad), ($cy - $rad), (2 * $rad), (2 * $rad)
  $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush $disc, $warm, $dusk, 90.0
  $g.FillEllipse($grad, $disc)
  $penRay = New-Object System.Drawing.Pen $warm, 2.4
  $penRay.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $penRay.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
  # Screen Y grows DOWNWARD, so 270 degrees points straight up: 210..330 fans across the upper
  # hemisphere only. Rays below the horizon would be clipped anyway, but drawing none is cheaper.
  foreach ($a in 210, 250, 290, 330) {
    $r = [math]::PI * $a / 180
    $g.DrawLine($penRay, ($cx + 10.5 * [math]::Cos($r)), ($cy + 10.5 * [math]::Sin($r)), ($cx + 14.5 * [math]::Cos($r)), ($cy + 14.5 * [math]::Sin($r)))
  }
  $g.ResetClip()
  $penH = New-Object System.Drawing.Pen $dusk, 2.6
  $penH.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $penH.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawLine($penH, 2.5, $horizon, 29.5, $horizon)
  $penH.Dispose(); $penRay.Dispose(); $grad.Dispose(); $g.Dispose()
  ConvertTo-TrayIcon $bmp
}
$script:iconNormal = New-SunIcon
$script:iconSunset = New-SunsetIcon

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
  $rb = Get-TrayRebootState
  $lr = Get-LastRun
  $nr = Get-NextRun
  $lastTxt = if ($lr) { "Last run: $($lr.date)" } else { 'Last run: (never)' }
  $miHeader.Text = "SunUp — $lastTxt"
  $miNext.Text   = if ($nr) { "Next run: $($nr.ToString('ddd HH:mm'))" } else { 'Next run: (unscheduled)' }
  $miReboot.Checked = ((Get-RebootPolicy) -ne 'never')   # checked = auto-reboot enabled (ifRequired or always)
  $script:notify.Icon = if ($rb.Required) { $script:iconSunset } else { $script:iconNormal }
  # Say WHAT is asking, not just that something is. "Restart needed" alone gave no way to tell a
  # real servicing hold from the false positive this release exists to remove.
  $tip = "SunUp`n$lastTxt"
  if ($rb.Required) {
    $why = if ($rb.Labels.Count) { $rb.Labels -join ', ' } else { 'reason unavailable' }
    $tip += "`nRestart needed — $why"
  }
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
  # Under the same Global\SunUp-Notify mutex and published by rename as every other writer of this
  # file -- three processes read-modify-write it and a torn write kills the next dialog outright.
  #
  # Worth remembering what this menu item used to be able to do: with the payload still saying
  # rebootRequired and the dialog unable to tell it had already restarted, clicking "Show last
  # summary" armed a fresh five-minute countdown and rebooted the machine. It is now inert -- the
  # restart record decides, and re-showing a summary cannot re-arm anything.
  try {
    if (Test-Path $Payload) {
      $mx = $null; $held = $false
      try { $mx = New-Object System.Threading.Mutex($false, 'Global\SunUp-Notify') } catch {}
      if ($mx) {
        try { $held = $mx.WaitOne([timespan]::FromSeconds(5)) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }
        catch { $held = $false }
      }
      if ($held) {
        try {
          $p = Get-Content $Payload -Raw -ErrorAction Stop | ConvertFrom-Json
          $p.pendingShow = $true
          $tmp = "$Payload.tmp"
          ($p | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
          $null = Get-Content $tmp -Raw -ErrorAction Stop | ConvertFrom-Json
          Move-Item -Path $tmp -Destination $Payload -Force -ErrorAction Stop
        } finally {
          try { $mx.ReleaseMutex() } catch {}
          try { $mx.Dispose() } catch {}
        }
      }
    }
    Start-ScheduledTask -TaskName "$Name-Notify" -ErrorAction Stop
  } catch { [System.Windows.Forms.MessageBox]::Show("Couldn't open the summary: $_", 'SunUp', 'OK', 'Warning') | Out-Null }
})
$miLogs.Add_Click({ try { Start-Process explorer.exe $Logs } catch {} })
$miReboot.Add_Click({
  try {
    $c = Get-Content $Cfg -Raw | ConvertFrom-Json
    # Toggle enabled/off. "On" turns on the smart default (ifRequired = only when a run needs it),
    # not the blunt 'always'. A power user who wants 'always' edits config.json directly; toggling
    # off then on from there lands on ifRequired.
    $c.rebootPolicy = if ($c.rebootPolicy -eq 'never') { 'ifRequired' } else { 'never' }
    $c | ConvertTo-Json -Depth 6 | Set-Content $Cfg -Encoding UTF8
    Update-Tray
    $script:notify.BalloonTipTitle = 'SunUp'
    $script:notify.BalloonTipText  = if ($c.rebootPolicy -eq 'never') { 'Auto-reboot is now OFF' } else { 'Auto-reboot is now ON (only when required)' }
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
  $rbv = Get-TrayRebootState
  Write-Host "validate OK: tray built (icons $($script:iconNormal.Width)px sun + $($script:iconSunset.Width)px sunset, $($menu.Items.Count) menu items; restart needed = $($rbv.Required)$(if ($rbv.Labels.Count) { " [$($rbv.Labels -join ', ')]" }))"
  $script:notify.Visible = $false; $script:notify.Dispose()
  exit 0
}

$script:timer.Start()
[System.Windows.Forms.Application]::Run()
# cleanup on exit
try { $script:notify.Dispose() } catch {}
try { $script:mutex.ReleaseMutex() } catch {}
