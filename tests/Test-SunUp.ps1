# Tests for the crash-reporting and self-hosting-handoff logic. Safe to run anywhere: no live update
# run, no installs, no reboots, nothing touched outside this folder.
#   1. every shipped script parses;
#   2. Report-CrashedRuns (lifted from source via AST) flags exactly the dead run dirs, once;
#   3. self-hosting packages leave the engine's upgrade list, and SelfHost.ps1 really is runnable
#      by Windows PowerShell 5.1 (parsed by the real 5.1 parser, not pwsh's);
#   5. the engine never upgrades a self-hosting package in-process again;
#   7-9. the user-scope pass, the detached-result ingest, and uninstall.
# (Section 4 covered the Dell/dcu integration, removed in v0.14.0.)
# Run:  pwsh -File .\tests\Test-SunUp.ps1
$src = Join-Path (Split-Path $PSScriptRoot -Parent) 'SunUp.ps1'
$fail = 0
function Check($name, $cond, $detail = '') {
  if ($cond) { Write-Host "  PASS  $name" -ForegroundColor Green }
  else { Write-Host "  FAIL  $name $detail" -ForegroundColor Red; $script:fail++ }
}

Write-Host "`n[1] parse"
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$errs)
Check 'SunUp.ps1 parses with no errors' ($errs.Count -eq 0) ($errs | Out-String)

# Every script that ships. A syntax error in one of these is invisible until the task that runs it
# fails silently in production -- UserScope.ps1 and Uninstall.ps1 had no parse coverage at all.
$repoRoot = Split-Path $PSScriptRoot -Parent
foreach ($f in 'SelfHost.ps1','UserScope.ps1','VendorProfiles.ps1','Install.ps1','Uninstall.ps1','Show-UpdateDialog.ps1','SunUp-Tray.ps1','Status.ps1','Show-AlertToast.ps1') {
  $p = Join-Path $repoRoot $f
  $e = $null
  if (Test-Path $p) {
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e)
    Check "$f parses with no errors" ($e.Count -eq 0) ($e | Out-String)
  } else { Check "$f exists" $false }
}

$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)

# The shared timestamp reader/writer, dot-sourced HERE -- before the AST lifts below, not at [11]
# where it used to be. As of v0.17.0 the engine functions those lifts pull out (Test-RunAlive,
# Import-DetachedResults, Save-StampMerged) call ConvertTo-UtcTime and Get-SunUpTimestamp, which now
# live in RebootState.ps1 rather than in SunUp.ps1. Lifting a function away from its dependencies
# does not throw -- PowerShell resolves the call at run time, so it just returns $null and the
# assertion passes for the wrong reason. Which is exactly how this suite stayed green while
# Show-UpdateDialog.ps1 carried the bug that restarted the box three times.
$rebootStatePath = Join-Path $repoRoot 'RebootState.ps1'
. $rebootStatePath
$rsAst  = [System.Management.Automation.Language.Parser]::ParseFile($rebootStatePath, [ref]$null, [ref]$null)
$rsText = Get-Content $rebootStatePath -Raw

