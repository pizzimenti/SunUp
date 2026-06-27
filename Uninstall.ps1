#Requires -RunAsAdministrator
# Removes the SunUp scheduled tasks. Leaves C:\ProgramData\SunUp (logs, REPORT.md, config)
# in place unless -Purge is given. Also best-effort removes any leftover legacy 'AutoUpdate'
# task/dir/source (e.g. after a partial migration). Refreshes the SysSentry baseline.
param([switch]$Purge)
$ErrorActionPreference = 'Continue'

$Name = 'SunUp'
foreach ($t in @($Name, "$Name-Notify", 'AutoUpdate', 'AutoUpdate-Notify')) {
  Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Write-Host "Unregistered tasks '$Name' + '$Name-Notify' (and any legacy AutoUpdate tasks)."

if ($Purge) {
  Remove-Item "C:\ProgramData\$Name" -Recurse -Force -ErrorAction SilentlyContinue
  foreach ($src in @($Name, 'AutoUpdate')) {
    if ([System.Diagnostics.EventLog]::SourceExists($src)) { Remove-EventLog -Source $src -ErrorAction SilentlyContinue }
  }
  Write-Host "Purged C:\ProgramData\$Name and event source(s)."
}

$sentry = 'C:\ProgramData\SysSentry\bin\Sentry.ps1'
if (Test-Path $sentry) { & (Get-Command pwsh).Source -NoProfile -ExecutionPolicy Bypass -File $sentry -Mode Baseline }
Write-Host 'Done.'
