<#
Show-RestartToast.ps1 -- the "Restarting Soon" notification, and the countdown it owns.

WINDOWS POWERSHELL 5.1 ONLY, and not by preference. The toast APIs are WinRT, and .NET Core has no
WinRT projection, so [Windows.UI.Notifications.ToastNotificationManager] does not resolve under
pwsh 7 at all. This is the same 5.1 carve-out SelfHost.ps1 makes for a different reason, and it
carries the same constraint: 5.1 reads a BOM-less file as ANSI, so this file and everything it
dot-sources must be PURE ASCII or the parse dies silently inside a scheduled task. Both are asserted
by tests\Test-SunUp.ps1 against the real 5.1 parser.

Runs as the interactive user (RunLevel Highest, so it can actually restart the box), fired by the
engine after a run that intends to restart. Before v0.17.0 this job belonged to the WPF summary
dialog; that dialog still carries a countdown as the fallback for when a toast cannot be shown, but
it is no longer the normal path.

WHAT IT SHOWS
  header      "Restarting Soon"
  body        which update is asking for the restart
  attribution why it is needed and what stays broken until it happens, in plain words --
              see Get-RebootConsequence in RebootState.ps1, and notify\why-cache.json when
              notify.explain is on
  progress    a live countdown
  buttons     [Restart now] [Pause] -- Pause toggles to Unpause and holds the countdown
              indefinitely. There is no auto-resume: if you paused it, you meant it.

THREE MECHANICS WORTH KNOWING, because none of them are obvious:

 1. scenario="reminder" is load-bearing. A default toast auto-dismisses into Action Center after
    about five seconds, which is useless for a countdown you are being asked to act on. "reminder"
    pins it on screen until the user acts. It REQUIRES an <actions> block to be well-formed.

 2. The countdown updates WITHOUT re-popping the toast, because <progress> fields are data-bound
    ({tick}, {ticklabel}) and ToastNotifier.Update() rewrites just those. Re-showing once a second
    would be a strobe light.

 3. The Pause/Unpause toggle DOES re-pop, unavoidably: button labels are not data-bindable, so
    swapping the label means Show()ing a replacement with the same Tag and Group. That is a
    deliberate trade -- it happens only on a button press, where a visible acknowledgement is what
    you want anyway.

 4. Buttons activate by PROTOCOL (activationType="protocol", sunup:...), not by COM. Foreground and
    background activation both require a registered CLSID activator, which an unpackaged script
    cannot sanely provide. The sunup: handler (Invoke-ToastAction.ps1) writes a one-line command
    file that this process polls. activationType="system" only does dismiss.

EXITS
  0  handled (restart issued, paused-and-exited, dismissed, or nothing to do)
  2  cannot show a toast here -- the CALLER SHOULD FALL BACK to the WPF dialog's countdown
  1  a real error

  -SelfTest   show a demo toast with both buttons wired, never restart
  -Demo       run the real countdown against the real payload, but never restart
  -Validate   build everything, print the decision and the XML, exit 0 (no toast, no message loop)
#>
param(
  [string]$DataPath         = 'C:\ProgramData\SunUp\notify\latest-updates.json',
  [string]$RestartStatePath = 'C:\ProgramData\SunUp\notify\restart-state.json',
  [string]$CommandPath      = 'C:\ProgramData\SunUp\notify\toast-command.json',
  [switch]$SelfTest,
  [switch]$Demo,
  [switch]$Validate
)
$ErrorActionPreference = 'Continue'
$Name    = 'SunUp'
$Root    = "C:\ProgramData\$Name"
$LogFile = Join-Path $Root 'notify\reboot.log'
$AumId   = 'SunUp.Restart'
$ToastTag   = 'sunup-restart'
$ToastGroup = 'sunup'

# -Encoding UTF8 on every read: the engine writes these files under pwsh 7 (UTF-8, no BOM) and this
# script runs under 5.1, whose Get-Content defaults to ANSI. Without it every em dash in an update
# title reaches the toast as mojibake.
function Write-ToastLog { param($Level, $Msg)
  try { "{0} [{1,-5}] toast: {2}" -f (Get-Date).ToString('o'), $Level, $Msg | Add-Content -Path $LogFile -Encoding UTF8 } catch {}
}