# Source text with whole-line comments removed, for the assertions that say a construct must NOT
# appear. This file documents its bugs by quoting them, so "the engine no longer interpolates
# $stamp.ingestCursor" was matching the comment EXPLAINING that it no longer does -- a guard that
# fails the moment someone describes the thing it guards against. Positive assertions keep using
# the raw text; only the negative ones need this.
# Strips <# block #> comments first, then whole-line # comments. Both matter: these files explain
# themselves at length, and a header that says "there is no auto-resume" would otherwise satisfy a
# search for "auto-resume" and fail the very check asserting the behaviour is absent.
function Get-CodeOnly { param([string]$Text)
  $noBlocks = [regex]::Replace($Text, '(?s)<#.*?#>', '')
  (($noBlocks -split "`r?`n") | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"
}

Write-Host "`n[2] Report-CrashedRuns"
# stubs for the engine's logging surface
$script:logged = @(); $script:events = @(); $script:alerts = @()
function Write-Log { param($Level, $Msg) $script:logged += "$Level|$Msg" }
function Write-Evt { param([int]$Id, [string]$Type = 'Information', [string]$Msg) $script:events += $Id }
$script:claimedAtAlert = @()
function Raise-Alert { param($Msg)
  $script:alerts += $Msg
  # A report must be CLAIMED (incomplete.json created) before it is emitted, or two concurrent
  # scanners would both alert on the same dead run. Record what was true at alert time.
  if ($Msg -match 'Previous run (\S+) never finished') {
    $script:claimedAtAlert += [bool](Test-Path (Join-Path $RunsDir (Join-Path $Matches[1] 'incomplete.json')))
  }
}
$script:Version = 'test'

foreach ($name in 'New-RunDirectory','Publish-JsonFile','Test-RunAlive','Report-CrashedRuns','Import-DetachedResults') {
  $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
  Check "$name found in source" ($null -ne $fn)
  Invoke-Expression $fn.Extent.Text
}

$RunsDir = Join-Path $PSScriptRoot 'runs'
if (Test-Path $RunsDir) { Remove-Item $RunsDir -Recurse -Force }
try {   # everything below is in try/finally so a throwing assertion can't leave tests\runs behind
# good  = finished normally            dead1/dead2 = killed mid-run
# empty = dir with no run.log          live        = this process's own run dir
# peer  = a CONCURRENT run (manual -Force alongside the scheduled task) that is still working
# stale = killed run whose PID has since been recycled by an unrelated process
foreach ($d in 'good','dead1','dead2','empty','live','peer','stale') { New-Item -ItemType Directory -Force (Join-Path $RunsDir $d) | Out-Null }
'x' | Set-Content (Join-Path $RunsDir 'good\run.log');  '{}' | Set-Content (Join-Path $RunsDir 'good\result.json')
@('start','winget: starting…') | Set-Content (Join-Path $RunsDir 'dead1\run.log')
'died here' | Set-Content (Join-Path $RunsDir 'dead2\run.log')
'live run in progress' | Set-Content (Join-Path $RunsDir 'live\run.log')
$script:RunDir = (Join-Path $RunsDir 'live')

# A live peer: marker naming a process that really is running (this one), with its true start time.
$self = Get-Process -Id $PID
'peer still working' | Set-Content (Join-Path $RunsDir 'peer\run.log')
@{ pid = $PID; processName = $self.ProcessName; processStartUtc = $self.StartTime.ToUniversalTime().ToString('o') } |
  ConvertTo-Json | Set-Content (Join-Path $RunsDir 'peer\running.json')
# Recycled PID: same PID and image, but claims a start time that is not this process's.
'died with a marker' | Set-Content (Join-Path $RunsDir 'stale\run.log')
@{ pid = $PID; processName = $self.ProcessName; processStartUtc = $self.StartTime.ToUniversalTime().AddHours(-5).ToString('o') } |
  ConvertTo-Json | Set-Content (Join-Path $RunsDir 'stale\running.json')

# Same-second starts (scheduled run + manual -Force) must never share a run dir.
$sameSecond = ' 2026-07-22_141106'.Trim()
$claims = 1..3 | ForEach-Object { New-RunDirectory $sameSecond $RunsDir }
Check 'concurrent claims on the same stamp get distinct dirs' ((@($claims | Sort-Object -Unique).Count) -eq 3) ($claims -join ' | ')
Check 'the first claim keeps the plain stamp' ((Split-Path $claims[0] -Leaf) -eq $sameSecond)
Check 'later claims are PID-qualified' ((Split-Path $claims[1] -Leaf) -like "${sameSecond}_$PID*")
Check 'every claimed dir actually exists' (@($claims | Where-Object { Test-Path $_ }).Count -eq 3)
$claims | ForEach-Object { Remove-Item $_ -Recurse -Force }

# result.json must only ever appear whole — a truncated one would read as "this run finished".
$okDir = Join-Path $RunsDir 'save-ok'; New-Item -ItemType Directory -Force $okDir | Out-Null
$okPath = Join-Path $okDir 'result.json'
$sample = [ordered]@{ date = '2026-07-27'; components = @(@{ name = 'winget'; status = 'ok' }); updates = @() }
Check 'Publish-JsonFile reports success' (Publish-JsonFile $sample $okPath)
Check 'the published result parses as JSON' ((Get-Content $okPath -Raw | ConvertFrom-Json).components[0].name -eq 'winget')
Check 'no .tmp file is left behind' (-not (Test-Path "$okPath.tmp"))
$badPath = Join-Path $RunsDir 'no-such-dir\deeper\result.json'
Check 'an unwritable destination returns false' (-not (Publish-JsonFile $sample $badPath))
Check 'and leaves no result.json behind' (-not (Test-Path $badPath))

Check 'a live peer is detected as alive' (Test-RunAlive (Join-Path $RunsDir 'peer'))
Check 'a recycled PID is NOT mistaken for alive' (-not (Test-RunAlive (Join-Path $RunsDir 'stale')))
Check 'a dir with no marker is not alive' (-not (Test-RunAlive (Join-Path $RunsDir 'dead1')))

Report-CrashedRuns
Check 'flags the dead runs (incl. recycled-PID marker), not the peer' ($script:events.Count -eq 3) "events=$($script:events -join ',')"
Check 'never flags a concurrent run that is still working' (-not ($script:alerts -match 'peer')) ($script:alerts -join ' | ')
Check 'no incomplete.json written for the live peer' (-not (Test-Path (Join-Path $RunsDir 'peer\incomplete.json')))
Check 'uses event id 2011' (($script:events | Sort-Object -Unique) -join ',' -eq '2011')
Check 'raises an alert per dead run' ($script:alerts.Count -eq 3)
Check 'ignores the finished run' (-not ($script:alerts -match 'good'))
Check 'ignores the run dir with no run.log' (-not ($script:alerts -match 'empty'))
Check 'never flags the live run dir' (-not ($script:alerts -match 'live'))
Check 'quotes the last line the dead run logged' ($script:alerts[0] -match 'winget: starting') $script:alerts[0]
Check 'writes incomplete.json markers' ((Test-Path (Join-Path $RunsDir 'dead1\incomplete.json')) -and (Test-Path (Join-Path $RunsDir 'dead2\incomplete.json')))
Check 'each report is claimed BEFORE it is emitted' ($script:claimedAtAlert.Count -eq 3 -and -not ($script:claimedAtAlert -contains $false)) ($script:claimedAtAlert -join ',')
# A dead run already claimed by a peer scanner must silence this one entirely.
New-Item -ItemType Directory -Force (Join-Path $RunsDir 'claimed') | Out-Null
'peer-claimed run' | Set-Content (Join-Path $RunsDir 'claimed\run.log')
New-Item -ItemType File -Force (Join-Path $RunsDir 'claimed\incomplete.json') | Out-Null
$script:events = @(); $script:alerts = @()
Report-CrashedRuns
Check 'a fresh claim (peer mid-report) is left alone' ($script:events.Count -eq 0 -and $script:alerts.Count -eq 0)

# ...but a claim whose owner died before reporting must NOT silence the crash forever.
$abandoned = Join-Path $RunsDir 'claimed\incomplete.json'
(Get-Item $abandoned).LastWriteTime = (Get-Date).AddHours(-1)
$script:events = @(); $script:alerts = @()
Report-CrashedRuns
Check 'an abandoned claim is retaken and reported' ($script:events.Count -eq 1 -and ($script:alerts -match 'claimed').Count -eq 1) "events=$($script:events -join ',')"
Check 'retaking is logged' (($script:logged -match 're-taking an abandoned crash-report claim').Count -ge 1)
Check 'the retaken claim is now marked reported' ([bool]((Get-Content $abandoned -Raw | ConvertFrom-Json).reported))

# A completed report (reported=true) is never re-emitted, however old it gets.
(Get-Item $abandoned).LastWriteTime = (Get-Date).AddDays(-30)
$script:events = @(); $script:alerts = @()
Report-CrashedRuns
Check 'a completed report is never re-emitted, however stale' ($script:events.Count -eq 0 -and $script:alerts.Count -eq 0)

# A run that publishes result.json in the window between the scan and the claim finished normally,
# and must not be reported. Simulated by having the alert stub publish it mid-flight.
New-Item -ItemType Directory -Force (Join-Path $RunsDir 'racer') | Out-Null
'racing run' | Set-Content (Join-Path $RunsDir 'racer\run.log')
$script:events = @(); $script:alerts = @()
function Test-RunAlive { param([string]$Dir)   # stub: peer completes during the liveness probe
  if ($Dir -like '*racer') { '{}' | Set-Content (Join-Path $Dir 'result.json') }
  $false
}
Report-CrashedRuns
Check 'a peer that completes mid-scan is not reported as crashed' (-not ($script:alerts -match 'racer')) ($script:alerts -join ' | ')
Check 'and its claim is not left behind' (-not (Test-Path (Join-Path $RunsDir 'racer\incomplete.json')))

# The invariant the whole claim protocol now rests on: an exclusive handle can be held by exactly one
# process, and the file stays present and recognizable throughout — no window in which a scanner
# arriving mid-take could read the state as unclaimed.
$lockPath = Join-Path $RunsDir 'lock-probe'
$held = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
$secondTakeFailed = $false
try { [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None).Dispose() }
catch { $secondTakeFailed = $true }
Check 'an exclusive claim handle can be held by only one scanner' $secondTakeFailed
Check 'the marker stays present while it is held' (Test-Path $lockPath)
$held.Dispose()
$reTake = $false
try { [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None).Dispose(); $reTake = $true } catch { }
Check 'the lock is released when its holder goes away' $reTake

$script:events = @(); $script:alerts = @()
Report-CrashedRuns
Check 'second pass is silent (alert fires once)' ($script:events.Count -eq 0 -and $script:alerts.Count -eq 0)

Write-Host "`n[3] self-hosting handoff (v0.12.0)"
$selfPat = 'Microsoft\.PowerShell|Microsoft\.DesktopAppInstaller'
$isSelfHost = { param($Pkg) $Pkg.id -match $selfPat -or $Pkg.name -match $selfPat }
# the real 2026-07-22 list (minus the excluded VCLibs pair) plus App Installer, the OTHER half of the
# default selfHostPattern
$pending = @(
  [pscustomobject]@{ name='Google Chrome';    id='Google.Chrome.EXE';            old='150.0.7871.129'; new='150.0.7871.182' }
  [pscustomobject]@{ name='PowerShell 7-x64'; id='Microsoft.PowerShell';         old='7.6.3.0';        new='7.6.4.0' }
  [pscustomobject]@{ name='App Installer';    id='Microsoft.DesktopAppInstaller'; old='1.29.280.0';    new='1.30.0.0' }
  [pscustomobject]@{ name='Tailscale';        id='tailscale.tailscale';          old='1.98.9';         new='1.99.0' }
)
$deferred = @($pending | Where-Object { & $isSelfHost $_ })
$remaining = @($pending | Where-Object { -not (& $isSelfHost $_) })
Check 'both self-hosting packages are detected' ($deferred.Count -eq 2) (($deferred | ForEach-Object id) -join ',')
# THE v0.12.0 CONTRACT: self-hosting packages leave the engine's upgrade list entirely. If one is
# still in $pending the engine will upgrade it in-process and Restart Manager will kill the run.
Check 'self-hosting packages are REMOVED from the engine list' (@($remaining | Where-Object { & $isSelfHost $_ }).Count -eq 0) (($remaining | ForEach-Object id) -join ',')
Check 'nothing else is dropped' ((($remaining | ForEach-Object id) -join ',') -eq 'Google.Chrome.EXE,tailscale.tailscale')
Check 'no package is lost overall' (($remaining.Count + $deferred.Count) -eq 4)

# The handoff must survive the "only self-hosting packages are pending" case: $pending goes empty,
# and the run must still report the handoff rather than claiming it upgraded nothing of note.
$onlySelf  = @($pending | Where-Object { & $isSelfHost $_ })
$afterOnly = @($onlySelf | Where-Object { -not (& $isSelfHost $_) })
Check 'an all-self-host list empties the engine queue' ($afterOnly.Count -eq 0)
Check 'and still hands off both packages' (@($onlySelf | Where-Object { & $isSelfHost $_ }).Count -eq 2)

Write-Host "`n[3b] SelfHost.ps1 must be runnable by Windows PowerShell 5.1"
$selfSrc = Join-Path (Split-Path $PSScriptRoot -Parent) 'SelfHost.ps1'
Check 'SelfHost.ps1 exists' (Test-Path $selfSrc)
$selfText = Get-Content $selfSrc -Raw

# 5.1 reads a BOM-less file as ANSI, so a single non-ASCII character (an em dash in a comment was
# enough) corrupts the parse and the helper never runs — silently, since it is launched by a task.
$nonAscii = @($selfText.ToCharArray() | Where-Object { [int]$_ -gt 127 })
Check 'SelfHost.ps1 is pure ASCII' ($nonAscii.Count -eq 0) ("$($nonAscii.Count) non-ASCII char(s)")

# Parse it with the REAL 5.1 parser, not pwsh's. This is the check that would have caught the above.
$parse51 = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "
  `$e = `$null
  [void][System.Management.Automation.Language.Parser]::ParseFile('$selfSrc', [ref]`$null, [ref]`$e)
  if (`$e) { 'FAIL: ' + (`$e[0].Message) } else { 'OK' }"
Check 'SelfHost.ps1 parses under Windows PowerShell 5.1' ("$parse51" -eq 'OK') "$parse51"

# The whole point is that the helper does not run in the runtime being replaced.
Check 'the engine launches the helper with powershell.exe, not pwsh' ($src -and ((Get-Content $src -Raw) -match 'WindowsPowerShell\\v1\.0\\powershell\.exe'))
Check 'the helper waits for the engine PID before upgrading' ($selfText -match '\$WaitForPid' -and $selfText -match 'Get-Process -Id \$WaitForPid')
Check 'the helper never reboots the box' ($selfText -notmatch 'shutdown\.exe|Restart-Computer')
Check 'the helper cleans up its own one-shot task' ($selfText -match 'schtasks.*\/delete')

# REGRESSION (found by the first live handoff test): powershell.exe -File passes every argument as
# a literal string and CANNOT bind an array parameter. "-Ids a,b" arrives as the one string "a,b";
# "-Ids a b" binds only "a" and silently drops the rest. Both measured below. The first version
# declared [string[]]$Ids and got a single glued-together package name, so winget answered
# "No installed package found matching input criteria" and upgraded nothing -- while every other
# part of the handoff reported success. Hence: one delimited string, split inside the helper.
$argProbe = Join-Path $PSScriptRoot 'argprobe.ps1'
Set-Content -Path $argProbe -Value 'param([string[]]$Ids); "$($Ids.Count)"' -Encoding Ascii
$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$commaBound = (& $ps51 -NoProfile -ExecutionPolicy Bypass -File $argProbe -Ids 'aaa,bbb') -join ''
$spaceBound = (& $ps51 -NoProfile -ExecutionPolicy Bypass -File $argProbe -Ids 'aaa' 'bbb') -join ''
Remove-Item $argProbe -Force -ErrorAction SilentlyContinue
Check '-File cannot bind a comma list to an array (so we must split ourselves)' ($commaBound -eq '1') "got $commaBound"
Check '-File silently drops extra space-separated values too'                   ($spaceBound -eq '1') "got $spaceBound"

Check 'SelfHost.ps1 declares Ids as a single string, not an array' ($selfText -match '\[Parameter\(Mandatory = \$true\)\]\[string\]\$Ids')
Check 'SelfHost.ps1 splits Ids on commas itself' ($selfText -match [regex]::Escape('$IdList = @($Ids -split '','''))
Check 'SelfHost.ps1 upgrades from the SPLIT list, not the raw string' ($selfText -match 'foreach \(\$id in \$IdList\)')
Check 'the engine passes the ids comma-joined to match' ((Get-Content $src -Raw) -match "\`$shIds -join ','")

# THE RETRY GATE. --custom REBOOT=ReallySuppress is what stops the PowerShell MSI restarting the box
# behind SunUp's back; the retry drops it, so it may only fire when winget rejected the ARGUMENT,
# before touching the installer. Gating on 'Starting package install' alone was too narrow -- a
# failure mid-download shows none of it, so a network blip was retried WITHOUT the suppression and
# the MSI was free to reboot the machine unannounced. These are the three markers the engine's
# deleted Test-WingetArgsRejected checked, and the case its deleted tests covered.
$sast = [System.Management.Automation.Language.Parser]::ParseFile($selfSrc, [ref]$null, [ref]$null)
$tisFn = $sast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-InstallStarted' }, $true)
Check 'Test-InstallStarted found in SelfHost.ps1' ($null -ne $tisFn)
if ($tisFn) { Invoke-Expression $tisFn.Extent.Text }
Check 'a failed DOWNLOAD counts as work started (so it is NOT retried without the reboot suppression)' `
      (Test-InstallStarted "Found PowerShell 7-x64 [Microsoft.PowerShell]`nDownloading https://github.com/PowerShell/PowerShell/releases/x.msi`n0x80072ee2")
Check 'a verified installer hash counts too' (Test-InstallStarted "Successfully verified installer hash`n")
Check 'so does an install that began'        (Test-InstallStarted "Starting package install...`n")
Check 'but an argument rejection before any work does not' (-not (Test-InstallStarted "Invalid argument provided: --custom`nUsage: winget upgrade"))
Check 'the retry gate actually uses it' ($selfText -match 'Test-InstallStarted \$txt')

# Upgrading Microsoft.DesktopAppInstaller replaces the very WindowsApps folder the resolved winget
# path points into, so the cached path is dangling for every package after it. The failed launch
# raises CommandNotFoundException (which 2>&1 does not capture) and leaves $LASTEXITCODE at the
# previous package's 0 -- recorded as "upgraded (exit 0x00000000)" for a package winget never saw.
Check 'the helper re-resolves winget for each package' ($selfText -match 'foreach \(\$id in \$IdList\)[\s\S]{0,1500}\$winget\s+= Resolve-Winget')
Check 'a package that could not be launched is never counted as upgraded' ($selfText -match '\$isOk = \(\$launched -and')
Check 'and its record says so rather than showing exit 0' ($selfText -match "\`$exitText = '\(not launched\)'")
Check 'concurrent SunUp winget passes are serialized by a machine-wide mutex' ($selfText -match 'Global\\SunUp-Winget')
# The two holders are different principals (SYSTEM and the interactive user), and a mutex created
# with the default constructor carries the creator's token security -- so the second principal can be
# denied on open, and a swallowed failure there means both passes run winget at once.
Check 'the mutex has an explicit cross-principal ACL' ($selfText -match 'MutexSecurity' -and $selfText -match 'S-1-5-32-544')
Check 'and failing to take it is logged, not swallowed' ($selfText -match 'could not take the winget lock')
# Proceeding unserialized undermines the only thing the lock is for: winget refuses two concurrent
# installs, so the packages go un-upgraded anyway, with a spurious per-package failure to explain.
Check 'no lock means NO upgrade, reported as a failed handoff' `
      ($selfText -match 'if \(\$winget -and -not \$haveMutex\)' -and $selfText -match "exitCode = '\(no winget lock\)'" -and $selfText -notmatch 'held the lock for 60 minutes -- proceeding anyway')
Check 'the helper waits for the user-scope task as well as the engine pid' ($selfText -match '\$WaitForTask' -and $selfText -match 'Get-ScheduledTask -TaskName \$WaitForTask')
Check 'the helper can sit out an interactive reboot countdown' ($selfText -match '\$InitialDelaySec' -and $selfText -match 'Start-Sleep -Seconds \$InitialDelaySec')
Check 'the helper labels its own log/json (so the user pass cannot clobber the SYSTEM one)' ($selfText -match '\$SelfJson = Join-Path \$RunDir \(\$Label')

Write-Host "`n[5] the engine no longer upgrades self-hosting packages in-process"
# REGRESSION GUARD for the v0.12.0 fix. Three runs died because the engine ran the PowerShell
# upgrade itself; if that ever comes back, this catches it in source rather than in production
# eight days later.
$engineText = Get-Content $src -Raw
# Comments explaining WHY the old approach was dropped legitimately name --custom, so test the
# actual code: strip full-line comments and the trailing part of inline ones before matching.
$engineCode = (Get-Content $src | ForEach-Object { ($_ -replace '(?<!`)#.*$', '').TrimEnd() } | Where-Object { $_ }) -join "`n"
$offenders = @(Get-Content $src | Where-Object { ($_ -replace '(?<!`)#.*$', '') -match '--custom' })
Check 'the engine passes no --custom installer args any more' ($engineCode -notmatch '--custom') ($offenders -join ' | ')
Check 'the engine registers the one-shot handoff task' ($engineText -match 'Register-ScheduledTask -TaskName \$SelfHostTask')
# Skipped for the HEADLESS reboot only. When a user is logged in, $willReboot merely means the dialog
# offers a CANCELLABLE countdown -- deferring on that alone cost a whole day every time someone
# clicked Postpone, for a reboot that then never happened.
Check 'the handoff is skipped for the headless reboot' ($engineText -match "rebootAction -eq 'reboot'" -and $engineText -match 'headless reboot imminent')
Check 'but an interactive countdown is waited out, not deferred' ($engineText -match '\$shDelay = if \(\$result\.rebootAction -eq .dialog-countdown.\)' -and $engineText -match '-InitialDelaySec')
# Start-ScheduledTask returns success without running anything when an IgnoreNew task is already
# active, so the "started ... " log line and event 2020 were claims, not observations.
Check 'the engine verifies the task really started before claiming a handoff' ($engineText -match 'function Start-TaskVerified' -and $engineText -match 'Start-TaskVerified \$SelfHostTask')
Check 'a no-op start is reported as NOT started' ($engineText -match 'did NOT start')
Check 'the helper is told to wait for the user-scope task too' ($engineText -match '-WaitForTask')

Write-Host "`n[6] the update-collapse block must not clobber `$Name"
# REGRESSION: the block assigned $name for a row label. PowerShell variable names are
# case-insensitive and the block runs at SCRIPT scope, so it overwrote the global $Name = 'SunUp'
# with the last collapsed update's product name. Real runs logged "===== Google Chrome run end ====="
# (2026-07-18) and raised event 2001 as "Tailscale run ... clean" (2026-07-28). It only triggered
# with 2+ updates in a run, which made it look intermittent. Lift the real block and run it.
$srcText = Get-Content $src -Raw
$m = [regex]::Match($srcText, '(?ms)^# ---- collapse exact-duplicate update rows.*?(?=^# ---- structured result)')
Check 'the collapse block was found in source' $m.Success
$Name = 'SunUp'
$script:Updates = [System.Collections.Generic.List[object]]::new()
$script:Updates.Add([ordered]@{ name='Tailscale';    source='winget'; old='1.98.9'; new='1.99.0';  durationSec=3; sizeMB=10 })
$script:Updates.Add([ordered]@{ name='Google Chrome'; source='winget'; old='150.0';  new='150.1';   durationSec=4; sizeMB=90; meta=[ordered]@{ kb='KB5121003'; severity='Critical' } })
$script:Updates.Add([ordered]@{ name='Google Chrome'; source='winget'; old='150.0';  new='150.1';   durationSec=4; sizeMB=90; meta=[ordered]@{ kb='KB5121003'; severity='Critical' } })
Invoke-Expression $m.Value
Check '$Name survives the collapse block' ($Name -eq 'SunUp') "got '$Name'"
Check 'duplicate rows still collapse' ($script:Updates.Count -eq 2) "$($script:Updates.Count) rows"
Check 'and the collapsed row is annotated' (($script:Updates | ForEach-Object { $_.name }) -join ',' -match ([char]0x00D7)) (($script:Updates | ForEach-Object { $_.name }) -join ',')
# FOUND BY DEPLOYING IT (2026-08-12), not by reading it. This block REBUILDS every row from a fresh
# [ordered] literal, so a field it does not name is dropped -- and the first live run under v0.17.0
# emitted no meta on any row. It only bites a run with 2+ updates, which is precisely the run where
# the restart notification most needs to say what it is restarting for. Same shape as the $Name bug
# above, in the same block, for the same reason.
$collapsed = @($script:Updates | Where-Object { $_.name -like 'Google Chrome*' })[0]
Check 'and the row keeps its metadata, which the notification explains itself out of' `
      ("$($collapsed.meta.kb)" -eq 'KB5121003') "got '$($collapsed.meta.kb)'"
Check 'while a row that never had metadata does not gain an empty one' `
      (-not (@($script:Updates | Where-Object { $_.name -eq 'Tailscale' })[0].Keys -contains 'meta'))

Write-Host "`n[7] user-scope pass (v0.13.0)"
$userSrc = Join-Path (Split-Path $PSScriptRoot -Parent) 'UserScope.ps1'
Check 'UserScope.ps1 exists' (Test-Path $userSrc)
$userText = Get-Content $userSrc -Raw
$uast = [System.Management.Automation.Language.Parser]::ParseFile($userSrc, [ref]$null, [ref]$null)
$pu = $uast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Parse-Upgrades' }, $true)
Check 'Parse-Upgrades found in source' ($null -ne $pu)
Invoke-Expression $pu.Extent.Text

# The REAL user-scope output measured on caldera 2026-07-28 - the list SYSTEM could not see.
$realUserList = @(
  'Name               Id                           Version                       Available'
  '-----------------------------------------------------------------------------------------------------------'
  'Deno               DenoLand.Deno                2.9.2                         2.9.4'
  'FFmpeg for yt-dlp  yt-dlp.FFmpeg                N-124716-g054dffd133-20260531 N-125365-g9a01c1cb6a-20260630'
  'fzf                junegunn.fzf                 0.73.1                        0.74.1'
  'LM Studio 0.4.16+2 ElementLabs.LMStudio         0.4.16+2                      0.4.20+1'
  'RipGrep MSVC       BurntSushi.ripgrep.MSVC      15.1.0                        15.2.0'
  'Rufus              Rufus.Rufus                  4.14                          4.15'
  'Sysinternals Suite Microsoft.Sysinternals.Suite 2026-06-17                    2026-07-09'
  '7 upgrades available.'
)
$parsed = @(Parse-Upgrades $realUserList)
Check 'parses every row, dropping header/rule/footer' ($parsed.Count -eq 7) "$($parsed.Count) rows"
Check 'ids are read from the right column' ((($parsed | ForEach-Object { $_.id }) -join ',') -eq 'DenoLand.Deno,yt-dlp.FFmpeg,junegunn.fzf,ElementLabs.LMStudio,BurntSushi.ripgrep.MSVC,Rufus.Rufus,Microsoft.Sysinternals.Suite')
Check 'a version containing dashes survives' ((@($parsed | Where-Object { $_.id -eq 'yt-dlp.FFmpeg' }).new) -eq 'N-125365-g9a01c1cb6a-20260630')

# THE POLICY CONTRACT: excludePattern is SHARED with the engine, so an app excluded there is
# excluded here. LM Studio must be skipped; the six that match nothing must all go through.
$exclReal = 'NVIDIA|GeForce|Claude|Anthropic|ElementLabs|LM ?Studio|Spotify|Discord|Slack|Teams|VCLibs'
$selfReal = 'Microsoft\.PowerShell|Microsoft\.DesktopAppInstaller'
$uPending = @($parsed | Where-Object {
  -not ($_.name -match $exclReal -or $_.id -match $exclReal) -and
  -not ($_.name -match $selfReal -or $_.id -match $selfReal) })
$uSkipped = @($parsed | Where-Object { $_.name -match $exclReal -or $_.id -match $exclReal })
Check 'LM Studio is still excluded in user scope' ((($uSkipped | ForEach-Object { $_.id }) -join ',') -eq 'ElementLabs.LMStudio')
Check 'the six scope-only packages all pass the filter' ($uPending.Count -eq 6) (($uPending | ForEach-Object { $_.id }) -join ',')
Check 'ripgrep specifically is now covered' ((($uPending | ForEach-Object { $_.id }) -contains 'BurntSushi.ripgrep.MSVC'))
# Microsoft.Sysinternals.Suite starts with "Microsoft." - it must NOT be caught by selfHostPattern.
Check 'Sysinternals is not mistaken for a self-hosting package' ((($uPending | ForEach-Object { $_.id }) -contains 'Microsoft.Sysinternals.Suite'))

Check 'the user pass never reboots the box' ($userText -notmatch 'shutdown\.exe|Restart-Computer')
Check 'the user pass reads excludePattern from the shared config' ($userText -match 'cfg\.winget\.excludePattern')
Check 'a failed upgrade LIST is not reported as up to date' ($userText -match 'list failed' -and $userText -match '\$listCode -ne 0')

# Get-Content's missing/locked-file error is NON-TERMINATING under $ErrorActionPreference='Continue',
# so a bare try/catch around it never fires: $cfg stayed $null and every setting -- including
# "userScope": false -- silently fell through to the built-in defaults, with no warning written.
Check 'the config read cannot fall through to defaults in silence' ($userText -match 'Test-Path \$ConfigFile' -and $userText -match 'Get-Content \$ConfigFile -Raw -ErrorAction Stop')

# HKCU-registered self-hosting packages cannot go to the SYSTEM handoff -- SYSTEM cannot see them at
# all, which is this script's entire premise -- so "left N to the SYSTEM handoff" meant nobody ever
# upgraded them while the log claimed otherwise.
Check 'self-hosting packages get a REAL handoff, run by 5.1 as this user' `
      ($userText -match 'SelfHost\.ps1' -and $userText -match 'WindowsPowerShell\\v1\.0\\powershell\.exe' -and $userText -match '-Label user-selfhost')
# Assert the ARGUMENT in the launch string, not the word anywhere in the file: an `-or ... -match
# 'WaitForPid'` alternative also matched the comment text, so the check could not fail.
Check 'the helper waits for this pass to exit first' ($userText -match '-WaitForPid \{5\}')
Check 'an immediately-exiting helper is a failure, not a handoff' ($userText -match '-PassThru' -and $userText -match 'exited immediately')
Check 'and the pass no longer claims the SYSTEM handoff will take them' ($userText -notmatch 'to the SYSTEM handoff:')

$engineText2 = Get-Content $src -Raw
Check 'the engine starts the user task only when interactive' ($engineText2 -match 'if \(-not \$interactive\)[\s\S]{0,400}Start-TaskVerified \$UserTask')
Check 'and says so when there is no session' ($engineText2 -match 'no interactive session')
# The pass routinely outlives a 300s interactive countdown, so starting it into a pending reboot
# means restarting on top of a live `winget upgrade`. Its sibling handoff has always guarded this.
Check 'the user pass is NOT started when this run is going to reboot' ($engineText2 -match 'elseif \(\$willReboot\)[\s\S]{0,240}skipping \$UserTask')
Check 'winget.userScope=false actually disables it' ($engineText2 -match '\$userScopeEnabled = \$cfg\.winget\.enabled')
Check 'the user task start is verified, not assumed' ($engineText2 -match '\$uStart = Start-TaskVerified \$UserTask')

Write-Host "`n[8] the detached passes are folded back into the next run"
# SelfHost.ps1 and UserScope.ps1 finish after the engine that started them has exited, so their
# results cannot be in that run's result.json -- and nothing read the JSON they leave behind. A
# PowerShell 7 upgrade therefore never appeared in updates[], the dialog or the history; a FAILED
# one never appeared anywhere at all; and a winget "restart required" exit code was lost outright,
# since the engine had already decided about rebooting and winget sets no OS pending flag for the
# watchdog to find.
$script:Updates = [System.Collections.Generic.List[object]]::new()
function Add-Update { param($Name, $Source, $Old, $New, $DurationSec, $SizeMB)
  $script:Updates.Add([ordered]@{ name = $Name; source = $Source; old = $Old; new = $New })
}
$hd = Join-Path $RunsDir 'zz-handoff-run'      # sorts first descending, so it is always scanned
New-Item -ItemType Directory -Force $hd | Out-Null
@{ finishedLocal = '2026-08-01T09:00:00'; ids = @('Microsoft.PowerShell'); ok = 1; failed = 0; rebootRequired = $true
   results = @(@{ id = 'Microsoft.PowerShell'; exitCode = '0x8A150077'; ok = $true; durationSec = 42 }) } |
  ConvertTo-Json -Depth 6 | Set-Content (Join-Path $hd 'selfhost.json')
@{ finishedLocal = '2026-08-01T09:10:00'; user = 'bradley'; ok = 1; failed = 1; skipped = 0; rebootRequired = $false
   results = @(
     @{ id = 'Rufus.Rufus';   name = 'Rufus'; old = '4.14';  new = '4.15';  exitCode = '0x00000000'; ok = $true;  durationSec = 9 }
     @{ id = 'DenoLand.Deno'; name = 'Deno';  old = '2.9.2'; new = '2.9.4'; exitCode = '0x8A150011'; ok = $false; durationSec = 3 }) } |
  ConvertTo-Json -Depth 6 | Set-Content (Join-Path $hd 'user-winget.json')
$script:RunDir = Join-Path $RunsDir 'live'
$ing = Import-DetachedResults
$ingNames = @($script:Updates | ForEach-Object { $_.name })
Check 'a self-host upgrade the engine never saw is recorded as an update' ($ingNames -contains 'Microsoft.PowerShell') ($ingNames -join ',')
Check 'so is a user-scope upgrade, with its versions' ((@($script:Updates | Where-Object { $_.name -eq 'Rufus' }).new) -eq '4.15')
Check 'a FAILED detached upgrade is counted, not silently dropped' ($ing.failed -eq 1) "failed=$($ing.failed)"
Check 'and it is named' (($ing.notes -join ' ') -match 'DenoLand\.Deno') ($ing.notes -join ' | ')
Check 'a reboot the helper needed reaches the engine' ($ing.reboot)
# ...but not one the box has already been rebooted for. A manual restart between the helper finishing
# and the next run satisfies the request; importing it anyway would schedule a second, pointless one.
$hd3 = Join-Path $RunsDir 'zx-prebooted-run'
New-Item -ItemType Directory -Force $hd3 | Out-Null
@{ finishedLocal = '2026-08-01T09:00:00'; ok = 1; failed = 0; rebootRequired = $true
   results = @(@{ id = 'Microsoft.PowerShell'; exitCode = '0x8A150077'; ok = $true; durationSec = 5 }) } |
  ConvertTo-Json -Depth 6 | Set-Content (Join-Path $hd3 'selfhost.json')
# The record's timestamp is the file's write time (when it became visible), so age it accordingly.
(Get-Item (Join-Path $hd3 'selfhost.json')).LastWriteTime = [datetime]'2026-08-01T09:00:00'
$booted = Import-DetachedResults $null ([datetime]'2026-08-01T12:00:00').ToUniversalTime()
Check 'a reboot request already satisfied by a boot is not re-raised' (-not $booted.reboot)
Check 'while its upgrade is still recorded' ($booted.upgraded -eq 1)
Check 'the successful ones are counted' ($ing.upgraded -eq 2) "upgraded=$($ing.upgraded)"
$beforeRows = $script:Updates.Count
$again = Import-DetachedResults
Check 'ingesting twice does not double-count' ($again.upgraded -eq 0 -and $again.failed -eq 0 -and -not $again.reboot -and $script:Updates.Count -eq $beforeRows)
Check 'because the records are marked ingested on disk' ([bool]((Get-Content (Join-Path $hd 'selfhost.json') -Raw | ConvertFrom-Json).ingested))

# THE CURSOR. A helper can finish long after its own run (it waits for the engine, the user task, a
# reboot countdown, the winget lock), by which time several -Force runs may have made newer dirs --
# so discovery cannot be capped by directory count. What keeps week-old news out of today's dialog is
# the cursor: anything written before the last run ended is consumed without being counted.
$hd2 = Join-Path $RunsDir 'zy-stale-run'
New-Item -ItemType Directory -Force $hd2 | Out-Null
@{ finishedLocal = '2026-07-20T09:00:00'; user = 'bradley'; ok = 1; failed = 0; skipped = 0; rebootRequired = $true
   results = @(@{ id = 'Old.Package'; name = 'Old Package'; old = '1.0'; new = '2.0'; exitCode = '0x00000000'; ok = $true; durationSec = 1 }) } |
  ConvertTo-Json -Depth 6 | Set-Content (Join-Path $hd2 'user-winget.json')
(Get-Item (Join-Path $hd2 'user-winget.json')).LastWriteTime = [datetime]'2026-07-20T09:00:00'
$rowsBefore = $script:Updates.Count
$staleIng   = Import-DetachedResults ([datetime]'2026-07-25T00:00:00')
Check 'a record older than the cursor is not counted as this run''s work' ($staleIng.upgraded -eq 0 -and $script:Updates.Count -eq $rowsBefore)
Check 'nor does its reboot request resurface days later' (-not $staleIng.reboot)
Check 'but it IS marked consumed, so it cannot come back' ([bool]((Get-Content (Join-Path $hd2 'user-winget.json') -Raw | ConvertFrom-Json).ingested))
Check 'discovery is bounded by that cursor, not by a directory count' `
      ($engineText2 -match 'function Import-DetachedResults \{ param\(\$Since' -and $engineText2 -notmatch 'Sort-Object Name -Descending \| Select-Object -First 3')
# The cursor is the moment the scan BEGAN, not when the run ended: a helper writing in the gap
# between the two would otherwise look old to the next run and be consumed unread.
Check 'the cursor is taken before the scan, not after the run' `
      ($engineText2 -match '(?s)\$ingestScanAt = \(Get-Date\)\.ToUniversalTime\(\).*\$detached = Import-DetachedResults \$ingestCursor')
# A record is judged by when it became VISIBLE, not by the finishedLocal stamped inside it before
# serializing: a scan that caught a half-written file skipped it as unreadable, and the earlier
# embedded time would then bury the completed record as stale. Both producers publish atomically so
# that window does not exist in the first place.
Check 'ingestion compares the file write time, not the embedded timestamp' `
      ($engineText2 -match "\`$written = try \{ \(Get-Item \`$p -ErrorAction Stop\)\.LastWriteTimeUtc")
# In local time the repeated hour after a daylight-saving fall-back gives a file written AFTER the
# cursor a wall-clock stamp that reads as earlier - consuming a brand-new record unread, once a year.
Check 'and it compares in UTC, so a DST fall-back cannot bury a record' `
      ($engineText2 -match '\$sinceUtc = if \(\$Since\) \{ \$Since\.ToUniversalTime\(\) \}' -and $engineText2 -match '\$ingestScanAt = \(Get-Date\)\.ToUniversalTime\(\)')
Check 'the self-host helper publishes its record atomically' `
      ($selfText -match 'function Publish-Json' -and $selfText -match 'Move-Item -Path \$tmp -Destination \$Path -Force')
Check 'so does the user-scope pass' `
      ($userText -match 'function Publish-Json' -and $userText -match 'Publish-Json.*\$UserJson')
Check 'and neither writes the live file directly any more' `
      ($selfText -notmatch 'Set-Content -Path \$SelfJson' -and $userText -notmatch 'Set-Content \$UserJson')
Check 'and it is persisted separately from finishedLocal' `
      ($engineText2 -match '\$nextCursor = if \(\$detached\.scanned\) \{ Get-SunUpTimestamp \$ingestScanAt' -and $engineText2 -match 'ingestCursor = \$nextCursor')
# The carry arm used to be "$($stamp.ingestCursor)": interpolating a value ConvertFrom-Json had
# already turned back into a [datetime] wrote culture text to disk, which the next run read as local
# and pushed SEVEN HOURS INTO THE FUTURE -- consuming every helper record written in that window.
$engineCode = Get-CodeOnly $engineText2
Check 'and the carry arm normalizes it instead of interpolating it' `
      ($engineText2 -match 'elseif \(\$stamp\) \{ Get-SunUpTimestamp \$stamp\.ingestCursor' -and $engineCode -notmatch '"\$\(\$stamp\.ingestCursor\)"')
Check 'the same for the stale-reboot tracker' `
      ($engineText2 -match 'Get-SunUpTimestamp \$stamp\.pendingSince' -and $engineCode -notmatch '"\$\(\$stamp\.pendingSince\)"')
Check 'a stamp from before the cursor existed still works' ($engineText2 -match '\$ingestCursor = \$lastRunEnd')

# A reboot a detached pass asked for must outlive the run that ingests it: with a user logged in that
# run only offers a CANCELLABLE countdown, and a winget-signalled reboot sets no OS pending flag.
Check 'a detached reboot request survives a postponed countdown' `
      ($engineText2 -match 'handoffRebootPending' -and $engineText2 -match '\$carriedReboot' -and $engineText2 -match 'LastBootUpTime')
Check 'and is cleared only once the box has actually booted' ($engineText2 -match '\$bootedSinceLastRun')
# Confirming "the task is Running" proved nothing: an instance that entered Running between the
# pre-check and the start is precisely the one IgnoreNew dropped ours in favour of.
Check 'the task-start confirmation is anchored to OUR start call' `
      ($engineText2 -match '\$startedAt = Get-Date' -and $engineText2 -match '\$now -ge \$startedAt\.AddSeconds\(-2\)')

# Read-count-then-mark is not atomic, and a manual -Force run can overlap a scheduled one: both would
# count the same upgrade into their own history and both act on its reboot request.
Check 'ingestion is serialized across concurrent engines' `
      ($engineText2 -match 'Global\\SunUp-Ingest' -and $engineText2 -match 'another run holds the ingest lock')
Check 'and a run that cannot take the lock ingests NOTHING' `
      ($engineText2 -match '(?s)another run holds the ingest lock.{0,120}return \$out')
# A lock that cannot even be CREATED must abort too - falling through would be a fail-open path in
# the guard added to stop double-counting.
Check 'nor does it ingest unlocked when the mutex cannot be created' `
      ($engineText2 -match '(?s)could not create the ingest lock.{0,120}return \$out')
# ...and an aborted ingest must not advance the cursor, or the next run writes off every record that
# already existed as stale - the loss the cursor exists to prevent, via the abort path.
Check 'an aborted ingest leaves the cursor where it was' `
      ($engineText2 -match '\$out\.scanned = \$true' -and $engineText2 -match '\$nextCursor = if \(\$detached\.scanned\)')
Check 'and the stamp saves that conditional cursor, not the attempt time' ($engineText2 -match 'ingestCursor = \$nextCursor')
# The ingest lock is released long before the stamp is written, so an overlapping run can ingest a
# reboot record and stamp it in between - and an unconditional write would blank the flag for a
# record already marked ingested, losing that reboot for good.
Check 'the stamp write merges with the on-disk state instead of clobbering it' `
      ($engineText2 -match 'function Save-StampMerged' -and $engineText2 -match 'Save-StampMerged \(\[ordered\]@\{')
Check 'a peer''s reboot flag is never cleared, only an observed boot clears it' `
      ($engineText2 -match 'if \(-not \$Booted -and \$onDisk -and \$onDisk\.handoffRebootPending\) \{ \$Obj\.handoffRebootPending = \$true \}')
Check 'and the cursor only ever moves forward' ($engineText2 -match 'if \(\$theirs -and \$theirs -gt \$ours\) \{ \$Obj\.ingestCursor = \$onDisk\.ingestCursor')
# Unlike the ingest, this one must NOT abandon the write when the lock is unavailable: the stamp also
# carries the once-per-day gate, and skipping it would have the next trigger re-run everything. It
# writes, verifies, and retries instead.
Check 'an unlocked stamp write is verified and retried, not skipped' `
      ($engineText2 -match 'for \(\$attempt = 1; \$attempt -le 3; \$attempt\+\+\)' -and $engineText2 -match 'a concurrent run rewrote it')
# FOUND BY RUNNING IT, not by reading it: ConvertFrom-Json parses an ISO-8601 stamp value back into a
# [datetime], whose string form is culture-formatted LOCAL time ("08/03/2026 06:18:05") and never
# equals the round-trip string it was written from. The verification compared those as text, so every
# single run logged a phantom "a concurrent run rewrote it" and wrote the stamp three times.
$cvFn = $rsAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-UtcTime' }, $true)
Check 'ConvertTo-UtcTime is defined in RebootState.ps1, shared by every consumer' ($null -ne $cvFn)
# The engine may still define it, but ONLY inside the degraded fallback that runs when bin\ is
# missing the shared file -- never as its own primary implementation. That is the difference between
# a graceful degradation and the second copy that drifts.
$dotSourceAt = $engineText2.IndexOf('if (Test-Path $RebootStateScript) { . $RebootStateScript }')
$configAt    = $engineText2.IndexOf('# ---- config ---')
$cvInEngine  = @([regex]::Matches($engineText2, 'function ConvertTo-UtcTime'))
Check 'and the engine keeps no primary copy -- only the degraded fallback defines one' `
      ($dotSourceAt -gt 0 -and $configAt -gt $dotSourceAt -and $cvInEngine.Count -eq 1 -and
       $cvInEngine[0].Index -gt $dotSourceAt -and $cvInEngine[0].Index -lt $configAt) `
      "defs=$($cvInEngine.Count)"
if ($cvFn) {
  $iso = '2026-08-03T06:18:05.9758571Z'
  $roundTripped = ('{"ingestCursor":"' + $iso + '"}' | ConvertFrom-Json).ingestCursor
  Check 'the round-tripped stamp value really is a DateTime, not a string' ($roundTripped -is [datetime])
  Check 'a raw string compare would have differed (the bug)' ("$roundTripped" -ne $iso)
  Check 'but as UTC instants they are equal (the fix)' ((ConvertTo-UtcTime $roundTripped) -eq (ConvertTo-UtcTime $iso))
  Check 'and a genuinely different instant still compares unequal' ((ConvertTo-UtcTime $iso) -ne (ConvertTo-UtcTime '2026-08-03T07:18:05.9758571Z'))
  Check 'empty and null normalize to null, not to a date' ((-not (ConvertTo-UtcTime '')) -and (-not (ConvertTo-UtcTime $null)))
}
Check 'the stamp verification compares instants, not text' ($engineText2 -match 'ConvertTo-UtcTime \$after\.ingestCursor')
# The task-start confirmation is only as good as its pre-check: two engines can both pass it before
# either instance is Running, and both then see the same advanced LastRunTime.
Check 'task starts are serialized so only the real starter claims success' `
      ($engineText2 -match 'Global\\SunUp-TaskStart' -and $engineText2 -match 'another run holds the task-start lock')
$ingFn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Import-DetachedResults' }, $true)
Check 'every abort path leaves scanned false' `
      (@([regex]::Matches($ingFn.Extent.Text, 'return \$out')).Count -ge 3 -and @([regex]::Matches($ingFn.Extent.Text, '\$out\.scanned = \$true')).Count -eq 1)

Check 'the engine folds them in BEFORE deciding about rebooting' `
      ($engineText2 -match '(?s)\$detached = Import-DetachedResults.*\$rebootRequiredByRun = @\(\$results')
Check 'and reports them as a component, so a failure is not invisible' ($engineText2 -match "name        = 'handoff'")
Check 'a run with warnings no longer logs event 2001 clean' ($engineText2 -match 'Write-Evt 2002 Warning')

Write-Host "`n[10] OEM detection and the vendorUpdates policy (v0.15.0)"
# THE CASE THAT DEFEATS THE OBVIOUS IMPLEMENTATION: this box reports 'Alienware' in Manufacturer,
# SystemFamily AND BIOS vendor, and 'Dell' in none of them. A `-match 'Dell'` check would have
# concluded "not a Dell" on an actual Dell, and silently blocked nothing.
. (Join-Path $repoRoot 'VendorProfiles.ps1')
Check 'Get-SystemVendor is loadable standalone (no engine dependency)' ($null -ne (Get-Command Get-SystemVendor -ErrorAction SilentlyContinue))
$alien = Get-SystemVendor -Manufacturer 'Alienware' -Family 'Alienware' -BiosVendor 'Alienware'
Check 'an Alienware is recognized as Dell (measured on caldera: no field says "Dell")' ($alien -and $alien.name -eq 'Dell') "got '$($alien.name)'"
Check 'and carries both delivering-path patterns' ($alien.wuTitle -match 'Dell' -and $alien.winget -match 'Dell')
$cases = @(
  @{ mfr = 'Dell Inc.';               fam = 'Latitude';    expect = 'Dell'      }
  @{ mfr = 'LENOVO';                  fam = 'ThinkPad T14'; expect = 'Lenovo'   }
  @{ mfr = 'HP';                      fam = 'EliteBook';   expect = 'HP'        }
  @{ mfr = 'Hewlett-Packard';         fam = '';            expect = 'HP'        }
  @{ mfr = 'ASUSTeK COMPUTER INC.';   fam = 'ROG';         expect = 'ASUS'      }
  @{ mfr = 'Micro-Star International'; fam = 'GS66';       expect = 'MSI'       }
  @{ mfr = 'Microsoft Corporation';   fam = 'Surface';     expect = 'Surface'   }
  @{ mfr = 'Framework';               fam = 'Laptop 13';   expect = 'Framework' }
  @{ mfr = 'Acer';                    fam = 'Swift';       expect = 'Acer'      }
)
foreach ($c in $cases) {
  $got = Get-SystemVendor -Manufacturer $c.mfr -Family $c.fam -BiosVendor ''
  Check "  '$($c.mfr)' -> $($c.expect)" ($got -and $got.name -eq $c.expect) "got '$($got.name)'"
}
# An OEM with no profile must return $null so the caller can SAY it cannot enforce, rather than
# applying an empty pattern and reporting success.
$unknown = Get-SystemVendor -Manufacturer 'Some Whitebox Ltd' -Family '' -BiosVendor 'American Megatrends'
Check 'an unprofiled OEM returns $null (so the caller can report it)' ($null -eq $unknown)
Check 'and so does a machine that reports nothing at all' ($null -eq (Get-SystemVendor -Manufacturer '' -Family '' -BiosVendor ''))
Check 'every profile has all four fields populated' `
      (@($script:SunUpVendorProfiles | Where-Object { -not ($_.name -and $_.match -and $_.wuTitle -and $_.winget) }).Count -eq 0)

# THE FALSE POSITIVE THAT MATTERS. These patterns are -matched against winget ids/names and WU
# titles, so an UNANCHORED brand word matches anything containing it, and the update is silently
# classified as OEM junk and skipped. Two that were live before review caught them:
#   winget  'HP\.'      matched  PHP.PHP.8.4                  -> PHP skipped on any HP
#   wuTitle 'Framework' matched  ".NET Framework 4.8 update"  -> .NET skipped on a Framework
$hp = Get-SystemVendor -Manufacturer 'HP' -Family 'EliteBook' -BiosVendor ''
Check 'PHP is NOT mistaken for an HP utility' (-not ('PHP.PHP.8.4' -match $hp.winget)) "pattern '$($hp.winget)'"
Check 'nor is PHP Group by name'             (-not ('PHP Group' -match $hp.winget))
Check 'but real HP packages still match'     (('HP.SupportAssistant' -match $hp.winget) -and ('HP Support Assistant' -match $hp.winget))
Check 'and real HP firmware titles still match' ('HP Inc. - Firmware - 1.2.3' -match $hp.wuTitle)
$fw = Get-SystemVendor -Manufacturer 'Framework' -Family 'Laptop 13' -BiosVendor ''
Check '.NET Framework updates are NOT mistaken for OEM updates' `
      ((-not ('Microsoft .NET Framework 4.8 update' -match $fw.wuTitle)) -and (-not ('Microsoft.DotNet.Framework.DeveloperPack' -match $fw.winget))) "pattern '$($fw.wuTitle)'"
Check 'but real Framework updates still match' ('Framework Computer Inc. - Firmware' -match $fw.wuTitle)
# The general rule, enforced on every row rather than the two we happened to notice.
$unanchored = @($script:SunUpVendorProfiles | Where-Object {
  @(@($_.wuTitle -split '\|') + @($_.winget -split '\|') | Where-Object { $_ -notmatch '^\^' }).Count -gt 0
})
Check 'EVERY pattern alternative is anchored at the start' ($unanchored.Count -eq 0) (($unanchored | ForEach-Object name) -join ',')
# A vendor's own name must of course still match its own packages, for every profile.
$selfMatch = @($script:SunUpVendorProfiles | Where-Object { -not ("$($_.name) Something" -match $_.winget -or "$($_.name).Package" -match $_.winget) })
Check 'and every vendor still matches its own packages' ($selfMatch.Count -eq 0) (($selfMatch | ForEach-Object name) -join ',')

# One CIM query failing must not discard what the other returned: losing 'Dell Inc.' because
# Win32_BIOS hiccuped would fail OPEN, enforcing nothing on a machine whose vendor was never in doubt.
Check 'the CIM queries are independent, not one shared catch' `
      ((Get-Content (Join-Path $repoRoot 'VendorProfiles.ps1') -Raw) -match '(?s)Win32_ComputerSystem -ErrorAction Stop.{0,220}\} catch \{ \}.{0,200}Win32_BIOS -ErrorAction Stop')
Check 'a machine with only a manufacturer is still identified' `
      ((Get-SystemVendor -Manufacturer 'Dell Inc.' -Family '' -BiosVendor '').name -eq 'Dell')
Check 'and one with only a BIOS vendor is too' `
      ((Get-SystemVendor -Manufacturer '' -Family '' -BiosVendor 'LENOVO').name -eq 'Lenovo')
# Every `match` must be a valid regex - a bad one would throw mid-run inside the -match below.
$badRx = @($script:SunUpVendorProfiles | Where-Object { try { [void]('x' -match $_.match); $false } catch { $true } })
Check 'every profile pattern is a valid regex' ($badRx.Count -eq 0) (($badRx | ForEach-Object name) -join ',')

# The policy resolves to something reportable, and is wired into BOTH delivering paths.
$rvFn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-VendorPolicy' }, $true)
Check 'Resolve-VendorPolicy found in source' ($null -ne $rvFn)
if ($rvFn) {
  Invoke-Expression $rvFn.Extent.Text
  $allow = Resolve-VendorPolicy ([pscustomobject]@{ vendorUpdates = 'allow' })
  Check 'allow blocks nothing and says nothing' ((-not $allow.block) -and -not $allow.note)
  $block = Resolve-VendorPolicy ([pscustomobject]@{ vendorUpdates = 'block' })
  Check 'block on this box resolves to Dell' ($block.block -and $block.vendor.name -eq 'Dell') $block.note
  Check 'and explains itself in one line' ($block.note -match 'Windows Update' -and $block.note -match 'winget')
}
$jeFn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Join-ExcludePattern' }, $true)
if ($jeFn) {
  Invoke-Expression $jeFn.Extent.Text
  Check 'patterns merge into one alternation' ((Join-ExcludePattern 'NVIDIA' 'Dell\.') -eq 'NVIDIA|Dell\.')
  Check 'an empty vendor pattern leaves the configured one alone' ((Join-ExcludePattern 'NVIDIA' '') -eq 'NVIDIA')
  Check 'an empty configured pattern still applies the vendor one' ((Join-ExcludePattern '' 'Dell\.') -eq 'Dell\.')
  Check 'both empty yields nothing to exclude' ((Join-ExcludePattern '' '') -eq '')
}
Check 'the policy filters Windows Update titles' ($engineText2 -match '\$notTitle = Join-ExcludePattern')
Check 'and winget ids'                          ($engineText2 -match '\$excl = Join-ExcludePattern')
Check 'and the user-scope pass honours it too'  ($userText -match "vendorUpdates.*-eq 'block'" -and $userText -match 'Get-SystemVendor')
Check 'a block that cannot be enforced is a WARN, not silence' ($engineText2 -match 'Write-Log WARN  "vendor: ')

Write-Host "`n[9] uninstall really stops what it unregisters"
# Unregister-ScheduledTask does not terminate a running instance, and the detached helpers are not
# task instances at all: the kill loop matched only SunUp-Tray.ps1 under pwsh.exe, so SelfHost.ps1
# (Windows PowerShell 5.1) went on upgrading PowerShell 7 minutes after the admin was told SunUp was
# removed, and UserScope.ps1 kept upgrading against a config dir that no longer existed.
$uninstText = Get-Content (Join-Path $repoRoot 'Uninstall.ps1') -Raw
Check 'uninstall stops the detached helpers too' ($uninstText -match 'SelfHost\.ps1' -and $uninstText -match 'UserScope\.ps1')
# ...but only the INSTALLED ones. A bare '*\SelfHost.ps1*' also matches an unrelated C:\tools copy,
# or a developer running another checkout of this repo, and the uninstall runs elevated.
Check 'and only processes running the INSTALLED copies are killed' `
      ($uninstText -match '\$Bin = "C:\\ProgramData\\\$Name\\bin"' -and $uninstText -match 'ForEach-Object \{ Join-Path \$Bin \$_ \}' -and $uninstText -notmatch '-like "\*\\\\\$_\*"')
Check 'and looks at Windows PowerShell 5.1, where SelfHost runs' ($uninstText -match "Name='powershell\.exe'")

# --- v0.17.1: a process that MENTIONS one of our scripts is not one of our processes ---
$installText = Get-Content (Join-Path $repoRoot 'Install.ps1') -Raw
# Install.ps1 killed on `-like '*SunUp-Tray.ps1*'`, i.e. the bare filename anywhere in the command
# line. On 2026-08-12 that force-killed the shell that was verifying the deploy -- which was
# Install.ps1's own caller, so the install died with it at exit 255, after registering every task
# but before restarting the tray. Both scripts now anchor on the deployed path AFTER -File.
Check 'the installer never kills on a bare filename match' `
      ((Get-CodeOnly $installText) -notmatch "-like '\*SunUp-Tray\.ps1\*'")
foreach ($f in @{ n='Install.ps1'; t=$installText }, @{ n='Uninstall.ps1'; t=$uninstText }) {
  Check "  $($f.n) anchors the kill filter on -File <deployed path>" ($f.t -match '-like "\*-File `"\$\w+`"\*"')
  Check "  $($f.n) never kills the process doing the killing"        ($f.t -match '\$_\.ProcessId -ne \$PID')
}
# Behavioural: exercise the pattern itself against realistic command lines. The regex guards above
# prove the SHAPE changed; this proves the shape is CORRECT.
$trayPath = 'C:\ProgramData\SunUp\bin\SunUp-Tray.ps1'
$isOurs = { param($cl) ($cl -like "*-File `"$trayPath`"*") -or ($cl -like "*-File $trayPath*") }
$realTray   = '"C:\Program Files\PowerShell\7\pwsh.exe" -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $trayPath + '"'
$unquoted   = 'pwsh.exe -NoProfile -File ' + $trayPath
$innocentFull = 'pwsh -NoProfile -Command "Get-FileHash ' + $trayPath + '"'
$innocentName = 'pwsh -NoProfile -Command "$names = @(''SunUp.ps1'',''SunUp-Tray.ps1'')"'
Check '  the real tray process still matches (quoted -File)'   (& $isOurs $realTray)
Check '  and unquoted -File matches too'                       (& $isOurs $unquoted)
Check '  a shell merely hashing that path does NOT match'      (-not (& $isOurs $innocentFull)) 'this is the shell that got killed'
Check '  nor does one that only names the file'                (-not (& $isOurs $innocentName))
Check 'and stops running task instances before unregistering them' ($uninstText -match 'Stop-ScheduledTask')
# Removal errors are suppressed, so "Purged …" was printed even when a path survived an open handle.
Check 'purge reports only what it actually removed' ($uninstText -match 'Could NOT remove' -and $uninstText -match 'Where-Object \{ -not \(Test-Path \$_\) \}')
# v0.13.x staged Dell reports in C:\SunUp; that integration is gone, but an UPGRADED install still
# has the directory, so the cleanup stays. It may also pre-date SunUp and hold unrelated data, so
# only the 'dcu' child was ever ours and the parent goes only when left empty.
Check 'purge still cleans up the legacy staging dir' `
      ($uninstText -match "Join-Path \`$legacyStage 'dcu'" -and $uninstText -notmatch 'Remove-Item .\$env:SystemDrive.\$Name. -Recurse')
Check 'and removes its parent only when it is empty' `
      ($uninstText -match '(?s)Get-ChildItem \$legacyStage -Force.{0,240}Remove-Item \$legacyStage -Force')
# The report is built from the tracked list, so a removal missing from it cannot be reported as
# failed - the parent would silently read as purged while it was still sitting there.
Check 'every attempted removal is tracked, so a failure cannot read as success' `
      ($uninstText -match '\$attempted\.Add\(\$legacyStage\)' -and $uninstText -match '\$left = @\(\$attempted' -and $uninstText -match '\$gone = @\(\$attempted')

Write-Host "`n[11] reboot state (v0.16.0)"
# PendingFileRenameOperations is a work queue for smss.exe, not a reboot signal. Treating any entry
# in it as one is what pinned rebootPending=true on this box continuously from 2026-08-04: Claude
# Code queues a delete-on-boot for a temp file it unpacks minutes into every startup.
. (Join-Path $repoRoot 'RebootState.ps1')
Check 'RebootState.ps1 exposes the shared entry points' `
      ((Get-Command Get-RebootState -ErrorAction SilentlyContinue) -and (Get-Command Test-PfroEntrySignificant -ErrorAction SilentlyContinue))

# --- pair parsing -------------------------------------------------------------
$pairs = ConvertFrom-PfroValue @('*1\??\C:\Users\b\AppData\Local\Temp\.abc-0.node', '',
                                 '\??\C:\Windows\WinSxS\Temp\a.dll', '!\??\C:\Windows\System32\a.dll')
Check 'a REG_MULTI_SZ value parses into source/destination pairs' ($pairs.Count -eq 2) "got $($pairs.Count)"
Check 'the \??\ prefix and the * / ! markers are stripped from both halves' `
      ($pairs[0].Source -eq 'C:\Users\b\AppData\Local\Temp\.abc-0.node' -and $pairs[1].Destination -eq 'C:\Windows\System32\a.dll') `
      "$($pairs[0].Source) / $($pairs[1].Destination)"
# An odd-length value is a source with no destination element at all; smss.exe deletes it. The
# parser must still yield it -- it is dismissed as a delete downstream, but it has to be COUNTED
# and classified in the advisory line, and a silently dropped tail would be missing from both.
$odd = ConvertFrom-PfroValue @('\??\C:\Windows\Temp\x.tmp')
Check 'an odd-length value yields a delete, not a dropped entry' ($odd.Count -eq 1 -and $odd[0].Destination -eq '')

# --- classification -----------------------------------------------------------
# v0.19.1: the rule is the MECHANISM, not the path. An empty destination is
# MoveFileEx(path, NULL, DELAY_UNTIL_REBOOT) -- "unlink this at boot, it is locked now" -- which
# reports an open handle, never a half-configured system. v0.16.0 dismissed those only under a temp
# directory, and on 2026-08-17 that let 78 C:\Config.Msi\*.rbf MSI rollback backups fire the
# stale-reboot watchdog on a box with nothing outstanding.
Check 'a delete-on-boot under a user temp dir is NOT a reboot signal' `
      (-not (Test-PfroEntrySignificant ([pscustomobject]@{ Source='C:\Users\bradley\AppData\Local\Temp\.78eefce1f7f6b7d6-0.node'; Destination='' })))
Check 'nor is one under C:\Windows\Temp' `
      (-not (Test-PfroEntrySignificant ([pscustomobject]@{ Source='C:\Windows\Temp\tmp1234.tmp'; Destination='' })))
# The entries that fired the SECOND false watchdog alert on this box.
Check 'nor is an MSI rollback backup in C:\Config.Msi (2026-08-17 false positive)' `
      (-not (Test-PfroEntrySignificant ([pscustomobject]@{ Source='C:\Config.Msi\f343d4e.rbf'; Destination='' })))
Check 'nor is a superseded updater directory outside any temp path' `
      (-not (Test-PfroEntrySignificant ([pscustomobject]@{ Source='C:\Program Files (x86)\Microsoft\EdgeUpdate\1.3.251.23'; Destination='' })))
Check 'nor is a delete of a locked binary under Program Files' `
      (-not (Test-PfroEntrySignificant ([pscustomobject]@{ Source='C:\Program Files\Vendor\driver.sys'; Destination='' })))
# ...and the signal that must still count. A rename is a file being PUT IN PLACE, which is the only
# shape in this value that a restart is required to complete.
Check 'a rename INTO a destination is a reboot signal' `
      (Test-PfroEntrySignificant ([pscustomobject]@{ Source='C:\Windows\WinSxS\Temp\a.dll'; Destination='C:\Windows\System32\a.dll' }))
Check 'a rename is significant regardless of where the source sits' `
      (Test-PfroEntrySignificant ([pscustomobject]@{ Source='not-a-path'; Destination='C:\Windows\System32\a.dll' }))
# The narrowing is safe ONLY because the authoritative servicing keys are read directly and do not
# depend on PFRO at all. If that ever stops being true, this test fails before the false negative
# reaches a user.
Check 'the servicing keys that make dismissing deletes safe are still read directly' `
      ((@($script:SunUpRebootKeys | ForEach-Object { $_.key }) -join ',') -eq 'cbs,cbsInProgress,cbsPackages,windowsUpdate,wuPostReboot') `
      "$(@($script:SunUpRebootKeys | ForEach-Object { $_.key }) -join ',')"

# --- dismissed entries stay auditable ----------------------------------------
# Narrowing the verdict is only defensible because nothing is silently dropped: a misclassification
# has to be visible in result.json and Status output, which means classified and counted, not a
# bare number under a label ("under a temp directory") that stopped being true.
Check 'a dismissed delete is classified for the audit line' `
      ((Get-PfroCleanupClass 'C:\Config.Msi\f343d4e.rbf') -eq 'MSI rollback backups') `
      (Get-PfroCleanupClass 'C:\Config.Msi\f343d4e.rbf')
Check 'a temp delete still reads as temp' `
      ((Get-PfroCleanupClass 'C:\Users\b\AppData\Local\Temp\x.node') -eq 'temp files')
# The engine runs as SYSTEM, whose TEMP is C:\Windows\TEMP. Classifying against $env:TEMP would
# mislabel every entry left by an interactive user -- the v0.16.0 lesson, still asserted here even
# though only the audit line depends on it now.
Check 'a temp path is recognised for ANY user, not just the one we run as' `
      ((Get-PfroCleanupClass 'D:\Users\someone.else\AppData\Local\Temp\x.node') -eq 'temp files')
Check 'an unrecognised path gets a true, vague class rather than a wrong one' `
      ((Get-PfroCleanupClass 'C:\Program Files\Vendor\driver.sys') -eq 'other locked files')

# --- the verdict --------------------------------------------------------------
$st = Get-RebootState -RunRequired $true
Check 'a run-signal reboot is Required even with no OS flag set' ($st.Required -and ($st.Sources -contains 'run'))
Check 'the verdict carries reasons and labels, not just a boolean' ($st.Reasons.Count -gt 0 -and $st.Labels.Count -gt 0)
$live = Get-RebootState
Check 'Get-RebootState returns a well-formed verdict for the live machine' `
      (($live.PSObject.Properties.Name -contains 'Required') -and ($live.Sources -is [array]) -and ($live.Advisory -is [array]))

# --- exactly one implementation ------------------------------------------------
# The point of the refactor. Two copies of the detector is how the engine and the tray came to be
# wrong in the same way, independently, and stayed that way.
$trayText    = Get-Content (Join-Path $repoRoot 'SunUp-Tray.ps1') -Raw
$engineText3 = Get-Content $src -Raw
Check 'neither the engine nor the tray defines its own pending-reboot test' `
      (($engineText3 -notmatch 'function Test-PendingReboot') -and ($trayText -notmatch 'function Test-PendingReboot'))
Check 'both dot-source the shared RebootState.ps1' `
      (($engineText3 -match "Join-Path .*'RebootState\.ps1'") -and ($trayText -match "Join-Path .*'RebootState\.ps1'"))
Check 'Install.ps1 deploys it alongside them' `
      ((Get-Content (Join-Path $repoRoot 'Install.ps1') -Raw) -match "Copy-Item .*'RebootState\.ps1'")

# --- the watchdog ratchet -------------------------------------------------------
# pendingSince used to reset only on observing the state clear. Against a signal that re-arms itself
# minutes into every boot no run ever sees it clear, so the tracker ratcheted backwards forever --
# alerting on 2026-08-11 about a reboot "pending since 08-04" across two intervening restarts.
Check 'the stale-reboot tracker resets when the box has booted since the last run' `
      ($engineText3 -match '\$carryTracker\s*=\s*\[bool\]\(\$stamp -and \$stamp\.pendingSince -and -not \$bootedSinceLastRun\)')
Check 'and the once-only alert latch resets with it' `
      ($engineText3 -match '\$pendingAlerted = \[bool\]\(\$carryTracker -and \$stamp\.pendingAlerted\)')
# The watchdog alert is the only sentence most people will ever read about a pending restart, so
# v0.19.1 rewrote all three of its clauses. Assert the PROPERTIES, not the wording -- these are the
# three complaints it was rebuilt to answer.
Check 'the alert names what is asking for the restart' `
      ($engineText3 -match '\$what\s*=\s*if \(\$rebootState\.Labels\.Count\)')
# "3.0 days" spelled a tenth of precision onto a value that is a guess about when a signal became
# observable. Whole days, and hours below one so a fractional pendingRebootAlertDays cannot render
# every alert as "0 days".
Check 'the age is whole days, never a decimal' `
      (($engineText3 -notmatch 'pending \{0:N1\} days') -and ($engineText3 -match '\[math\]::Floor\(\$ageDays\)'))
Check 'and reads as hours below a day, so it is never "0 days"' `
      ($engineText3 -match '\$ageDays -lt 1\s*\)\s*\{\s*"\{0:N0\} hours"')
# A config KEY in a desktop toast names a setting without stating its consequence, and the
# consequence -- nobody but the reader is going to restart this box -- is the only actionable part.
# Derived from what happened this run, because a blocker deferral reaches this path under ANY policy.
$policyLeaks = @($engineText3 -split "`n" | Where-Object { $_ -match 'Raise-Alert' -and $_ -match 'rebootPolicy=' })
Check 'no rebootPolicy= config key is pasted into a user-facing alert' `
      ($policyLeaks.Count -eq 0) "$($policyLeaks.Count) alert(s) still quote the policy key"
Check 'the alert says who is NOT going to restart the box, blocker case included' `
      ($engineText3 -match '\$who\s*=\s*if \(\$rebootDeferredByBlocker\)' -and
       $engineText3 -match 'restarts only for updates it installs itself')
Check 'the run records which signals fired, for audit' `
      ($engineText3 -match 'rebootSources\s*=\s*@\(\$rebootState\.Sources\)' -and $engineText3 -match 'rebootIgnored\s*=\s*@\(\$rebootState\.Advisory\)')

# --- the tray -------------------------------------------------------------------
Check 'the tray has a distinct sunset icon, not a second shade of the sun' `
      ($trayText -match 'function New-SunsetIcon' -and $trayText -match '\$script:iconSunset = New-SunsetIcon')
Check 'the sunset icon is what shows when a restart is needed' `
      ($trayText -match 'if \(\$rb\.Required\) \{ \$script:iconSunset \} else \{ \$script:iconNormal \}')
Check 'the tray also counts reboots SunUp itself caused (those set no OS flag)' `
      ($trayText -match '(?s)function Get-TrayRebootState.{0,600}\$p\.rebootRequired.{0,240}handoffRebootPending')

# The icons must actually DRAW. A bad GDI+ argument here throws at logon, inside a tray process with
# nowhere to report it -- the icon simply never appears, which is indistinguishable from "not running".
$trayAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'SunUp-Tray.ps1'), [ref]$null, [ref]$null)
foreach ($fnName in 'ConvertTo-TrayIcon','New-SunIcon','New-SunsetIcon') {
  $fnAst = $trayAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }.GetNewClosure(), $true)
  Check "$fnName is defined in the tray" ($null -ne $fnAst)
  if ($fnAst) { . ([scriptblock]::Create($fnAst.Extent.Text)) }
}
try {
  Add-Type -AssemblyName System.Drawing
  $i1 = New-SunIcon; $i2 = New-SunsetIcon
  Check 'both icons render without a GDI+ error' ($i1.Width -gt 0 -and $i2.Width -gt 0)
  $b1 = $i1.ToBitmap(); $b2 = $i2.ToBitmap()
  # Same canvas, different pixels -- catches a "sunset" that silently drew as a plain sun.
  $diff = 0
  for ($y = 0; $y -lt 32; $y += 2) { for ($x = 0; $x -lt 32; $x += 2) {
    if ($b1.GetPixel($x, $y).ToArgb() -ne $b2.GetPixel($x, $y).ToArgb()) { $diff++ } } }
  Check 'the sunset icon is visibly different from the sun' ($diff -gt 40) "differing sampled pixels: $diff"
  # A setting sun is EMPTY where a full sun has its top ray: the shapes differ, not just the palette.
  Check 'the sunset draws nothing where the sun has its top ray' `
        (($b2.GetPixel(16, 2).A -eq 0) -and ($b1.GetPixel(16, 4).A -gt 0)) `
        "sunset alpha $($b2.GetPixel(16,2).A), sun alpha $($b1.GetPixel(16,4).A)"
  $b1.Dispose(); $b2.Dispose()
} catch { Check 'both icons render without a GDI+ error' $false $_.Exception.Message }

