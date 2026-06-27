# Thin status wrapper — prints the last SunUp run, the day stamp, and task state.
# Usage: pwsh -File C:\ProgramData\SunUp\bin\Status.ps1
$engine = Join-Path $PSScriptRoot 'SunUp.ps1'
if (-not (Test-Path $engine)) { $engine = 'C:\ProgramData\SunUp\bin\SunUp.ps1' }
& $engine -Mode Status
