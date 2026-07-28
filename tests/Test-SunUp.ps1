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
function Raise-SysSentryAlert { param($Msg) $script:alerts += $Msg }
$script:Version = 'test'

$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Report-CrashedRuns' }, $true)
Check 'Report-CrashedRuns found in source' ($null -ne $fn)
Invoke-Expression $fn.Extent.Text

$RunsDir = Join-Path $PSScriptRoot 'runs'
if (Test-Path $RunsDir) { Remove-Item $RunsDir -Recurse -Force }
# good = finished; dead1/dead2 = killed; empty = dir with no run.log; live = the current run
foreach ($d in 'good','dead1','dead2','empty','live') { New-Item -ItemType Directory -Force (Join-Path $RunsDir $d) | Out-Null }
'x' | Set-Content (Join-Path $RunsDir 'good\run.log');  '{}' | Set-Content (Join-Path $RunsDir 'good\result.json')
@('start','winget: starting…') | Set-Content (Join-Path $RunsDir 'dead1\run.log')
'died here' | Set-Content (Join-Path $RunsDir 'dead2\run.log')
'live run in progress' | Set-Content (Join-Path $RunsDir 'live\run.log')
$script:RunDir = (Join-Path $RunsDir 'live')

Report-CrashedRuns
Check 'flags both dead runs' ($script:events.Count -eq 2) "events=$($script:events -join ',')"
Check 'uses event id 2011' (($script:events | Sort-Object -Unique) -join ',' -eq '2011')
Check 'raises a SysSentry alert per dead run' ($script:alerts.Count -eq 2)
Check 'ignores the finished run' (-not ($script:alerts -match 'good'))
Check 'ignores the run dir with no run.log' (-not ($script:alerts -match 'empty'))
Check 'never flags the live run dir' (-not ($script:alerts -match 'live'))
Check 'quotes the last line the dead run logged' ($script:alerts[0] -match 'winget: starting') $script:alerts[0]
Check 'writes incomplete.json markers' ((Test-Path (Join-Path $RunsDir 'dead1\incomplete.json')) -and (Test-Path (Join-Path $RunsDir 'dead2\incomplete.json')))

$script:events = @(); $script:alerts = @()
Report-CrashedRuns
Check 'second pass is silent (alert fires once)' ($script:events.Count -eq 0 -and $script:alerts.Count -eq 0)

Write-Host "`n[3] self-hosting partition + --custom tagging"
$selfPat  = 'Microsoft\.PowerShell|Microsoft\.DesktopAppInstaller'
$selfArgs = 'MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress'
$isSelfHost = { param($Pkg) $selfPat -and ($Pkg.id -match $selfPat -or $Pkg.name -match $selfPat) }
# the real 2026-07-22 list, minus the excluded VCLibs pair
$pending = @(
  [pscustomobject]@{ name='Google Chrome';   id='Google.Chrome.EXE';    old='150.0.7871.129'; new='150.0.7871.182' }
  [pscustomobject]@{ name='PowerShell 7-x64'; id='Microsoft.PowerShell'; old='7.6.3.0';        new='7.6.4.0' }
  [pscustomobject]@{ name='Tailscale';        id='tailscale.tailscale';  old='1.98.9';         new='1.99.0' }
)
$deferred = @($pending | Where-Object { & $isSelfHost $_ })
Check 'PowerShell is detected as self-hosting' ($deferred.Count -eq 1 -and $deferred[0].id -eq 'Microsoft.PowerShell')
$pending = @(@($pending | Where-Object { -not (& $isSelfHost $_) }) + $deferred)
Check 'no package is lost by the partition' ($pending.Count -eq 3)
Check 'PowerShell is upgraded last' ($pending[-1].id -eq 'Microsoft.PowerShell') (($pending | ForEach-Object id) -join ' -> ')
$argsFor = $pending | ForEach-Object {
  $extra = @(); if ((& $isSelfHost $_) -and $selfArgs) { $extra = @('--custom', $selfArgs) }
  [pscustomobject]@{ id = $_.id; extra = ($extra -join ' ') }
}
Check 'only the self-hosting package gets --custom' (@($argsFor | Where-Object extra).Count -eq 1 -and ($argsFor | Where-Object extra).id -eq 'Microsoft.PowerShell')
Check 'RM is disabled in those args' (($argsFor | Where-Object extra).extra -match 'MSIRESTARTMANAGERCONTROL=Disable')
Check 'not --override (would drop winget''s silent defaults)' (($argsFor | Where-Object extra).extra -notmatch '--override')
# Splatting an array into a native command must expand to separate argv entries, with the
# space-containing value kept as ONE argument (quoted by PowerShell) — otherwise winget would see
# REBOOT=ReallySuppress as a stray positional and reject the command.
$echoed = & cmd /c echo @('--custom', $selfArgs)
Check 'array splat expands to --custom + one quoted value' ($echoed -match '^--custom "MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress"$') $echoed

Remove-Item $RunsDir -Recurse -Force
Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green } else { Write-Host "$fail TEST(S) FAILED" -ForegroundColor Red; exit 1 }