Write-Host "`n[12] the restart loop (v0.17.0)"
# On 2026-08-12 this box restarted three times in seventy minutes -- 08:09:53, 09:03:18, 09:09:45 --
# because Show-UpdateDialog.ps1 could not tell that it had already restarted. Everything in this
# section is that incident, decomposed into things that can fail independently.
$dlgSrc  = Join-Path $repoRoot 'Show-UpdateDialog.ps1'
$dlgText = Get-Content $dlgSrc -Raw
$dlgAst  = [System.Management.Automation.Language.Parser]::ParseFile($dlgSrc, [ref]$null, [ref]$null)
$dlgCode = Get-CodeOnly $dlgText

# --- the bug itself, as a unit test ------------------------------------------
$data = '{"runEndUtc":"2026-08-12T15:04:43.8905354Z"}' | ConvertFrom-Json
Check 'ConvertFrom-Json hands a consumer a [datetime], not the string it wrote' ($data.runEndUtc -is [datetime])
$truth = [datetime]::Parse('2026-08-12T15:04:43.8905354Z', $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
Check 'ConvertTo-UtcTime reads the deserialized value exactly (the fix)' ((ConvertTo-UtcTime $data.runEndUtc) -eq $truth)
# Only meaningful away from UTC; asserted conditionally so the suite stays timezone-portable.
if ([TimeZoneInfo]::Local.BaseUtcOffset -ne [TimeSpan]::Zero) {
  $bug = [datetime]::Parse($data.runEndUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
  Check 'and the old dialog parse really did land in the future' ($bug -gt $truth) "off by $(($bug - $truth).TotalHours)h"
}
# THE WRITER CONTRACT, which is the layer that protects a consumer that forgot the guard entirely.
$ts = Get-SunUpTimestamp
Check 'the canonical writer emits local-with-offset, never Z' `
      ($ts -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+[+-]\d{2}:\d{2}$') "got '$ts'"
Check 'and still does when handed a UTC DateTime' ((Get-SunUpTimestamp ([datetime]::UtcNow)) -notmatch 'Z$')
$viaBug = [datetime]::Parse((("{`"a`":`"$ts`"}" | ConvertFrom-Json).a), $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
Check 'local-with-offset survives EVEN the buggy reparse (why the format matters)' `
      (($viaBug - (ConvertTo-UtcTime $ts)).Duration().TotalSeconds -lt 1)
# A corrupted cursor already on disk self-heals rather than eating a week of helper records.
Check 'a timestamp in the future is clamped, not trusted' `
      ((ConvertTo-UtcTime ((Get-Date).ToUniversalTime().AddHours(7))) -le (Get-Date).ToUniversalTime().AddMinutes(1))

