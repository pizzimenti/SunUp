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

foreach ($name in 'New-RunDirectory','Publish-JsonFile','Test-RunAlive','Report-CrashedRuns','Split-DcuUpdates') {
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
Check 'the handoff is skipped when a reboot is imminent' ($engineText -match 'if \(\$willReboot\)[\s\S]{0,200}NOT starting')

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
