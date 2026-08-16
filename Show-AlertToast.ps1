<#
Show-AlertToast.ps1 -- drains SunUp's alert queue and raises persistent desktop toasts.

SunUp historically appended alert lines to SysSentry's ALERTS.md and let SysSentry's notifier
toast them. SysSentry was retired 2026-08-15 (monitoring descoped on this box), and depending on
another tool's plumbing for our own voice was backwards anyway -- an update manager should be able
to say "a restart is waiting on you" without a second product installed. This script is that
voice, and nothing else: no checks, no baselines, no categories. One thing.

Runs as the INTERACTIVE USER (a SYSTEM task has no desktop) under Windows PowerShell 5.1
specifically: the toast APIs are WinRT-only and .NET Core has no projection for them -- the same
carve-out Show-RestartToast.ps1 makes, for the same reason. Fired on demand by any queue writer
via Start-ScheduledTask, and at logon so alerts raised while nobody was signed in still surface.

DESIGN, inherited deliberately from the retired notifier because it was measured to work:
 - The QUEUE FILE is the source of truth, not the task start. Start-ScheduledTask reports
   success without running anything when an IgnoreNew instance is already live (see SunUp.ps1
   Start-TaskVerified for the autopsy), so a silently-dropped start must be harmless. Writers
   re-fire this task on every Raise-Alert; the AtLogon trigger catches a signed-out gap.
 - notify\alerts-history.md is appended BEFORE toasting and is the durable record. The queue is
   truncated before toasting too: a toast lost to a crash costs nothing, re-toasting the same
   batch on every retry is the failure mode that would actually annoy.
 - Past 3 queued alerts the stack collapses into one summary toast.
This file is kept pure ASCII: 5.1 reads a BOM-less file as ANSI, and one em dash would be
mojibake on screen. Enforced by the test suite alongside Show-RestartToast.ps1.
#>
param([switch]$SelfTest)

$ErrorActionPreference = 'Continue'
$Name       = 'SunUp'
$Root       = "C:\ProgramData\$Name"
$NotifyDir  = Join-Path $Root 'notify'
$QueueFile  = Join-Path $NotifyDir 'alerts.jsonl'
$HistFile   = Join-Path $NotifyDir 'alerts-history.md'
$LogFile    = Join-Path $NotifyDir 'alert-toast.log'
$AumId      = "$Name.Alerts"
$MaxIndividual = 3

# -Encoding UTF8 everywhere: the writers run under pwsh 7 (UTF-8, no BOM) but this script is
# Windows PowerShell 5.1, whose Get-Content/Add-Content default to ANSI.
function Write-Log { param($Level, $Msg)
  try { "{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}" -f (Get-Date), $Level, $Msg | Add-Content -Path $LogFile -Encoding UTF8 } catch {}
}

# A toast is delivered on behalf of a registered AppUserModelID. Registering our own under HKCU
# (cheap, idempotent) makes the notification say "SunUp" and gives it a row in
# Settings > Notifications, instead of impersonating Windows PowerShell. Uninstall.ps1 removes it.
function Register-Aum {
  $k = "HKCU:\Software\Classes\AppUserModelId\$AumId"
  try {
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    New-ItemProperty -Path $k -Name 'DisplayName'    -Value $Name -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $k -Name 'ShowInSettings' -Value 1     -PropertyType DWord  -Force | Out-Null
  } catch { Write-Log 'WARN' "AUMID registration failed: $_" }
}

function Show-Toast { param([string]$Title, [string]$Body)
  # scenario="reminder" keeps the popup up until the user acts (it needs an <actions> block to be
  # well-formed); it lands in Action Center either way, which is the half that matters when the
  # user is away -- the situation most SunUp alerts describe.
  $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
  $xml = @"
<toast scenario="reminder">
  <visual>
    <binding template="ToastGeneric">
      <text>$(& $esc $Title)</text>
      <text>$(& $esc $Body)</text>
    </binding>
  </visual>
  <actions>
    <action content="Dismiss" arguments="dismiss" activationType="system"/>
  </actions>
</toast>
"@
  try {
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AumId).Show($toast)
    return $true
  } catch { Write-Log 'ERROR' "Toast failed: $_"; return $false }
}

# ---- main --------------------------------------------------------------------

try {
  [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI, ContentType = WindowsRuntime]
  [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
} catch {
  Write-Log 'ERROR' "WinRT unavailable (are we under pwsh instead of powershell.exe 5.1?): $_"
  exit 1
}
Register-Aum

if ($SelfTest) {
  $ok = Show-Toast "$Name self-test" 'Alert toasts are working. This one stays until dismissed.'
  Write-Log 'INFO' "Self-test toast: $ok"
  Write-Host "Self-test toast dispatched: $ok"
  exit ($(if ($ok) { 0 } else { 1 }))
}

if (-not (Test-Path $QueueFile)) { exit 0 }

# Serialize the drain so two instances (on-demand + AtLogon racing) cannot both deliver the same
# batch. Parallel instances are allowed by design; only this section must not interleave.
$mx = $null; $held = $false
try { $mx = New-Object System.Threading.Mutex($false, "Global\$Name-AlertDrain") } catch {}
if ($mx) {
  try { $held = $mx.WaitOne([timespan]::FromSeconds(20)) }
  catch [System.Threading.AbandonedMutexException] { $held = $true }
  catch { $held = $false }
}
if (-not $held) { Write-Log 'INFO' 'Another drain holds the lock; leaving the queue to it.'; exit 0 }

try {
  $raw = @(Get-Content $QueueFile -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
  if (-not $raw.Count) { exit 0 }
  try { Clear-Content -Path $QueueFile -ErrorAction Stop } catch { Write-Log 'WARN' "Could not truncate queue: $_" }

  $alerts = foreach ($line in $raw) {
    try { $line | ConvertFrom-Json } catch { Write-Log 'WARN' "Unparseable queue line skipped: $line"; $null }
  }
  $alerts = @($alerts | Where-Object { $_ })
  if (-not $alerts.Count) { exit 0 }

  # History first: the durable record must exist before anything ephemeral is attempted.
  foreach ($a in $alerts) {
    try { ('- **{0:yyyy-MM-dd HH:mm}** [{1}] {2}' -f (Get-Date), "$($a.src)", "$($a.msg)") | Add-Content -Path $HistFile -Encoding UTF8 } catch {}
  }

  if ($alerts.Count -le $MaxIndividual) {
    foreach ($a in $alerts) { [void](Show-Toast $Name $a.msg) }
  } else {
    [void](Show-Toast "${Name}: $($alerts.Count) alerts" "See $HistFile")
  }
  Write-Log 'INFO' "Delivered $($alerts.Count) alert(s)."
}
finally {
  if ($mx -and $held) { try { $mx.ReleaseMutex() } catch {} }
  if ($mx) { try { $mx.Dispose() } catch {} }
}