# --- Test-BootedSince, which no test had ever called -------------------------
$bootU = Get-BootUtc
foreach ($shape in @(@{n='raw [datetime]'; f={param($d) $d}},
                     @{n='local-offset';   f={param($d) Get-SunUpTimestamp $d}},
                     @{n='epoch';          f={param($d) Get-SunUpEpoch $d}})) {
  Check "  an instant before the boot reads as booted-since ($($shape.n))" (Test-BootedSince (& $shape.f $bootU.AddMinutes(-10)))
  Check "  an instant after it does not ($($shape.n))"                     (-not (Test-BootedSince (& $shape.f $bootU.AddMinutes(10))))
}
Check 'null and empty never read as booted-since' ((-not (Test-BootedSince $null)) -and (-not (Test-BootedSince '')))

# --- boot identity: the comparison that needs no clock -----------------------
$be = Get-BootEpoch
Check 'the boot epoch is stable across queries' ($be -eq (Get-BootEpoch))
Check 'the same boot reads as the same boot' (Test-SameBoot $be $be)
Check 'a second of clock drift is still the same boot' (Test-SameBoot $be ($be + 1))
Check 'a genuinely different boot is detected' (-not (Test-SameBoot $be ($be + 5000)))
Check 'an unknown recorded boot reads as "not restarted yet", never as done' (Test-SameBoot $null $be)

