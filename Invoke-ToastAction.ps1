<#
Invoke-ToastAction.ps1 -- the sunup: protocol handler behind the restart toast's buttons.

Windows launches this with the action URI as its only argument when a button on the "Restarting
Soon" toast is pressed:  sunup:restart | sunup:pause | sunup:resume | sunup:dismiss | sunup:show

WHY A PROTOCOL HANDLER AT ALL. A toast button can activate three ways. "foreground" and "background"
both deliver the click straight back to the app -- through a COM activator registered under a CLSID,
which an unpackaged PowerShell script cannot sanely provide. "system" only performs a built-in
dismiss. "protocol" launches a URI, which is the one path that works for a script, at the cost of
this extra hop: Windows starts a fresh short-lived process, which writes a command file that the
running toast host polls. There is no shared memory to use instead -- the two processes are not
related, and this one has to work whether or not the host is still alive.

Kept deliberately tiny and dependency-free (no RebootState.ps1, no config): it runs on a UI button
press, so its whole job is to be fast and to never fail in a way that loses the click. It makes no
decisions. It cannot restart anything. It writes one small file.

ASCII only and 5.1-parseable, like everything else the restart path touches.
#>
param([Parameter(Position = 0)][string]$Uri = '')

$ErrorActionPreference = 'Continue'
$Name        = 'SunUp'
$NotifyDir   = "C:\ProgramData\$Name\notify"
$CommandPath = Join-Path $NotifyDir 'toast-command.json'
$LogFile     = Join-Path $NotifyDir 'reboot.log'

function Write-ActionLog { param($Msg)
  try { "{0} [INFO ] toast-action: {1}" -f (Get-Date).ToString('o'), $Msg | Add-Content -Path $LogFile -Encoding UTF8 } catch {}
}

# "sunup:pause", "sunup://pause", "sunup:pause/" -- the shell is not consistent about trailing
# slashes or the authority form, so normalize rather than string-compare the whole URI.
$action = "$Uri" -replace '(?i)^sunup:(//)?', ''
$action = ($action -replace '[/\s]+$', '').Trim().ToLower()

# An allow-list, not a pass-through. This is reachable by anything that can launch a URI, so it is
# treated as untrusted input: an unrecognised action is dropped, never written on and never acted on.
$known = @('restart', 'pause', 'resume', 'dismiss', 'show')
if ($known -notcontains $action) {
  Write-ActionLog "ignored an unrecognised action from '$Uri'"
  exit 0
}

try {
  if (-not (Test-Path $NotifyDir)) { New-Item -ItemType Directory -Force -Path $NotifyDir | Out-Null }
  $payload = [ordered]@{
    action  = $action
    atLocal = (Get-Date).ToString('o')   # local-with-offset, per the writer contract
    pid     = $PID
  }
  # Publish by rename: the host polls this path once a second and must never read a half-written
  # file. A dropped click is a nuisance; a torn read is an exception inside the countdown loop.
  $tmp = "$CommandPath.tmp"
  ($payload | ConvertTo-Json -Depth 4) | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
  Move-Item -Path $tmp -Destination $CommandPath -Force -ErrorAction Stop
  Write-ActionLog "queued '$action'"
} catch {
  Write-ActionLog "could not queue '$action': $_"
  exit 1
}
exit 0
