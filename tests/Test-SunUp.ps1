# Tests for the v0.10.0 crash-reporting and self-hosting-package logic. Safe to run anywhere:
# no live update run, no installs, no reboots, nothing touched outside this folder.
#   1. the engine parses;
#   2. Report-CrashedRuns (lifted from source via AST) flags exactly the dead run dirs, once;
#   3. the self-hosting partition orders deferred packages last and only tags those with --custom.
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

foreach ($name in 'New-RunDirectory','Publish-JsonFile','Test-RunAlive','Report-CrashedRuns','Test-WingetHasMsiInstaller','Test-WingetArgsRejected','Split-DcuUpdates') {
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

Write-Host "`n[3] self-hosting partition + --custom tagging"
$selfPat  = 'Microsoft\.PowerShell|Microsoft\.DesktopAppInstaller'
$selfArgs = 'MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress'
$isSelfHost = { param($Pkg) $selfPat -and ($Pkg.id -match $selfPat -or $Pkg.name -match $selfPat) }
# the real 2026-07-22 list (minus the excluded VCLibs pair) plus App Installer, the OTHER half of the
# default selfHostPattern — and an MSIX, so it must be deferred but must NOT receive MSI properties
$pending = @(
  [pscustomobject]@{ name='Google Chrome';    id='Google.Chrome.EXE';            old='150.0.7871.129'; new='150.0.7871.182' }
  [pscustomobject]@{ name='PowerShell 7-x64'; id='Microsoft.PowerShell';         old='7.6.3.0';        new='7.6.4.0' }
  [pscustomobject]@{ name='App Installer';    id='Microsoft.DesktopAppInstaller'; old='1.29.280.0';    new='1.30.0.0' }
  [pscustomobject]@{ name='Tailscale';        id='tailscale.tailscale';          old='1.98.9';         new='1.99.0' }
)
$deferred = @($pending | Where-Object { & $isSelfHost $_ })
Check 'both self-hosting packages are detected' ($deferred.Count -eq 2) (($deferred | ForEach-Object id) -join ',')
$pending = @(@($pending | Where-Object { -not (& $isSelfHost $_) }) + $deferred)
Check 'no package is lost by the partition' ($pending.Count -eq 4)
Check 'self-hosting packages are upgraded last' ((& $isSelfHost $pending[-1]) -and (& $isSelfHost $pending[-2])) (($pending | ForEach-Object id) -join ' -> ')
Check 'ordinary packages keep their original order' ((($pending[0..1] | ForEach-Object id) -join ',') -eq 'Google.Chrome.EXE,tailscale.tailscale')

# REGRESSION (v0.10.1): the probe must ask "does an MSI-family installer EXIST for this package",
# not "what is the default installer type". Microsoft.PowerShell really does publish both, plain
# `winget show` really does answer msix, and the upgrade that killed the engine on 2026-07-22 really
# did run the WiX .msi — so the old question would have withheld the Restart Manager args from the
# one package this entire feature exists to protect. $realPwsh reproduces winget's actual answers.
# No param() block: the engine calls these positionally with winget's real flags ("-e", "--id", ...),
# and only a scriptblock without declared parameters takes them into $args verbatim instead of
# trying to bind "-e" as a parameter name.
$typeArg = { param($a) for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -eq '--installer-type') { return "$($a[$i+1])" } }; $null }
$noInstaller = "Installer:`n    No applicable installer found; see logs for more details."
$realPwsh = {
  # Mirrors winget 1.29 for Microsoft.PowerShell: the default block names the msix, and only
  # --installer-type wix is applicable — the .msi that an upgrade of an MSI-installed copy runs.
  $t = & $typeArg $args
  if ($t) {
    if ($t -eq 'wix') { return "Installer:`n  Installer Type: wix`n  Installer Url: https://example.invalid/PowerShell-7.6.4-win-x64.msi" }
    return $noInstaller
  }
  "Installer:`n  Installer Type: msix`n  Installer Url: https://example.invalid/PowerShell-7.6.4.msixbundle"
}.GetNewClosure()
$realMsixOnly = {
  if (& $typeArg $args) { return $noInstaller }
  "Installer:`n  Installer Type: msix"
}.GetNewClosure()
$fakeDead = { throw 'winget exploded' }
Check 'a package publishing a WiX .msi is detected despite an msix default' (Test-WingetHasMsiInstaller $realPwsh 'Microsoft.PowerShell')
Check 'an msix-only package is not' (-not (Test-WingetHasMsiInstaller $realMsixOnly 'Microsoft.DesktopAppInstaller'))
Check 'a failing winget show yields false, not a crash' (-not (Test-WingetHasMsiInstaller $fakeDead 'whatever'))