# --- one implementation, every consumer --------------------------------------
$consumers = [ordered]@{ 'SunUp.ps1' = $engineText3; 'SunUp-Tray.ps1' = $trayText; 'Show-UpdateDialog.ps1' = $dlgText }
foreach ($k in $consumers.Keys) {
  Check "  $k dot-sources the shared RebootState.ps1" ($consumers[$k] -match "Join-Path \`$PSScriptRoot 'RebootState\.ps1'")
  Check "  $k parses no timestamp of its own outside its degraded fallback" `
        (@([regex]::Matches((Get-CodeOnly $consumers[$k]), '\[datetime\]::Parse\(')).Count -le 1)
}
Check 'RebootState.ps1 is the only place in the product that parses a timestamp' `
      (@([regex]::Matches((Get-CodeOnly $rsText), '\[datetime\]::Parse\(')).Count -eq 1)
# Write-only helpers are exempt from the dependency ON PURPOSE: SelfHost.ps1 runs under 5.1, launched
# by a task, after the engine is dead, and a silent dot-source failure there is the worst place for a
# new runtime dependency. They inline the compliant one-liner instead, and that is asserted here.
foreach ($w in @{n='SelfHost.ps1'; t=$selfText}, @{n='UserScope.ps1'; t=$userText}) {
  Check "  $($w.n) writes local-with-offset inline, without depending on bin\" `
        (((Get-CodeOnly $w.t) -match "\(Get-Date\)\.ToString\('o'\)") -and ((Get-CodeOnly $w.t) -notmatch "ToUniversalTime\(\)\.ToString\('o'\)"))
}
Check 'no shipped script writes a UTC round-trip string into a persisted field' `
      (@(($consumers.Values + $selfText + $userText) | Where-Object { (Get-CodeOnly $_) -match "ToUniversalTime\(\)\.ToString\('o'\)" }).Count -eq 0)

# --- RebootState.ps1 must load under 5.1 (the toast host dot-sources it) -----
$rsNonAscii = @($rsText.ToCharArray() | Where-Object { [int]$_ -gt 127 })
Check 'RebootState.ps1 is pure ASCII' ($rsNonAscii.Count -eq 0) "$($rsNonAscii.Count) non-ASCII char(s)"
$rsParse51 = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "
  `$e = `$null
  [void][System.Management.Automation.Language.Parser]::ParseFile('$rebootStatePath', [ref]`$null, [ref]`$e)
  if (`$e) { 'FAIL: ' + (`$e[0].Message) } else { 'OK' }"
Check 'RebootState.ps1 parses under Windows PowerShell 5.1' ("$rsParse51" -eq 'OK') "$rsParse51"

# --- the plain-language consequence table ------------------------------------
$cons = Get-RebootConsequence -Sources @('windowsUpdate','run')
Check 'a consequence is produced for the signals that fired' (@($cons).Count -eq 2)
Check 'and it is plain language -- no CVE, KB or servicing jargon' `
      (($cons -join ' ') -notmatch '(?i)CVE-|\bKB\d|servicing stack|mitigation')
Check 'an unknown signal still gets an honest sentence, never a blank' `
      (@(Get-RebootConsequence -Sources @('somethingNew')).Count -eq 1)
Check 'and no signals at all produces nothing to say' (@(Get-RebootConsequence -Sources @()).Count -eq 0)

# --- the record gates re-arming ----------------------------------------------
# Lifted from RebootState.ps1, NOT from the dialog: the toast host runs under 5.1 and needs the
# identical answer, so the decision lives in the one file both dot-source. A copy in each is exactly
# the shape of the bug that caused the incident.
foreach ($fnName in 'Get-RestartRecord','Save-RestartRecord','New-RestartRecord','Get-RestartDisplayState','Format-LocalStamp') {
  $fnAst = $rsAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }.GetNewClosure(), $true)
  Check "$fnName is shared in RebootState.ps1, not private to a UI script" ($null -ne $fnAst)
}
# The dialog is allowed exactly one Get-RestartDisplayState: the degraded stub used when bin\ has no
# RebootState.ps1. What it must NOT contain is a second real implementation -- so the stub is
# required to be incapable of arming anything. A fallback nobody exercises is the likeliest copy of
# all to drift, and a drifted copy of THIS function is the incident.
$dlgFallback = $dlgAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RestartDisplayState' }, $true)
Check 'the dialog keeps no second real copy of the restart decision' `
      (($null -eq $dlgFallback) -or ($dlgFallback.Extent.Text -notmatch "'countdown'"))
Check 'and without the shared file it decides nothing rather than guessing' `
      (($null -ne $dlgFallback) -and ($dlgFallback.Extent.Text -match "Mode = 'none'"))
$BOOT = 1000
$payAt  = [pscustomobject]@{ rebootRequired = $true; runStamp = 'R1'; rebootCountdownSec = 300 }
$issued = [pscustomobject]@{ runStamp = 'R1'; outcome = 'issued'; trigger = 'countdown-expired'
                             executedLocal = (Get-SunUpTimestamp (Get-Date).AddMinutes(-5)); bootAtRequestEpoch = ($BOOT - 5000) }
$same   = [pscustomobject]@{ runStamp = 'R1'; outcome = 'issued'; trigger = 'countdown-expired'
                             executedLocal = (Get-SunUpTimestamp (Get-Date).AddMinutes(-5)); bootAtRequestEpoch = $BOOT }
Check 'a fresh run with no record arms the countdown' `
      ((Get-RestartDisplayState -Data $payAt -Record $null -BootEpoch $BOOT).Mode -eq 'countdown')
Check 'a restart that was issued and came back reads as post-reboot' `
      ((Get-RestartDisplayState -Data $payAt -Record $issued -BootEpoch $BOOT).Mode -eq 'postReboot')
# THE INCIDENT: the record must win over the timestamp, however wrong the timestamp is.
$future = [pscustomobject]@{ rebootRequired = $true; runStamp = 'R1'; rebootCountdownSec = 300
                             runEnd = (Get-SunUpTimestamp (Get-Date).AddHours(7)) }
Check 'and a runEnd seven hours in the future CANNOT re-arm it (2026-08-12)' `
      ((Get-RestartDisplayState -Data $future -Record $issued -BootEpoch $BOOT).Mode -eq 'postReboot')
Check 'an issued restart on an UNCHANGED boot is awaitingRestart, never a second countdown' `
      ((Get-RestartDisplayState -Data $payAt -Record $same -BootEpoch $BOOT).Mode -eq 'awaitingRestart')
# Anti-over-fitting: a "fix" that simply never re-arms must fail here.
$run2 = [pscustomobject]@{ rebootRequired = $true; runStamp = 'R2'; rebootCountdownSec = 300 }
Check 'but a genuinely NEW run still arms one' `
      ((Get-RestartDisplayState -Data $run2 -Record $issued -BootEpoch $BOOT).Mode -eq 'countdown')
Check 'no restart required means nothing to show' `
      ((Get-RestartDisplayState -Data ([pscustomobject]@{ rebootRequired = $false; runStamp = 'R1' }) -Record $null -BootEpoch $BOOT).Mode -eq 'none')
# MIGRATION: a payload from <=v0.16.0 has no runStamp, so no record can be tied to it and nothing can
# prove a restart was not already issued. Showing a stale summary costs a day's nag; arming a
# countdown on an unprovable payload is the incident itself.
$old = [pscustomobject]@{ rebootRequired = $true; runEndUtc = '2026-08-12T15:04:43.8905354Z' }
Check 'a v0.16.0 payload with no runStamp can NEVER arm a countdown' `
      ((Get-RestartDisplayState -Data $old -Record $null -BootEpoch $BOOT).Mode -ne 'countdown')
Check 'and it still reports the restart once a boot has been observed' `
      ((Get-RestartDisplayState -Data $old -Record $null -BootEpoch $BOOT -BootedSinceRun $true).Mode -eq 'postReboot')
# The timing display the summary is built from.
$post = Get-RestartDisplayState -Data $payAt -Record $issued -BootEpoch $BOOT -BootLocal (Get-Date)
Check 'the post-reboot state carries when the restart executed' ($null -ne $post.ExecutedLocal)
Check 'and when the box came back, and how long it was down' `
      (($null -ne $post.BootedLocal) -and ($post.DowntimeSec -ge 290 -and $post.DowntimeSec -le 310)) "downtime=$($post.DowntimeSec)"

# --- record first, restart second --------------------------------------------
Check 'the dialog refuses to restart if it cannot record the restart' `
      ($dlgText -match '(?s)if \(-not \(Save-RestartRecord.{0,400}return' )
Check 'and the engine does the same on the headless path' `
      ($engineText3 -match '(?s)if \(Publish-JsonFile \$issued \$NotifyRestart\).{0,200}shutdown\.exe /r')
Check 'the engine arms a record naming the run, so a stale one cannot be mistaken for it' `
      ($engineText3 -match "runStamp\s*=\s*\`$runStamp" -and $engineText3 -match "outcome\s*=\s*'armed'")
Check 'the payload carries the runStamp the record is matched on' ($engineText3 -match 'runStamp\s+=\s+\$runStamp\s+#')
Check 'and the reasons a person can actually read' `
      ($engineText3 -match 'whyPlain\s+=\s+@\(Get-RebootConsequence' -and $engineText3 -match 'rebootReasons\s+=\s+@\(\$rebootState\.Reasons\)')
Check 'the payload is published atomically, not Set-Content into place' `
      ($engineText3 -match 'Publish-JsonFile \$payload \$NotifyPayload' -and $dlgCode -notmatch 'Set-Content \$script:dataPath')

# --- the pre-flight: do not redo work that is only waiting on a restart ------
# 2026-08-12, from the CBS Setup log: the orchestrator installed KB5120708+KB5121003 at 21:24/21:45
# and left "A reboot is necessary before package KB5121003 can be changed to the Installed state" at
# 21:45:40. Ten hours later this engine was handed the same packages -- "Current state is Installed.
# Target state is Installed" -- reinstalled them, and set rebootRequiredByRun, which under
# ifRequired is the ONLY thing that arms a restart. That is what started the loop.
Check 'servicing signals are recognised as a reason to hold off installing' `
      ((@(Get-ServicingSignals @('cbs','windowsUpdate')).Count -eq 2))
Check 'a queued temp-file deletion is NOT one -- it must never suppress the update pass' `
      (@(Get-ServicingSignals @('pendingRename')).Count -eq 0)
Check 'nor is this run''s own signal, which describes work we just did' `
      (@(Get-ServicingSignals @('run','handoff')).Count -eq 0)
Check 'and a mixed state reports only the servicing half' `
      ((@(Get-ServicingSignals @('pendingRename','cbsPackages','run')) -join ',') -eq 'cbsPackages')
Check 'empty and null are safe' ((@(Get-ServicingSignals @()).Count -eq 0) -and (@(Get-ServicingSignals $null).Count -eq 0))
# The whole point is WHEN it is asked. Asked after the components run -- as Get-RebootState always
# was -- it can only decide whether to restart, never whether the work was necessary.
$preAt  = $engineText3.IndexOf('$preRebootState = Get-RebootState')
$runAt  = $engineText3.IndexOf('$results = [System.Collections.Generic.List[object]]::new()')
Check 'the reboot state is captured BEFORE the components run, not only after' `
      ($preAt -gt 0 -and $runAt -gt $preAt) "pre=$preAt run=$runAt"
Check 'the Windows Update pass is skipped while a servicing restart is pending' `
      ($engineText3 -match 'if \(\$skipWuForPending\)' -and $engineText3 -match "status = 'skip'")
# Otherwise the pass would be suppressed every day forever and new updates would never install.
Check 'but never under rebootPolicy=never, where no restart is ever coming' `
      ($engineText3 -match '\$skipWuForPending = \(\$preServicing\.Count -gt 0\) -and \("\$\(\$cfg\.rebootPolicy\)" -ne .never.\)')
Check 'and the skip still asks for the restart, so it is self-limiting' `
      ($engineText3 -match "(?s)detail = 'restart pending.{0,120}reboot = \`$true")

Write-Host "`n[13] the Restarting Soon toast (v0.17.0)"
$toastSrc = Join-Path $repoRoot 'Show-RestartToast.ps1'
$actSrc   = Join-Path $repoRoot 'Invoke-ToastAction.ps1'
Check 'Show-RestartToast.ps1 exists'  (Test-Path $toastSrc)
Check 'Invoke-ToastAction.ps1 exists' (Test-Path $actSrc)
$toastText = Get-Content $toastSrc -Raw
$actText   = Get-Content $actSrc   -Raw
$toastCode = Get-CodeOnly $toastText
$installText = Get-Content (Join-Path $repoRoot 'Install.ps1') -Raw
$toastAst  = [System.Management.Automation.Language.Parser]::ParseFile($toastSrc, [ref]$null, [ref]$null)
# The <text> elements are a mix: two bare ones (which PowerShell surfaces as plain strings) and one
# carrying placement="attribution" (an XmlElement). Indexing the property would compare a string to
# an element, so go through the nodes and read InnerText.
function Get-ToastTexts { param($Xml) @($Xml.toast.visual.binding.SelectNodes('text') | ForEach-Object { $_.InnerText }) }

# The toast host runs under 5.1 because WinRT has no projection in .NET Core. Same ASCII trap as
# SelfHost.ps1, and the same consequence: a task that dies at parse time, silently.
$alertToastSrc  = Join-Path $repoRoot 'Show-AlertToast.ps1'
$alertToastText = Get-Content $alertToastSrc -Raw
foreach ($f in @{n='Show-RestartToast.ps1'; p=$toastSrc; t=$toastText}, @{n='Invoke-ToastAction.ps1'; p=$actSrc; t=$actText}, @{n='Show-AlertToast.ps1'; p=$alertToastSrc; t=$alertToastText}) {
  $na = @($f.t.ToCharArray() | Where-Object { [int]$_ -gt 127 })
  Check "  $($f.n) is pure ASCII" ($na.Count -eq 0) "$($na.Count) non-ASCII char(s)"
  $r = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "
    `$e = `$null
    [void][System.Management.Automation.Language.Parser]::ParseFile('$($f.p)', [ref]`$null, [ref]`$e)
    if (`$e) { 'FAIL: ' + (`$e[0].Message) } else { 'OK' }"
  Check "  $($f.n) parses under Windows PowerShell 5.1" ("$r" -eq 'OK') "$r"
}
Check 'the toast task runs Windows PowerShell 5.1, never pwsh (WinRT does not exist there)' `
      ($installText -match '(?s)\$rAction\s*=\s*New-ScheduledTaskAction -Execute \$ps51.{0,120}Show-RestartToast\.ps1')
Check 'and the engine hands it the countdown instead of the dialog when it intends to restart' `
      ($engineText3 -match '(?s)if \(\$willReboot\).{0,600}Start-ScheduledTask -TaskName \$RestartTask')

# --- the XML is real XML, and it escapes what it is given ---------------------
foreach ($fnName in 'ConvertTo-XmlText','New-ToastXml','Format-Countdown','Get-RestartSubject','Get-RestartWhy') {
  $fnAst = $toastAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }.GetNewClosure(), $true)
  Check "  $fnName is defined in the toast host" ($null -ne $fnAst)
  if ($fnAst) { . ([scriptblock]::Create($fnAst.Extent.Text)) }
}
$xmlOk = $false; $xmlErr = ''
try { $x = [xml](New-ToastXml -Subject 'KB5121003' -Why 'Because.' -Paused $false); $xmlOk = ($null -ne $x) } catch { $xmlErr = $_.Exception.Message }
Check 'the toast XML is well-formed' $xmlOk $xmlErr
# An update title really can contain an ampersand ("Intel(R) Chipset & Firmware"), and an unescaped
# one makes the whole toast fail to load -- i.e. no restart warning at all.
$hostile = 'Update & <script> "quoted" 2026-08 R&D'
$esc = $null; $escOk = $false
try { $esc = [xml](New-ToastXml -Subject $hostile -Why "Ampersands & angle <brackets>" -Paused $false); $escOk = $true } catch {}
Check 'and survives an update title containing & and < >' $escOk
if ($escOk) {
  Check 'with the text preserved, not mangled' ((Get-ToastTexts $esc) -contains $hostile)
}
$x0 = [xml](New-ToastXml -Subject 's' -Why 'w' -Paused $false)
Check 'the toast is a reminder, so it stays on screen instead of vanishing in 5s' ($x0.toast.scenario -eq 'reminder')
Check 'the countdown is data-bound, so it updates without re-popping the toast' `
      ($x0.toast.visual.binding.progress.value -eq '{tick}' -and $x0.toast.visual.binding.progress.valueStringOverride -eq '{ticklabel}')
$acts = @($x0.toast.actions.action)
Check 'there are exactly two buttons' ($acts.Count -eq 2)
Check 'Restart now comes first, Pause second (the order the user asked for)' `
      ($acts[0].content -eq 'Restart now' -and $acts[1].content -eq 'Pause')
