# Tests for the crash-reporting, self-hosting-handoff and Dell-exclusion logic. Safe to run anywhere:
# no live update run, no installs, no reboots, nothing touched outside this folder.
#   1. the engine parses;
#   2. Report-CrashedRuns (lifted from source via AST) flags exactly the dead run dirs, once;
#   3. self-hosting packages leave the engine's upgrade list, and SelfHost.ps1 really is runnable
#      by Windows PowerShell 5.1 (parsed by the real 5.1 parser, not pwsh's);
#   4. the Dell exclusions fail closed;
#   5. the engine never upgrades a self-hosting package in-process again.
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
foreach ($f in 'SelfHost.ps1','UserScope.ps1','Install.ps1','Uninstall.ps1','Show-UpdateDialog.ps1','SunUp-Tray.ps1','Status.ps1') {
  $p = Join-Path $repoRoot $f
  $e = $null
  if (Test-Path $p) {
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e)
    Check "$f parses with no errors" ($e.Count -eq 0) ($e | Out-String)
  } else { Check "$f exists" $false }
}

$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)

Write-Host "`n[2] Report-CrashedRuns"
# stubs for the engine's logging surface
$script:logged = @(); $script:events = @(); $script:alerts = @()
function Write-Log { param($Level, $Msg) $script:logged += "$Level|$Msg" }
function Write-Evt { param([int]$Id, [string]$Type = 'Information', [string]$Msg) $script:events += $Id }
$script:claimedAtAlert = @()
function Raise-SysSentryAlert { param($Msg)
  $script:alerts += $Msg
  # A report must be CLAIMED (incomplete.json created) before it is emitted, or two concurrent
  # scanners would both alert on the same dead run. Record what was true at alert time.
  if ($Msg -match 'Previous run (\S+) never finished') {
    $script:claimedAtAlert += [bool](Test-Path (Join-Path $RunsDir (Join-Path $Matches[1] 'incomplete.json')))
  }
}
$script:Version = 'test'