# The fallback lives HERE, not in the engine, because only this process knows whether a toast
# actually appeared. The engine fires us with Start-ScheduledTask, which returns no exit code and
# does not wait -- so "start the toast, check if it worked, otherwise start the dialog" is not
# something the caller can do. Every exit-2 path below hands the countdown back to the WPF dialog on
# its way out. A restart the user was never warned about is the one outcome worth any amount of
# plumbing to avoid.
function Invoke-DialogFallback {
  param([string]$Why)
  Write-ToastLog WARN "falling back to the summary dialog: $Why"
  try { Start-ScheduledTask -TaskName "$Name-Notify" -ErrorAction Stop }
  catch { Write-ToastLog ERROR "could not start $Name-Notify either: $_ -- the restart stays pending for the next run." }
}

$RebootStateScript = Join-Path $PSScriptRoot 'RebootState.ps1'
if (-not (Test-Path $RebootStateScript)) {
  Invoke-DialogFallback 'RebootState.ps1 is not beside me, so I cannot decide anything'
  exit 2
}
. $RebootStateScript

# ---- WinRT probe ------------------------------------------------------------
# Deliberately the first thing after the shared file loads. If this fails there is no toast to be
# had on this machine and the caller needs to know NOW, while it can still put the dialog up,
# rather than after a countdown has silently not been shown to anybody.
try {
  [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI, ContentType = WindowsRuntime]
  [void][Windows.UI.Notifications.ToastNotification,        Windows.UI, ContentType = WindowsRuntime]
  [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
} catch {
  Invoke-DialogFallback "WinRT is unavailable (running under pwsh instead of powershell.exe 5.1?): $_"
  exit 2
}

# ---- identity + notification preflight --------------------------------------
# A toast is only ever delivered on behalf of a registered AppUserModelID. Registering our own under
# HKCU is cheap, idempotent, and needs no Start Menu shortcut despite the usual advice -- SysSentry
# has done exactly this on this machine for months. It also gives SunUp its own row in
# Settings > Notifications instead of impersonating Windows PowerShell.
function Register-Aum {
  $k = "HKCU:\Software\Classes\AppUserModelId\$AumId"
  try {
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    New-ItemProperty -Path $k -Name 'DisplayName'    -Value 'SunUp'  -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $k -Name 'ShowInSettings' -Value 1        -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $k -Name 'IconUri' -Value "$env:SystemRoot\System32\shell32.dll,238" -PropertyType String -Force | Out-Null
  } catch { Write-ToastLog WARN "AUMID registration failed: $_" }
}

# Do Not Disturb is never wanted on this machine, so this asserts that rather than coping with it.
#
# Only the DOCUMENTED levers are written. The Windows 11 DND toggle itself lives in an undocumented
# CloudStore binary blob, and writing that blind is how you corrupt someone's notification settings;
# it is DETECTED and reported instead. AllowUrgentNotifications is the supported way for an app to
# break through when DND is on, and pairs with scenario="urgent" if "reminder" ever proves
# insufficient. Returns $false when it cannot vouch for the settings, so the caller can log it.
function Set-NotificationPreflight {
  $ok = $true
  try {
    $g = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
    if (-not (Test-Path $g)) { New-Item -Path $g -Force | Out-Null }
    New-ItemProperty -Path $g -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -Value 1 -PropertyType DWord -Force | Out-Null
  } catch { $ok = $false; Write-ToastLog WARN "could not enable toasts globally: $_" }
  try {
    $a = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$AumId"
    if (-not (Test-Path $a)) { New-Item -Path $a -Force | Out-Null }
    foreach ($v in @('Enabled', 'AllowUrgentNotifications', 'ShowInActionCenter', 'AllowContentAboveLock')) {
      New-ItemProperty -Path $a -Name $v -Value 1 -PropertyType DWord -Force | Out-Null
    }
  } catch { $ok = $false; Write-ToastLog WARN "could not set per-app notification policy: $_" }
  try {
    $p = 'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    New-ItemProperty -Path $p -Name 'NoQuietHours' -Value 1 -PropertyType DWord -Force | Out-Null
  } catch { $ok = $false; Write-ToastLog WARN "could not disable quiet hours by policy: $_" }
  # Detect, never write, the undocumented DND state.
  try {
    $q = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quiethourssettings\windows.data.donotdisturb.quiethourssettings'
    if (Test-Path $q) {
      $blob = (Get-ItemProperty -Path $q -ErrorAction Stop).Data
      if ($blob -and $blob.Length -gt 20) {
        Write-ToastLog WARN "Do Not Disturb may be configured (quiethourssettings is $($blob.Length) bytes); a restart toast can be suppressed. Turn it off in Settings > Notifications."
        $ok = $false
      }
    }
  } catch {}
  $ok
}

# ---- what to say ------------------------------------------------------------
function ConvertTo-XmlText { param([string]$S) [System.Security.SecurityElement]::Escape("$S") }

# Name the thing that is asking. "A restart is required" with no subject is what the old dialog said
# and it gave the user no way to judge whether it mattered.
function Get-RestartSubject {
  param($Data)
  if (-not $Data) { return 'A recent update' }
  $named = @()
  foreach ($i in @($Data.items)) {
    if ($i -and $i.meta -and $i.meta.rebootRequired) { $named += "$($i.name)" }
  }
  if ($named.Count -eq 0) { $named = @(@($Data.items) | ForEach-Object { "$($_.name)" } | Where-Object { $_ }) }
  if ($named.Count -eq 0) { $named = @(@($Data.rebootFrom) | Where-Object { $_ }) }
  if ($named.Count -eq 0) { return 'A recent update' }
  # Titles are long ("2026-08 Cumulative Update for Windows 11 ... (KB5121003)"), and this is one
  # toast line. Lead with the first and count the rest rather than truncating all of them to soup.
  $first = $named[0]
  if ($first.Length -gt 90) { $first = $first.Substring(0, 87) + '...' }
  if ($named.Count -eq 1) { return $first }
  if ($named.Count -eq 2) { return "$first and 1 other update" }
  "$first and $($named.Count - 1) other updates"
}

# The plain-language half. Prefers an enriched explanation if one has been cached for these updates
# (see notify\why-cache.json and the notify.explain config key); falls back to the deterministic
# consequence table, which always works, offline, with no API key and no network.
function Get-RestartWhy {
  param($Data)
  $lines = @()
  if ($Data -and $Data.whyPlain) { $lines = @($Data.whyPlain | Where-Object { $_ }) }
  if ($lines.Count -eq 0 -and $Data -and $Data.rebootSources) {
    $lines = @(Get-RebootConsequence -Sources @($Data.rebootSources))
  }
  if ($lines.Count -eq 0) { $lines = @('Windows needs to restart to finish applying an update.') }
  $t = ($lines -join ' ')
  if ($t.Length -gt 260) { $t = $t.Substring(0, 257) + '...' }
  $t
}

# ---- optional enrichment (notify.explain = auto) ----------------------------
# The deterministic table above always works and is always true, but it is generic: it explains what
# a CLASS of update means, not what THIS one does. When notify.explain is 'auto', ask Claude for the
# specific version, in plain words.
#
# Three rules make this safe to put in front of a restart warning:
#   1. CACHED FOREVER, per set of updates. A given KB is researched once on this machine, ever.
#   2. HARD TIMEOUT. Bounded by $ExplainTimeoutSec; the countdown is 300s and can spare ten, but it
#      may never wait on a network call that has hung.
#   3. FAILS TO THE TABLE. Every failure path -- no claude, no network, a timeout, an empty or
#      implausible answer -- returns the deterministic text. A restart warning that did not appear
#      because an LLM call failed would be a far worse bug than a generic sentence.
#
# 30s, MEASURED not guessed: a warm `claude -p` round trip for this prompt took 12.4s on this box
# (2026-08-12), so a 12s budget timed out on the very first real call. The delay is paid at most once
# per set of updates, and it delays only the APPEARANCE of the toast -- the countdown starts when the
# toast goes up, so nothing is taken away from the grace period the user gets.
$ExplainTimeoutSec = 30
$WhyCachePath      = Join-Path $Root 'notify\why-cache.json'

# Keyed on the identity of the updates, not on their descriptions: the same KB always resolves to
# the same cache entry, and a different set of updates is a genuinely different question.
function Get-WhyCacheKey {
  param($Data)
  $ids = @()
  foreach ($i in @($Data.items)) {
    if (-not $i) { continue }
    $id = $null
    if ($i.meta -and $i.meta.kb) { $id = "$($i.meta.kb)" } else { $id = "$($i.name)|$($i.new)" }
    if ($id) { $ids += $id }
  }
  if ($ids.Count -eq 0) { $ids = @("$($Data.runStamp)") }
  ($ids | Sort-Object -Unique) -join ';'
}

function Get-CachedWhy {
  param([string]$Key)
  if (-not (Test-Path $WhyCachePath)) { return $null }
  try {
    $c = Get-Content $WhyCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($c.PSObject.Properties.Name -contains $Key) { return "$($c.$Key.text)" }
  } catch {}
  $null
}

function Save-CachedWhy {
  param([string]$Key, [string]$Text)
  try {
    $c = $null
    if (Test-Path $WhyCachePath) { try { $c = Get-Content $WhyCachePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    if (-not $c) { $c = New-Object psobject }
    $entry = New-Object psobject
    Add-Member -InputObject $entry -MemberType NoteProperty -Name 'text'    -Value $Text
    Add-Member -InputObject $entry -MemberType NoteProperty -Name 'atLocal' -Value (Get-SunUpTimestamp)
    Add-Member -InputObject $c -MemberType NoteProperty -Name $Key -Value $entry -Force
    $tmp = "$WhyCachePath.tmp"
    ($c | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
    Move-Item -Path $tmp -Destination $WhyCachePath -Force -ErrorAction Stop
  } catch { Write-ToastLog WARN "could not cache the explanation: $_" }
}

function Build-ExplainPrompt {
  param($Data)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('A Windows machine has just installed the updates below and needs to restart.')
  [void]$sb.AppendLine('Write AT MOST TWO SENTENCES, in plain everyday English, telling the person who uses this')
  [void]$sb.AppendLine('machine what is actually still at risk or still broken until they restart.')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Rules:')
  [void]$sb.AppendLine('- No CVE numbers, no KB numbers, no version numbers, no security jargon.')
  [void]$sb.AppendLine('- Do not say "please restart" or give instructions; only describe the consequence.')
  [void]$sb.AppendLine('- Be concrete about what the machine still cannot do or is still exposed to.')
  [void]$sb.AppendLine('- If the updates are routine with no user-visible consequence, say so plainly.')
  [void]$sb.AppendLine('- Output the sentences only. No preamble, no bullet points, no quotes.')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Updates:')
  foreach ($i in @($Data.items)) {
    if (-not $i) { continue }
    $line = "- $($i.name)"
    if ($i.meta) {
      if ($i.meta.severity)    { $line += " [severity: $($i.meta.severity)]" }
      if ($i.meta.description) { $line += "`n    $($i.meta.description)" }
    }
    [void]$sb.AppendLine($line)
  }
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Why Windows says a restart is needed:')
  foreach ($r in @($Data.rebootReasons)) { if ($r) { [void]$sb.AppendLine("- $r") } }
  $sb.ToString()
}

# Claude Code's headless mode, run as the interactive user -- which is the point: that is where the
# user's own Claude authentication lives. The SYSTEM engine has none and could not do this.
# Start-Process + WaitForExit(ms) rather than a pipeline, because a pipeline cannot be timed out.
function Invoke-ClaudeExplain {
  param([string]$Prompt, [int]$TimeoutSec)
  $claude = $null
  try { $claude = (Get-Command claude -ErrorAction Stop).Source } catch { return $null }
  if (-not $claude) { return $null }
  $inFile  = Join-Path $env:TEMP "sunup-why-in-$PID.txt"
  $outFile = Join-Path $env:TEMP "sunup-why-out-$PID.txt"
  $errFile = Join-Path $env:TEMP "sunup-why-err-$PID.txt"
  try {
    Set-Content -Path $inFile -Value $Prompt -Encoding UTF8 -ErrorAction Stop
    # The prompt goes in on STDIN, not as an argument. It is long and multi-line, which makes
    # command-line quoting a liability, and "@$inFile" (Claude Code's file-reference syntax) makes it
    # fetch the file as a tool call -- slower, and it can decline. Redirected stdin is just the prompt.
    $p = Start-Process -FilePath $claude -ArgumentList @('-p', '--output-format', 'text') `
           -NoNewWindow -PassThru -RedirectStandardInput $inFile `
           -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill() } catch {}
      Write-ToastLog WARN "explanation timed out after ${TimeoutSec}s; using the built-in text."
      return $null
    }
    # JUDGE THE OUTPUT, NOT THE EXIT CODE. Measured on this box (2026-08-12): Start-Process
    # -PassThru leaves ExitCode EMPTY here even after the process has exited and WaitForExit has
    # returned $true -- and `$null -ne 0` is $true in PowerShell, so an `if ($p.ExitCode -ne 0)`
    # guard discarded a perfectly good 12.3-second answer every single time. The output is the thing
    # we actually care about and it is validated below anyway, so that is what decides.
    $exit = $p.ExitCode
    if (($null -ne $exit) -and ($exit -ne 0)) { Write-ToastLog WARN "claude exited $exit." }
    $text = $null
    try { $text = Get-Content $outFile -Raw -Encoding UTF8 -ErrorAction Stop } catch {}
    if (-not $text) {
      $stderr = ''
      try { $stderr = (Get-Content $errFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) } catch {}
      Write-ToastLog WARN "explanation produced nothing; using the built-in text. $stderr"
      return $null
    }
    $text = ($text -replace '\s+', ' ').Trim()
    # Sanity-check the answer rather than trusting it. An over-long or jargon-laden reply is worse
    # than the table sentence it would replace, and this text goes on screen unreviewed.
    if ($text.Length -lt 20 -or $text.Length -gt 400) { Write-ToastLog WARN 'explanation was an implausible length; using the built-in text.'; return $null }
    if ($text -match '(?i)CVE-\d|\bKB\d{6,}') { Write-ToastLog WARN 'explanation contained the jargon it was asked to avoid; using the built-in text.'; return $null }
    return $text
  } catch {
    Write-ToastLog WARN "could not run claude: $_"
    return $null
  } finally {
    foreach ($f in @($inFile, $outFile, $errFile)) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
  }
}

function Get-ExplainedWhy {
  param($Data, [string]$Fallback)
  $mode = ''
  if ($Data -and ($Data.PSObject.Properties.Name -contains 'explain')) { $mode = "$($Data.explain)".ToLower() }
  if ($mode -ne 'auto') { return $Fallback }
  $key = Get-WhyCacheKey $Data
  $hit = Get-CachedWhy $key
  if ($hit) { Write-ToastLog INFO 'explanation: cache hit.'; return $hit }
  $text = Invoke-ClaudeExplain -Prompt (Build-ExplainPrompt $Data) -TimeoutSec $ExplainTimeoutSec
  if (-not $text) { return $Fallback }
  Save-CachedWhy $key $text
  Write-ToastLog INFO 'explanation: researched and cached.'
  $text
}

function Format-Countdown { param([int]$Sec)
  if ($Sec -lt 0) { $Sec = 0 }
  '{0}:{1:00}' -f [math]::Floor($Sec / 60), ($Sec % 60)
}

# ---- the toast --------------------------------------------------------------
# {tick} and {ticklabel} are DATA BINDINGS, not string interpolation -- they are filled from
# NotificationData at Show() time and rewritten by Update() every second without re-popping.
function New-ToastXml {
  param([string]$Subject, [string]$Why, [bool]$Paused)
  $pauseLabel = 'Pause'
  $pauseArg   = 'sunup:pause'
  if ($Paused) { $pauseLabel = 'Unpause'; $pauseArg = 'sunup:resume' }
  $header = 'Restarting Soon'
  if ($Paused) { $header = 'Restart Paused' }
  @"
<toast scenario="reminder" launch="sunup:show" duration="long">
  <visual>
    <binding template="ToastGeneric">
      <text>$(ConvertTo-XmlText $header)</text>
      <text>$(ConvertTo-XmlText $Subject)</text>
      <text placement="attribution">$(ConvertTo-XmlText $Why)</text>
      <progress title="" status="{status}" value="{tick}" valueStringOverride="{ticklabel}"/>
    </binding>
  </visual>
  <actions>
    <action content="Restart now" arguments="sunup:restart" activationType="protocol"/>
    <action content="$pauseLabel" arguments="$pauseArg" activationType="protocol"/>
  </actions>
  <audio silent="true"/>
</toast>
"@
}

$script:seq = 1
# MEASURED, not assumed (2026-08-12): under Windows PowerShell 5.1, NotificationData.Values comes
# back as a bare System.__ComObject with NOTHING projected onto it. `$nd.Values['tick'] = x` throws
# "Unable to index into an object of type System.__ComObject", `.Insert()` does not exist, and it
# will not cast to IDictionary[string,string] either. The only route that works is handing the whole
# dictionary to the CONSTRUCTOR.
#
# The unary comma in -ArgumentList (,$d) is load-bearing: without it PowerShell unrolls the
# dictionary into separate arguments and no matching constructor is found.
#
# SequenceNumber must increase on every write, or Windows discards the update as stale.
function New-ToastData {
  param([int]$Remaining, [int]$Total, [bool]$Paused)
  $frac = 0.0
  if ($Total -gt 0) { $frac = [math]::Round(1.0 - ([double]$Remaining / [double]$Total), 3) }
  if ($frac -lt 0) { $frac = 0.0 }
  if ($frac -gt 1) { $frac = 1.0 }
  $status = 'Restarting in'
  if ($Paused) { $status = 'Paused -- press Unpause to resume' }
  $d = New-Object 'System.Collections.Generic.Dictionary[String,String]'
  $d.Add('tick', "$frac")
  $d.Add('ticklabel', (Format-Countdown $Remaining))
  $d.Add('status', $status)
  $nd = New-Object Windows.UI.Notifications.NotificationData -ArgumentList (, $d)
  $script:seq++
  $nd.SequenceNumber = $script:seq
  $nd
}

function Show-RestartToast {
  param([string]$Subject, [string]$Why, [int]$Remaining, [int]$Total, [bool]$Paused)
  try {
    $xml = New-ToastXml -Subject $Subject -Why $Why -Paused $Paused
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
    $toast.Tag   = $ToastTag
    $toast.Group = $ToastGroup
    $toast.Data  = New-ToastData -Remaining $Remaining -Total $Total -Paused $Paused
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AumId).Show($toast)
    $true
  } catch { Write-ToastLog ERROR "Show failed: $_"; $false }
}

# Silent in-place refresh. 'Failed' means the toast is gone -- the user dismissed it, or Action
# Center dropped it -- which the caller treats as a reason to re-Show rather than to keep counting
# down against a notification nobody can see.
function Update-RestartToast {
  param([int]$Remaining, [int]$Total, [bool]$Paused)
  try {
    $nd = New-ToastData -Remaining $Remaining -Total $Total -Paused $Paused
    $r = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AumId).Update($nd, $ToastTag, $ToastGroup)
    return ("$r" -eq 'Succeeded')
  } catch { return $false }
}