Check 'both activate by protocol -- the only route that works without a COM activator' `
      (@($acts | Where-Object { $_.activationType -eq 'protocol' }).Count -eq 2)
$xP = [xml](New-ToastXml -Subject 's' -Why 'w' -Paused $true)
$actsP = @($xP.toast.actions.action)
Check 'and Pause toggles to Unpause, pointing at the resume action' `
      ($actsP[1].content -eq 'Unpause' -and $actsP[1].arguments -eq 'sunup:resume')
Check 'the header changes with it, so a paused toast does not still say Restarting Soon' `
      ((Get-ToastTexts $xP)[0] -eq 'Restart Paused' -and (Get-ToastTexts $x0)[0] -eq 'Restarting Soon')
Check 'the countdown formats as m:ss' ((Format-Countdown 125) -eq '2:05' -and (Format-Countdown 5) -eq '0:05' -and (Format-Countdown -3) -eq '0:00')

# --- it names the update, and says why in plain words ------------------------
$pay = [pscustomobject]@{
  rebootRequired = $true; runStamp = 'R1'; rebootSources = @('windowsUpdate','run')
  whyPlain = @(Get-RebootConsequence -Sources @('windowsUpdate','run'))
  items = @(
    [pscustomobject]@{ name = 'KB5121003 Security Update'; meta = [pscustomobject]@{ rebootRequired = $true } }
    [pscustomobject]@{ name = 'KB5120708 .NET Update';     meta = [pscustomobject]@{ rebootRequired = $true } }
    [pscustomobject]@{ name = 'Defender signatures' }          # no meta: did NOT ask for a restart
  )
}
$subj = Get-RestartSubject $pay
Check 'the toast names the update that is asking, not just "an update"' ($subj -like 'KB5121003*')
Check 'and counts only the ones that actually asked (Defender did not)' ($subj -like '*1 other update')
Check 'with no payload at all it still says something honest' ((Get-RestartSubject $null) -eq 'A recent update')
$whyText = Get-RestartWhy $pay
Check 'the why-text is plain language, with no CVE or KB jargon' `
      ($whyText -notmatch '(?i)CVE-|\bKB\d|servicing stack|mitigation') "got: $whyText"
