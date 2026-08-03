#Requires -RunAsAdministrator
# Removes the SunUp scheduled tasks. Leaves C:\ProgramData\SunUp (logs, REPORT.md, config)
# in place unless -Purge is given. Also best-effort removes any leftover legacy 'AutoUpdate'
# task/dir/source (e.g. after a partial migration). Refreshes the SysSentry baseline.
param([switch]$Purge)
$ErrorActionPreference = 'Continue'

$Name = 'SunUp'
# Stop anything of ours that is currently running, THEN remove the tasks. Unregister-ScheduledTask
# does not terminate a running instance, and the detached helpers are not task instances at all, so
# without this an uninstall could report success while SelfHost.ps1 went on to upgrade PowerShell 7
# minutes later -- Restart Manager killing the admin's terminals after they were told SunUp was gone
# -- and UserScope.ps1 kept upgrading packages against a config dir that no longer exists.
# Both hosts matter: the tray/dialog/user pass run under pwsh.exe, the self-host helpers under
# Windows PowerShell 5.1 (powershell.exe). Match on our script names, so no unrelated shell is hit.
# Match the INSTALLED paths, not bare file names: '*\SelfHost.ps1*' would also match an unrelated
# C:\tools\SelfHost.ps1, or a developer running another checkout of this repo, and an elevated
# uninstall would kill it.
$Bin = "C:\ProgramData\$Name\bin"
$ourScripts = @('SunUp.ps1', 'SunUp-Tray.ps1', 'Show-UpdateDialog.ps1', 'UserScope.ps1', 'SelfHost.ps1') |
              ForEach-Object { Join-Path $Bin $_ }
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $cl = "$($_.CommandLine)"; @($ourScripts | Where-Object { $cl -like "*$_*" }).Count -gt 0 } |
  ForEach-Object {
    Write-Host "  stopping pid $($_.ProcessId) ($($_.Name))"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
# SunUp-SelfHost is a one-shot that normally self-deletes; it is listed here in case a run was
# interrupted between registering it and its own cleanup. Stop before unregistering: a task that is
# mid-run survives being unregistered.
foreach ($t in @($Name, "$Name-Notify", "$Name-Tray", "$Name-User", "$Name-SelfHost", 'AutoUpdate', 'AutoUpdate-Notify')) {
  try { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue } catch {}
  Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Write-Host "Unregistered tasks '$Name' + '$Name-Notify' + '$Name-Tray' + '$Name-User' + '$Name-SelfHost' (and any legacy AutoUpdate tasks)."

if ($Purge) {
  # v0.13.x staged Dell scan reports in C:\SunUp (dcu-cli refuses to write into C:\ProgramData).
  # That integration is gone as of v0.14.0, but an upgraded install may still have the directory, so
  # clean it up here. Only the 'dcu' child was ever ours: C:\SunUp may pre-date SunUp and hold
  # unrelated data, so the parent goes only when it is left empty.
  $legacyStage = Join-Path $env:SystemDrive $Name
  # TRACKED, not merely attempted. The report below is built from this list, so a removal that is
  # not in it cannot be reported as having failed — and every Remove-Item here suppresses its errors,
  # which is exactly why the reporting exists.
  $attempted = [System.Collections.Generic.List[string]]::new()
  foreach ($p in @("C:\ProgramData\$Name", (Join-Path $legacyStage 'dcu'))) {
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    $attempted.Add($p)
  }
  # The parent only when we left it empty. Added to the tracked list ONLY when removal was actually
  # attempted, so a parent deliberately left alone (it holds someone else's data) is not reported as
  # a failure — while one we tried and failed to remove is.
  if ((Test-Path $legacyStage) -and -not @(Get-ChildItem $legacyStage -Force -ErrorAction SilentlyContinue).Count) {
    Remove-Item $legacyStage -Force -ErrorAction SilentlyContinue
    $attempted.Add($legacyStage)
  }
  foreach ($src in @($Name, 'AutoUpdate')) {
    if ([System.Diagnostics.EventLog]::SourceExists($src)) { Remove-EventLog -Source $src -ErrorAction SilentlyContinue }
  }
  # Removal errors above are suppressed (an open handle, a locked log), so report what is actually
  # gone rather than announcing a purge that did not happen.
  $left = @($attempted | Where-Object { Test-Path $_ })
  $gone = @($attempted | Where-Object { -not (Test-Path $_) })
  if ($gone.Count -gt 0) { Write-Host "Purged $($gone -join ', ') and event source(s)." }
  if ($left.Count -gt 0) {
    Write-Warning "Could NOT remove: $($left -join ', ') — something still holds a handle. Re-run after a reboot, or delete by hand."
  }
}

$sentry = 'C:\ProgramData\SysSentry\bin\Sentry.ps1'
if (Test-Path $sentry) { & (Get-Command pwsh).Source -NoProfile -ExecutionPolicy Bypass -File $sentry -Mode Baseline }
Write-Host 'Done.'