function Hide-RestartToast {
  try { [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($ToastTag, $ToastGroup, $AumId) } catch {}
}

# ---- button plumbing --------------------------------------------------------
# Invoke-ToastAction.ps1 (the sunup: protocol handler) writes a command file; we poll it. A file is
# the right channel here precisely because the handler is a SEPARATE, short-lived process -- there
# is no shared memory to use, and it must work whether or not this process is still alive.
function Clear-ToastCommand {
  try { if (Test-Path $CommandPath) { Remove-Item $CommandPath -Force -ErrorAction Stop } } catch {}
}
function Read-ToastCommand {
  if (-not (Test-Path $CommandPath)) { return $null }
  $cmd = $null
  try { $cmd = (Get-Content $CommandPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json).action } catch {}
  Clear-ToastCommand
  if ($cmd) { "$cmd".Trim().ToLower() } else { $null }
}

# ---- restart ----------------------------------------------------------------
# RECORD FIRST, RESTART SECOND, and if the record cannot be written DO NOT RESTART. A restart
# nothing can later prove happened is one the next logon re-arms a countdown for -- which is the
# 2026-08-12 loop exactly. Refusing costs one postponed update; restarting unrecorded costs the
# user their work, repeatedly.
function Invoke-RestartNow {
  param([string]$RunStamp, [string]$Trigger)
  if ($Demo -or $SelfTest) {
    Write-ToastLog INFO "demo: restart suppressed (trigger=$Trigger)"
    return $true
  }
  $rec = New-RestartRecord -RunStamp $RunStamp -RequestedBy 'toast' -Trigger $Trigger -Method 'Restart-Computer'
  if (-not (Save-RestartRecord $RestartStatePath $rec)) {
    Write-ToastLog ERROR 'ABORTED: could not write restart-state.json -- refusing to restart unrecorded.'
    return $false
  }
  Write-ToastLog INFO "run=$RunStamp trigger=$Trigger method=Restart-Computer boot=$($rec.bootAtRequestEpoch)"
  Hide-RestartToast
  # Restart-Computer -Force first: in this elevated interactive-task context shutdown.exe has been
  # observed returning exit=1 even with SeShutdownPrivilege held (2026-06-27), and only
  # Restart-Computer actually rebooted. shutdown.exe stays as the fallback.
  try { Restart-Computer -Force }
  catch {
    Write-ToastLog WARN "Restart-Computer failed: $_ -> shutdown.exe fallback"
    try { Start-Process shutdown.exe -ArgumentList '/r', '/t', '5', '/c', 'Restarting to finish updates.' -WindowStyle Hidden }
    catch { Write-ToastLog ERROR "shutdown.exe also failed: $_" }
  }
  $true
}

# ---- main -------------------------------------------------------------------
Register-Aum
$preflightOk = Set-NotificationPreflight
if (-not $preflightOk) { Write-ToastLog WARN 'notification preflight could not vouch for every setting (see above).' }

if ($SelfTest) {
  $subject = 'Windows Security Update (KB5121003) and 2 other updates'
  $why     = 'The security fixes are installed but not switched on yet. Until the machine restarts it is still running the code they were meant to fix.'
  $total   = 60
  if (-not (Show-RestartToast -Subject $subject -Why $why -Remaining $total -Total $total -Paused $false)) {
    Write-Host 'self-test FAILED: the toast could not be shown.'
    exit 1
  }
  Write-Host "self-test: toast shown. Counting down $total s; press Pause/Unpause to exercise the toggle. Nothing will restart."
  Clear-ToastCommand
  $remaining = $total; $paused = $false
  while ($remaining -gt 0) {
    Start-Sleep -Seconds 1
    if (-not $paused) { $remaining-- }
    switch (Read-ToastCommand) {
      'pause'   { if (-not $paused) { $paused = $true;  Write-Host '  -> paused';   [void](Show-RestartToast -Subject $subject -Why $why -Remaining $remaining -Total $total -Paused $true) } }
      'resume'  { if ($paused)      { $paused = $false; Write-Host '  -> unpaused'; [void](Show-RestartToast -Subject $subject -Why $why -Remaining $remaining -Total $total -Paused $false) } }
      'restart' { Write-Host '  -> Restart now pressed (suppressed in self-test)'; Hide-RestartToast; exit 0 }
      'dismiss' { Write-Host '  -> dismissed'; Hide-RestartToast; exit 0 }
    }
    if (-not (Update-RestartToast -Remaining $remaining -Total $total -Paused $paused)) {
      Write-Host '  -> toast is no longer on screen (dismissed); stopping.'
      exit 0
    }
  }
  Write-Host 'self-test: countdown finished, restart suppressed.'
  Hide-RestartToast
  exit 0
}

# ---- the real thing ---------------------------------------------------------
if (-not (Test-Path $DataPath)) { Write-ToastLog INFO 'no payload; nothing to do.'; exit 0 }
$data = $null
try { $data = Get-Content $DataPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
  Invoke-DialogFallback "the payload is unreadable: $_"
  exit 2
}

$runEndValue = $null
if ($data.PSObject.Properties.Name -contains 'runEnd') { $runEndValue = $data.runEnd } else { $runEndValue = $data.runEndUtc }
$bootedSinceRun = $false
if ($runEndValue) { $bootedSinceRun = [bool](Test-BootedSince $runEndValue) }

$record  = Get-RestartRecord $RestartStatePath
$restart = Get-RestartDisplayState -Data $data -Record $record -BootEpoch (Get-BootEpoch) `
                                   -BootedSinceRun $bootedSinceRun -BootLocal (Get-BootLocal) -Demo:$Demo
$subject = Get-RestartSubject $data
$why     = Get-RestartWhy $data
$total   = [int]$restart.CountdownSec
$runStamp = "$($data.runStamp)"

if ($Validate) {
  Write-Host "validate OK: mode=$($restart.Mode), countdown=${total}s, runStamp=$runStamp, preflight=$preflightOk"
  Write-Host "  subject: $subject"
  Write-Host "  why:     $why"
  Write-Host (New-ToastXml -Subject $subject -Why $why -Paused $false)
  exit 0
}

# Only 'countdown' may restart anything. postReboot and none are the summary dialog's business, and
# awaitingRestart means the machine has already declined a restart once -- nothing automatic gets to
# ask it a second time.
if ($restart.Mode -ne 'countdown') {
  Write-ToastLog INFO "mode=$($restart.Mode); no countdown to run."
  exit 0
}

# Enrich only now: after we know a toast is going up, and before it does. Doing it earlier would
# spend the call on runs that never show anything, and doing it later would mean rewriting a toast
# the user is already reading. Returns the deterministic text unchanged unless everything succeeds.
$why = Get-ExplainedWhy -Data $data -Fallback $why

if (-not (Show-RestartToast -Subject $subject -Why $why -Remaining $total -Total $total -Paused $false)) {
  Invoke-DialogFallback 'the toast could not be shown'
  exit 2
}
Write-ToastLog INFO "restarting soon: run=$runStamp countdown=${total}s subject='$subject'"
Clear-ToastCommand

$remaining = $total
$paused    = $false
$missing   = 0
while ($true) {
  Start-Sleep -Seconds 1
  if (-not $paused) { $remaining-- }

  $cmd = Read-ToastCommand
  if ($cmd -eq 'pause' -and -not $paused) {
    $paused = $true
    Write-ToastLog INFO "paused by the user with $remaining s left; holding indefinitely."
    [void](Show-RestartToast -Subject $subject -Why $why -Remaining $remaining -Total $total -Paused $true)
    continue
  }
  if ($cmd -eq 'resume' -and $paused) {
    $paused = $false
    Write-ToastLog INFO "resumed by the user with $remaining s left."
    [void](Show-RestartToast -Subject $subject -Why $why -Remaining $remaining -Total $total -Paused $false)
    continue
  }
  if ($cmd -eq 'restart') {
    if (Invoke-RestartNow -RunStamp $runStamp -Trigger 'user-clicked') { exit 0 } else { exit 1 }
  }
  if ($cmd -eq 'dismiss') {
    # Dismissing is not postponing: the restart is still required, and the summary dialog will say
    # so. What it does mean is that nothing further happens without the user asking.
    Write-ToastLog INFO 'dismissed by the user; the restart stays pending.'
    Hide-RestartToast
    exit 0
  }

  if ($remaining -le 0 -and -not $paused) {
    if (Invoke-RestartNow -RunStamp $runStamp -Trigger 'countdown-expired') { exit 0 } else { exit 1 }
  }

  if (-not (Update-RestartToast -Remaining $remaining -Total $total -Paused $paused)) {
    # The toast is gone. Re-show it ONCE rather than counting down invisibly: a restart nobody was
    # warned about is the thing this whole release exists to prevent. If it will not stay up, stop
    # and leave the restart pending for the summary dialog to report.
    $missing++
    if ($missing -ge 2) {
      Invoke-DialogFallback 'the toast will not stay on screen, so the countdown stops here rather than restarting unannounced'
      exit 2
    }
    [void](Show-RestartToast -Subject $subject -Why $why -Remaining $remaining -Total $total -Paused $paused)
  } else {
    $missing = 0
  }
}