Check 'and it fits an attribution line' ($whyText.Length -le 260) "length $($whyText.Length)"
Check 'a payload with no explanation still gets a sentence rather than a blank' `
      ((Get-RestartWhy ([pscustomobject]@{ rebootRequired = $true })).Length -gt 0)

# --- the safety properties ---------------------------------------------------
Check 'ONLY the countdown mode may restart anything' `
      ($toastText -match "if \(\`$restart\.Mode -ne 'countdown'\)")
Check 'the toast records the restart before issuing it, and refuses to restart if it cannot' `
      ($toastText -match '(?s)if \(-not \(Save-RestartRecord.{0,200}return \$false')
Check 'every give-up path hands the countdown back to the dialog' `
      (@([regex]::Matches($toastText, 'Invoke-DialogFallback')).Count -ge 5)
Check 'and the dialog stands down while the toast is counting, so there is never a second countdown' `
      ($dlgText -match "Get-ScheduledTask -TaskName `"\`$Name-Restart`"" -and $dlgText -match '\$toastOwnsCountdown')
Check 'pausing holds indefinitely -- nothing auto-resumes it' `
      ($toastCode -notmatch '(?i)auto-?resume' -and $toastCode -notmatch '(?i)Start-Sleep -Seconds \$?resume' -and $toastText -match 'holding indefinitely')
Check 'the protocol handler allow-lists actions instead of trusting the URI' `
      ($actText -match "\`$known = @\('restart', 'pause', 'resume', 'dismiss', 'show'\)" -and $actText -match '\$known -notcontains \$action')
