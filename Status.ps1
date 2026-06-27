# Thin status wrapper — prints the last AutoUpdate run, the day stamp, and task state.
# Usage: pwsh -File C:\ProgramData\AutoUpdate\bin\Status.ps1
$engine = Join-Path $PSScriptRoot 'AutoUpdate.ps1'
if (-not (Test-Path $engine)) { $engine = 'C:\ProgramData\AutoUpdate\bin\AutoUpdate.ps1' }
& $engine -Mode Status