foreach ($name in 'New-RunDirectory','Publish-JsonFile','Test-RunAlive','Report-CrashedRuns','Split-DcuUpdates','ConvertTo-DcuCategory','Parse-DcuReport','Import-DetachedResults') {
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
Check 'raises a SysSentry alert per dead run' ($script:alerts.Count -eq 3)
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

Write-Host "`n[4] Dell exclusions (the NVIDIA pin, third path)"
$mk = { param($n, $c) [pscustomobject]@{ name = $n; category = $c; version = '1.0'; bytes = 0 } }
$dellScan = @(
  & $mk 'NVIDIA GeForce GTX 1060 Graphics Driver' 'Video'
  & $mk 'Intel HD Graphics Driver'                'Video'
  & $mk 'Realtek Audio Driver'                    'Audio'
  & $mk 'Intel Chipset Device Software'           'Chipset'
)
$s = Split-DcuUpdates $dellScan 'NVIDIA|GeForce'
Check 'the pinned GPU driver is excluded' (($s.excluded | ForEach-Object name) -join ',' -match 'NVIDIA')
Check 'its device category is dropped from the apply' ($s.categories -notcontains 'video') ($s.categories -join ',')
Check 'a same-category update is reported as collateral, not silently dropped' (($s.collateral | ForEach-Object name) -join ',' -eq 'Intel HD Graphics Driver')
Check 'unrelated categories still apply' ((($s.apply | ForEach-Object name) -join ',') -eq 'Realtek Audio Driver,Intel Chipset Device Software')
Check 'the pinned driver never appears in the apply set' (-not (($s.apply | ForEach-Object name) -match 'NVIDIA'))

$none = Split-DcuUpdates $dellScan 'ThisMatchesNothing'
Check 'no match means no filtering at all' ($none.apply.Count -eq 4 -and $none.categories.Count -eq 0 -and $none.excluded.Count -eq 0)

# An excluded update with no category gives dcu-cli nothing to filter on — apply nothing rather than
# risk installing the very thing we promised to skip.
$uncat = Split-DcuUpdates @((& $mk 'NVIDIA GeForce Driver' ''), (& $mk 'Realtek Audio Driver' 'Audio')) 'NVIDIA'
Check 'an uncategorized exclusion blocks the whole apply' ($uncat.apply.Count -eq 0)
Check 'and it is still reported as excluded' ($uncat.excluded.Count -eq 1)
Check 'empty scan is handled' ((Split-DcuUpdates @() 'NVIDIA').apply.Count -eq 0)

# MIXED scan — the case that defeated the first version of this fail-safe: one excluded update WITH a
# category and one WITHOUT. $banned is non-empty, so a naive "all of them lack a category" check
# passes and the uncategorized pinned driver sails through the very filter meant to stop it.
$mixed = Split-DcuUpdates @(
  & $mk 'NVIDIA Quadro Driver'      ''        # no category — unfilterable
  & $mk 'NVIDIA GeForce GTX Driver' 'Video'   # categorized
  & $mk 'Realtek Audio Driver'      'Audio'
) 'NVIDIA|GeForce'
Check 'a MIXED exclusion (one uncategorized) fails closed' ($mixed.apply.Count -eq 0) (($mixed.apply | ForEach-Object name) -join ',')
Check 'the mixed case names no apply categories' ($mixed.categories.Count -eq 0)
Check 'the mixed case explains itself' ($mixed.reason -match 'no device category') $mixed.reason
Check 'the safe update is reported deferred, not lost' (($mixed.collateral | ForEach-Object name) -contains 'Realtek Audio Driver')

# An uncategorized NON-excluded update cannot be selected by -updateDeviceCategory either, so it must
# be reported as deferred rather than counted as installed.
$orphan = Split-DcuUpdates @(
  & $mk 'NVIDIA GeForce GTX Driver' 'Video'
  & $mk 'Mystery Firmware'          ''
  & $mk 'Realtek Audio Driver'      'Audio'
) 'NVIDIA|GeForce'
Check 'an unselectable update is never counted as applied' (-not (($orphan.apply | ForEach-Object name) -contains 'Mystery Firmware')) (($orphan.apply | ForEach-Object name) -join ',')
Check 'it is reported as deferred instead' (($orphan.collateral | ForEach-Object name) -contains 'Mystery Firmware')
Check 'and the categorized survivor still applies' ((($orphan.apply | ForEach-Object name) -join ',') -eq 'Realtek Audio Driver')
Check 'every applied update has a category to select it by' (@($orphan.apply | Where-Object { -not "$($_.category)".Trim() }).Count -eq 0)

# dcu-cli accepts EXACTLY (audio,video,network,storage,input,chipset,others) for
# -updateDeviceCategory and rejects the whole command for anything else -- so the apply exits
# non-zero and installs NOTHING. The report does not speak that vocabulary: the real
# DCUApplicableUpdates.xml on this box says <category>Application</category>, and Dell also ships
# categories containing spaces and commas, which a raw `-join ','` would split into extra bogus
# tokens. Every emitted category must therefore be one of the seven.
$validCats = 'audio','video','network','storage','input','chipset','others'
$vocab = Split-DcuUpdates @(
  & $mk 'NVIDIA GeForce Driver'                 'Video'
  & $mk 'Dell SupportAssist OS Recovery Plugin' 'Application'                     # the REAL one, caldera 2026-08-02
  & $mk 'Dell Universal Receiver Firmware'      'Mouse, Keyboard & Input Devices' # commas + spaces
  & $mk 'Intel Rapid Storage Technology'        'Serial ATA'
) 'NVIDIA'
Check 'every emitted category is one dcu-cli accepts' (@($vocab.categories | Where-Object { $validCats -notcontains $_ }).Count -eq 0) ($vocab.categories -join ',')
Check 'a category containing commas cannot become extra bogus tokens' (($vocab.categories -join ',') -notmatch 'keyboard|devices|serial')
Check 'Application lands in the others bucket' ($vocab.categories -contains 'others')
Check 'Serial ATA lands in storage'            ($vocab.categories -contains 'storage')
Check 'Mouse/Keyboard lands in input'          ($vocab.categories -contains 'input')
Check 'the excluded video category is still dropped' ($vocab.categories -notcontains 'video')
Check 'an uncategorized update still maps to nothing (unfilterable, not "others")' ((ConvertTo-DcuCategory '   ') -eq '')

Write-Host "`n[4b] an unreadable Dell scan report must fail CLOSED"
# An empty parse and a FAILED parse are not the same thing: a truncated/locked/schema-changed report
# used to come back as an empty array, which reads as "nothing to exclude" -- so nothing was banned,
# no category restriction was passed, and /applyUpdates ran unrestricted straight over the pin.
$xmlOk    = Join-Path $PSScriptRoot 'dcu-ok.xml'
$xmlEmpty = Join-Path $PSScriptRoot 'dcu-empty.xml'
$xmlBad   = Join-Path $PSScriptRoot 'dcu-bad.xml'
@'
<?xml version="1.0"?>
<updates version="5.7.0" schemaVersion="1.2">
  <update><release>5CW83</release><name>Dell SupportAssist OS Recovery Plugin</name><version>5.5.16.2</version>
  <urgency>Recommended</urgency><type>Application</type><category>Application</category><bytes>23151424</bytes></update>
</updates>
'@ | Set-Content $xmlOk -Encoding UTF8
'<?xml version="1.0"?><updates version="5.7.0" schemaVersion="1.2"></updates>' | Set-Content $xmlEmpty -Encoding UTF8
'<?xml version="1.0"?><updates><update><name>truncated mid-w' | Set-Content $xmlBad -Encoding UTF8
$okParse = Parse-DcuReport $xmlOk
Check 'a good report parses to its updates' (@($okParse).Count -eq 1) (@($okParse).Count)
Check 'and carries the fields the apply needs' ("$($okParse[0].name)" -match 'SupportAssist' -and "$($okParse[0].category)" -eq 'Application')
$emptyParse = Parse-DcuReport $xmlEmpty
Check 'an EMPTY report parses to an empty list (not $null)' (($null -ne $emptyParse) -and (@($emptyParse).Count -eq 0)) `
      ("isNull=$($null -eq $emptyParse) count=$(@($emptyParse).Count) raw='$(Get-Content $xmlEmpty -Raw)'")
Check 'a TRUNCATED report returns $null, so the caller can fail closed' ($null -eq (Parse-DcuReport $xmlBad))
Check 'a MISSING report returns $null too' ($null -eq (Parse-DcuReport (Join-Path $PSScriptRoot 'no-such-report.xml')))
# dcu-cli has a distinct code for "nothing applicable" (500, no report written), so exit 0 means it
# had something to report. If the parse finds no records in it, the two disagree - a renamed element
# in a future schema would otherwise read as "nothing to exclude" and run the apply unrestricted.
$dellSrc = Get-Content $src -Raw
Check 'exit 0 with no recognized update records is treated as unusable' `
      ($dellSrc -match '\(@\(\$avail\)\.Count -gt 0\)' -and $dellSrc -match 'no recognized update records')

# dcu-cli refuses to write its report into a reserved folder and exits 107 WITHOUT SCANNING.
# C:\ProgramData -- where every run dir lives -- is one; measured on caldera on three consecutive
# runs, all of which then applied nothing while still reporting a clean run.
$dellText = Get-Content $src -Raw
Check 'the scan does NOT report into the run dir (C:\ProgramData is reserved)' ($dellText -notmatch '\$reportDir\s*=\s*\$script:RunDir')
Check 'it reports into a dedicated staging dir instead' ($dellText -match 'function Get-DcuReportDir' -and $dellText -match '-report="\$scanDir"')
Check 'and the report is still copied into the run dir for the record' ($dellText -match "Copy-Item \`$xmlPath \(Join-Path \`$script:RunDir 'DCUApplicableUpdates\.xml'\)")
Check 'an unusable scan is an ERROR, so it reaches event 2010 and SysSentry' ($dellText -match "status = 'error'; detail = .scan unusable")
Check 'a wholly blocked apply is not reported as a clean ok' ($dellText -match "no Dell update can be applied while the exclusion stands")
# `icacls /inheritance:r /grant` removes only INHERITED entries: an unprivileged process that created
# C:\SunUp first keeps its own explicit ACE and its OWNERSHIP, and an owner can restore the DACL.
# Replacing the whole DACL and taking ownership is what actually locks it. (icacls is also a native
# command whose non-zero exit throws nothing, so the old try/catch could never report a failure.)
Check 'the staging dir DACL is replaced, not merely un-inherited' ($dellText -match 'SetAccessRuleProtection\(\$true, \$false\)' -and $dellText -match 'SetOwner\(\$admins\)')
# New-Item -Force REUSES an existing dir, and the run stamp is predictable (daily 08:00 trigger), so
# a per-run dir pre-created before the parent was ever locked down keeps its creator's ACEs.
Check 'the per-run staging child is hardened too, not just its ancestors' `
      ($dellText -match 'function Protect-Directory' -and $dellText -match 'if \(-not \(Protect-Directory \$scanDir\)\)')
# ...but a C:\SunUp that pre-dates SunUp and holds unrelated files must NOT have its DACL and owner
# replaced - that would lock its owner out of their own data. Uninstall draws the same line.
Check 'a pre-existing foreign staging parent is refused, not taken over' `
      ($dellText -match 'already contains files that are not SunUp' -and $dellText -match '\$foreign = @\(Get-ChildItem \$root')
Check 'and ownership is taken with it' ($dellText -match "SecurityIdentifier 'S-1-5-32-544'")
# EVERY ancestor, not just the leaf: C:\SunUp pre-created as a junction leaves C:\SunUp\dcu looking
# like an ordinary folder while every ACL we set follows the junction to a target the planter owns.
Check 'a reparse point ANYWHERE in the staging path is refused' `
      ($dellText -match 'function Test-PathHasReparsePoint' -and $dellText -match 'refusing to scan under it' -and $dellText -match 'if \(Test-PathHasReparsePoint \$Path\) \{ return \$false \}')
$rpFn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-PathHasReparsePoint' }, $true)
Check 'Test-PathHasReparsePoint found in source' ($null -ne $rpFn)
if ($rpFn) {
  Invoke-Expression $rpFn.Extent.Text
  $rpBase = Join-Path $PSScriptRoot 'rp-probe'
  $rpReal = Join-Path $rpBase 'real'; $rpLeaf = Join-Path $rpBase 'link\leaf'
  New-Item -ItemType Directory -Force (Join-Path $rpReal 'leaf') | Out-Null
  $mk = & cmd /c mklink /J "$rpBase\link" "$rpReal" 2>&1     # junction in an ANCESTOR of the leaf
  Check 'an ordinary path is accepted' (-not (Test-PathHasReparsePoint (Join-Path $rpReal 'leaf')))
  if (Test-Path "$rpBase\link") {
    Check 'a junction in an ANCESTOR is caught, not just the leaf' (Test-PathHasReparsePoint $rpLeaf) "$mk"
  } else { Check 'junction could not be created (skipped)' $true }
  Remove-Item $rpBase -Recurse -Force -ErrorAction SilentlyContinue
}
# Overlapping runs sharing one staging dir would delete each other's report mid-flight.
Check 'each run stages its scan in its own subdirectory' ($dellText -match '\$scanDir = Join-Path \$scanRoot \(Split-Path \$script:RunDir -Leaf\)')
# Returning the dir after a FAILED lockdown would have Comp-Dell trust a report that may still be
# writable by whoever pre-created the folder - and that report is what keeps the pinned driver out.
Check 'a failed lockdown fails CLOSED rather than trusting the dir' `
      ($dellText -match '(?s)could not lock down \$Path.{0,200}return \$false' -and $dellText -match 'if \(-not \(Protect-Directory \$d\)\) \{ return \$null \}')
Check 'and Comp-Dell turns that into an error, not an apply' ($dellText -match 'if \(-not \$scanRoot\)' -and $dellText -match 'could not be trusted')
Check 'the report is found by what the scan produced, not an assumed file name' ($dellText -match "Get-ChildItem \`$scanDir -Filter '\*\.xml'")

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
$script:Updates.Add([ordered]@{ name='Google Chrome'; source='winget'; old='150.0';  new='150.1';   durationSec=4; sizeMB=90 })
$script:Updates.Add([ordered]@{ name='Google Chrome'; source='winget'; old='150.0';  new='150.1';   durationSec=4; sizeMB=90 })
Invoke-Expression $m.Value
Check '$Name survives the collapse block' ($Name -eq 'SunUp') "got '$Name'"
Check 'duplicate rows still collapse' ($script:Updates.Count -eq 2) "$($script:Updates.Count) rows"
Check 'and the collapsed row is annotated' (($script:Updates | ForEach-Object { $_.name }) -join ',' -match ([char]0x00D7)) (($script:Updates | ForEach-Object { $_.name }) -join ',')

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
      ($engineText2 -match '\$nextCursor = if \(\$detached\.scanned\) \{ \$ingestScanAt\.ToString\(.o.\)' -and $engineText2 -match 'ingestCursor = \$nextCursor')
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
$cvFn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-UtcTime' }, $true)
Check 'ConvertTo-UtcTime found in source' ($null -ne $cvFn)
if ($cvFn) {
  Invoke-Expression $cvFn.Extent.Text
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
Check 'and stops running task instances before unregistering them' ($uninstText -match 'Stop-ScheduledTask')
# Removal errors are suppressed, so "Purged …" was printed even when a path survived an open handle.
Check 'purge reports only what it actually removed' ($uninstText -match 'Could NOT remove' -and $uninstText -match 'Where-Object \{ -not \(Test-Path \$_\) \}')
# C:\SunUp may have pre-existed with unrelated data: Get-DcuReportDir creates the 'dcu' child inside
# whatever was already there, so purging the PARENT recursively would destroy someone else's files.
Check 'purge removes only the dcu subtree, not whatever else lives in C:\SunUp' `
      ($uninstText -match "Join-Path \`$stageRoot 'dcu'" -and $uninstText -notmatch 'Remove-Item .\$env:SystemDrive.\$Name. -Recurse')
Check 'and removes the parent only when it is empty' `
      ($uninstText -match '(?s)Get-ChildItem \$stageRoot -Force.{0,120}Remove-Item \$stageRoot -Force')

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
  foreach ($f in 'dcu-ok.xml','dcu-empty.xml','dcu-bad.xml') { Remove-Item (Join-Path $PSScriptRoot $f) -Force -ErrorAction SilentlyContinue }
}
Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green } else { Write-Host "$fail TEST(S) FAILED" -ForegroundColor Red; exit 1 }