Check 'and it can never restart anything itself' ($actText -notmatch 'Restart-Computer|shutdown\.exe')
Check 'Install registers the sunup: protocol the buttons need' ($installText -match 'Classes\\sunup')
# bin\ holds the scripts the ELEVATED interactive tasks run, so the grant must be read+execute and
# never write -- a write ACE there is a direct path to code execution with an administrator token.
Check 'and asserts bin is readable, never writable, by BUILTIN\Users' `
      ($installText -match 'icacls \$Bin /grant "\*S-1-5-32-545:\(OI\)\(CI\)RX"' -and
       $installText -notmatch 'icacls \$Bin /grant[^\r\n]*S-1-5-32-545[^\r\n]*(:\(OI\)\(CI\))?(M|F|W)\b')
Check 'and drops a pre-v0.17.0 payload that no record could be proven against' `
      ($installText -match 'schemaVersion' -and $installText -match 'Removed a pre-v0\.17\.0 notify payload')
$uninstText = Get-Content (Join-Path $repoRoot 'Uninstall.ps1') -Raw
Check 'Uninstall removes the restart task, the AUMID and the protocol' `
      ($uninstText -match '\$Name-Restart' -and $uninstText -match 'AppUserModelId' -and $uninstText -match 'Classes\\sunup')

# --- optional Claude enrichment: an enhancement that can never break the warning ---
Check 'enrichment is OFF by default' ($engineText3 -match "explain\s*=\s*'off'")
# A switch that decides whether to execute an external program must live in the admin-owned file,
# never in the payload. notify\ is granted Modify to the interactive user -- the SAME account the
# elevated toast task runs as -- so a policy kept there is settable by the party it constrains. The
# engine briefly did carry it, justified as "the toast runs non-elevated and config.json is
# admin-only"; a security review of this branch established that BOTH halves were false (every
# interactive task is RunLevel Highest, and config.json is world-readable, admin-writable).
Check 'the policy is NOT carried in the user-writable payload' `
      ((Get-CodeOnly $engineText3) -notmatch 'explain\s+=\s+\$\(if \(\$cfg\.notify')
Check 'and the toast reads it from admin-owned config.json instead' `
      ($toastCode -match 'function Get-ExplainMode' -and $toastCode -match 'Get-Content \$ConfigFile')
Check 'the toast only enriches when that policy says auto' `
      ($toastCode -match "if \(\(Get-ExplainMode\) -ne 'auto'\) \{ return \`$Fallback \}")
# Behavioural, not just structural: every way of failing to read the policy must land on OFF, so a
# missing key or a corrupt file can only ever disable the feature, never enable it.
$emFn = $toastAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ExplainMode' }, $true)
Check 'Get-ExplainMode is a liftable function' ($null -ne $emFn)
if ($emFn) {
  function Write-ToastLog { param($Level, $Msg) }          # the lifted function logs on failure
  . ([scriptblock]::Create($emFn.Extent.Text))
  $cfgProbe = Join-Path $RunsDir 'explain-config.json'
  foreach ($case in @(@{ n='auto';           json='{"notify":{"explain":"auto"}}'; want='auto' },
                      @{ n='off';            json='{"notify":{"explain":"off"}}';  want='off'  },
                      @{ n='mixed case';     json='{"notify":{"explain":"AUTO"}}'; want='auto' },
                      @{ n='key absent';     json='{"notify":{}}';                 want='off'  },
                      @{ n='notify absent';  json='{}';                            want='off'  },
                      @{ n='corrupt file';   json='not json at all';               want='off'  })) {
    Set-Content -Path $cfgProbe -Value $case.json -Encoding UTF8
    $ConfigFile = $cfgProbe
    Check "  policy from config.json: $($case.n) -> $($case.want)" ((Get-ExplainMode) -eq $case.want) "got '$(Get-ExplainMode)'"
  }
  Remove-Item $cfgProbe -Force -ErrorAction SilentlyContinue
  $ConfigFile = $cfgProbe        # now missing
  Check '  policy from config.json: file missing -> off' ((Get-ExplainMode) -eq 'off') "got '$(Get-ExplainMode)'"
}
Check 'every enrichment failure returns the deterministic text' `
      (@([regex]::Matches($toastCode, 'return \$Fallback')).Count -ge 2 -and $toastCode -match 'if \(-not \$text\) \{ return \$Fallback \}')
Check 'the call is bounded by a timeout and killed if it overruns' `
      ($toastCode -match 'WaitForExit\(\$TimeoutSec \* 1000\)' -and $toastCode -match '\$p\.Kill\(\)')
Check 'and it is judged on its OUTPUT, not on an exit code that is empty here' `
      ($toastCode -match '\(\$null -ne \$exit\) -and \(\$exit -ne 0\)')
Check 'the answer is sanity-checked before it goes on screen' `
      ($toastCode -match '\$text\.Length -lt 20 -or \$text\.Length -gt 400' -and $toastCode -match "CVE-\\d")
Check 'the prompt forbids the jargon the user asked us to avoid' `
      ($toastText -match 'No CVE numbers, no KB numbers' -and $toastText -match 'plain everyday English')
Check 'results are cached per update set, so each one is researched once ever' `
      ($toastCode -match 'function Get-WhyCacheKey' -and $toastCode -match 'Save-CachedWhy \$key \$text')
Check 'and enrichment happens only once a toast is definitely going up' `
      ($toastCode -match '(?s)if \(\$restart\.Mode -ne .countdown.\).{0,200}\$why = Get-ExplainedWhy')

} catch {
  # Without this, a terminating error inside a Check's CONDITION (an invalid regex, a missing file)
  # unwound straight past the counter to the summary, which then printed ALL TESTS PASSED -- while
  # every remaining check went unrun. A test suite that reports success when it did not finish is
  # worse than one that fails, so an unhandled error is now itself a failure.
  Write-Host "  FAIL  unhandled error: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "        at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
  Write-Host "        REMAINING CHECKS DID NOT RUN" -ForegroundColor Red
  $script:fail++
} finally {
  if (Test-Path $RunsDir) { Remove-Item $RunsDir -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item (Join-Path $PSScriptRoot 'argprobe.ps1') -Force -ErrorAction SilentlyContinue
}
Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green } else { Write-Host "$fail TEST(S) FAILED" -ForegroundColor Red; exit 1 }