# Retrying without the Restart Manager args is only safe BEFORE anything installs. A failure that
# happens after the download/install started must NOT be retried: the retry would rerun an installer
# against partially changed state with RM re-enabled — the original kill, re-armed.
$rc = 3010, 0x8A150077, 0x8A150078, 0x8A150079
$rejected = "winget: unrecognized argument`nAn unexpected error occurred."
$downloadFailed = @'
Found PowerShell [Microsoft.PowerShell]
Downloading https://example.invalid/PowerShell-7.6.4-win-x64.msi
Network error
'@
$installFailed = @'
Successfully verified installer hash
Starting package install...
Installer failed with exit code: 1603
'@
Check 'an argument rejection is retried'            (Test-WingetArgsRejected $rejected 1 $rc)
Check 'a failed download is NOT retried'            (-not (Test-WingetArgsRejected $downloadFailed 1 $rc))
Check 'a failure after install began is NOT retried' (-not (Test-WingetArgsRejected $installFailed 1603 $rc))
Check 'success is never retried'                     (-not (Test-WingetArgsRejected $rejected 0 $rc))
Check 'a reboot-required exit is never retried'      (-not (Test-WingetArgsRejected $rejected 3010 $rc))

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

# End-to-end arg decision, using the real probe against each package's real winget behaviour.
$probeFor = @{ 'Microsoft.PowerShell' = $realPwsh; 'Microsoft.DesktopAppInstaller' = $realMsixOnly }
$argsFor = $pending | ForEach-Object {
  $extra = @()
  if ((& $isSelfHost $_) -and $selfArgs -and (Test-WingetHasMsiInstaller $probeFor[$_.id] $_.id)) { $extra = @('--custom', $selfArgs) }
  [pscustomobject]@{ id = $_.id; extra = ($extra -join ' ') }
}
$tagged = @($argsFor | Where-Object extra)
Check 'only the MSI self-hosting package gets --custom' ($tagged.Count -eq 1 -and $tagged[0].id -eq 'Microsoft.PowerShell') (($tagged | ForEach-Object id) -join ',')
Check 'the MSIX self-hosting package is deferred but NOT given MSI properties' (-not ($argsFor | Where-Object { $_.id -eq 'Microsoft.DesktopAppInstaller' }).extra)
Check 'RM is disabled in those args' ($tagged[0].extra -match 'MSIRESTARTMANAGERCONTROL=Disable')
Check 'not --override (would drop winget''s silent defaults)' ($tagged[0].extra -notmatch '--override')
# Splatting an array into a native command must expand to separate argv entries, with the
# space-containing value kept as ONE argument (quoted by PowerShell) — otherwise winget would see
# REBOOT=ReallySuppress as a stray positional and reject the command.
$echoed = & cmd /c echo @('--custom', $selfArgs)
Check 'array splat expands to --custom + one quoted value' ($echoed -match '^--custom "MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress"$') $echoed

} finally {
  if (Test-Path $RunsDir) { Remove-Item $RunsDir -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green } else { Write-Host "$fail TEST(S) FAILED" -ForegroundColor Red; exit 1 }
