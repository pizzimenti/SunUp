#Requires -RunAsAdministrator
# Removes the AutoUpdate scheduled task. Leaves C:\ProgramData\AutoUpdate (logs,
# REPORT.md, config) in place unless -Purge is given. Refreshes SysSentry baseline.
param([switch]$Purge)
$ErrorActionPreference = 'Continue'

Unregister-ScheduledTask -TaskName 'AutoUpdate'        -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'AutoUpdate-Notify' -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Unregistered tasks 'AutoUpdate' + 'AutoUpdate-Notify'."

if ($Purge) {
  Remove-Item 'C:\ProgramData\AutoUpdate' -Recurse -Force -ErrorAction SilentlyContinue
  if ([System.Diagnostics.EventLog]::SourceExists('AutoUpdate')) { Remove-EventLog -Source 'AutoUpdate' -ErrorAction SilentlyContinue }
  Write-Host 'Purged C:\ProgramData\AutoUpdate and event source.'
}

$sentry = 'C:\ProgramData\SysSentry\bin\Sentry.ps1'
if (Test-Path $sentry) { & (Get-Command pwsh).Source -NoProfile -ExecutionPolicy Bypass -File $sentry -Mode Baseline }
Write-Host 'Done.'
