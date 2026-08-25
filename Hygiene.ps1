<#
Read-only hygiene checks, surfaced by the engine as a REPORT LINE — never as an alert.

WHY THIS LIVES IN SUNUP
-----------------------
SunUp already runs daily, already owns the report/dialog/history plumbing, and is already the one
place on this box that knows what is installed. A separate hygiene tool would have meant a second
scheduled task, a second config file and a second thing to remember — which is how SysSentry went
from "drift monitor" to "do-everything suite" before being retired on 2026-08-15. Folding the
checks in here costs no new task, no new surface, and no new place to look.

WHAT IT WATCHES FOR, AND WHY THESE FOUR
---------------------------------------
On 2026-08-24 the 2026-07-03 account rename was found to have left seven registry values still
pointing at the vanished C:\Users\user. The damage had been invisible for seven weeks because every
affected installer FAILED SILENTLY WITH EXIT CODE 0:

  - winget could not read Python 3.13.14's bundle cache, so rather than upgrading in place it
    installed 3.13.15 SIDE-BY-SIDE. Two interpreters on PATH, the older one winning.
  - Neither could then be removed. Both share Burn provider key CPython-3.13, and 3.13.14 was
    registered as a DEPENDENT of 3.13.15, so uninstalling either printed nothing and returned 0
    ("w210: Plan skipped due to 1 remaining dependents").
  - LM Studio's UninstallString was broken identically; its pending winget upgrade — a SunUp
    concern — would have failed the same way.

That is the failure class this file exists to catch: not things that crash, but things that report
success while doing nothing. Note that check 1 is what actually exposed the double Python. Neither
install looked anomalous on disk; both were normal-sized and internally intact. The only visible
tell was two rows sharing one Id.

DESIGN RULE: SILENT WHEN CLEAN
------------------------------
Every check is deterministic and yields NO findings on a healthy box. That is precisely what makes
one worth running unattended, and it is the bar any future check must clear.

Size heuristics were considered and REJECTED. The two largest directories on caldera are
.rustup\toolchains (3.9 GB) and .nuget\packages (2.3 GB), and both are legitimate — the 1.97.1
toolchain is pinned deliberately by eth-link-tester\rust-toolchain.toml precisely so SunUp cannot
move it underneath the project. A size threshold would fire every single run against intentional
state, which is the alert fatigue that made SysSentry's ALERTS.md worthless. Free space is the sole
exception, because a full disk is an emergency rather than a matter of taste.

THIS FILE NEVER MODIFIES ANYTHING. It reports. Acting on a finding is a human decision — that
separation is what keeps it from growing into the suite that was retired.

A NOTE ON PATH MATCHING
-----------------------
Every path comparison below uses -like, never -match. Windows paths are the worst possible input
for regex because backslash is the escape character: 'C:\Users\user\' throws "Unrecognized escape
sequence \U" at MATCH time, per item, inside the pipeline — so it fails item-by-item rather than up
front. That bug was hit twice while this code was being written.

Run directly (pwsh -File Hygiene.ps1) to print findings on demand; dot-source it to get
Get-HygieneFindings for the engine.
#>

function Get-HygieneFindings {
  <#
    Returns an array of finding strings. EMPTY ARRAY = clean.
    Never throws: each check is individually guarded so one broken probe cannot take down a run.
  #>
  param([int]$MinFreeGB = 25)

  $findings = [System.Collections.Generic.List[string]]::new()

  # ---------------------------------------------------------------------------------------------
  # 1. Duplicate winget package Ids
  #
  # Parsed by HEADER INDEX rather than fixed offsets: winget renders a width-adaptive table and
  # silently drops columns entirely on a narrow console, so hard-coded columns break without saying
  # so — which is the same class of failure this whole file exists to catch.
  # ---------------------------------------------------------------------------------------------
  try {
    # Framework redistributables are SIDE-BY-SIDE BY DESIGN: one winget Id covers both the x86 and
    # x64 payloads, and several major versions coexist because different apps bind to different
    # ones. winget list exposes no architecture column, so they cannot be told from a real duplicate
    # by shape — they have to be excluded by name.
    #
    # This list is the difference between a check that gets read and one that gets skipped. Before
    # it existed the check reported 12 "duplicates", every one a legitimate arch pair. One genuine
    # finding buried in twelve false ones is worse than no check at all.
    $sideBySide = @(
      'Microsoft.VCLibs.*', 'Microsoft.UI.Xaml.*', 'Microsoft.WindowsAppRuntime*',
      'Microsoft.DotNet.Native.*'
    )
    $raw = @(winget list --source winget 2>$null)
    $hdr = $raw | Where-Object { $_ -match 'Name\s+Id\s+Version' } | Select-Object -First 1
    if (-not $hdr) {
      $findings.Add('hygiene: could not parse winget list output') | Out-Null
    } else {
      $idStart  = $hdr.IndexOf('Id')
      $verStart = $hdr.IndexOf('Version')
      $ids = foreach ($line in $raw) {
        if ($line.Length -gt $verStart -and $line -notmatch '^-+$' -and $line -ne $hdr) {
          $id = $line.Substring($idStart, $verStart - $idStart).Trim()
          # ARP\ and MSIX\ pseudo-Ids are OS plumbing (driver stubs, Store runtimes). They duplicate
          # legitimately across architectures and are never actionable.
          if (-not $id -or $id -like 'ARP\*' -or $id -like 'MSIX\*') { continue }
          $isFramework = $false
          foreach ($pat in $sideBySide) { if ($id -like $pat) { $isFramework = $true; break } }
          if (-not $isFramework) { $id }
        }
      }
      foreach ($d in @($ids | Group-Object | Where-Object { $_.Count -gt 1 })) {
        $findings.Add("duplicate install: $($d.Name) x$($d.Count) — one winget Id, two installs; likely a failed in-place upgrade") | Out-Null
      }
    }
  } catch { $findings.Add("hygiene: winget duplicate check failed — $($_.Exception.Message)") | Out-Null }

  # ---------------------------------------------------------------------------------------------
  # 2. PATH entries that do not resolve, and duplicated entries.
  # A dead entry costs a failed directory stat in EVERY process launch on the box.
  # ---------------------------------------------------------------------------------------------
  try {
    foreach ($scope in 'Machine','User') {
      $parts = @([Environment]::GetEnvironmentVariable('Path',$scope) -split ';' | Where-Object { $_ -ne '' })
      foreach ($p in $parts) {
        if (-not (Test-Path $p)) { $findings.Add("$scope PATH -> missing: $p") | Out-Null }
      }
      # Duplicates are harmless at runtime but signal PATH edits that appended without checking.
      foreach ($d in @($parts | Group-Object | Where-Object { $_.Count -gt 1 })) {
        $findings.Add("$scope PATH -> duplicated x$($d.Count): $($d.Name)") | Out-Null
      }
    }
  } catch { $findings.Add("hygiene: PATH check failed — $($_.Exception.Message)") | Out-Null }

  # ---------------------------------------------------------------------------------------------
  # 3. Uninstall entries whose target no longer exists.
  #
  # THE CHECK THAT WOULD HAVE CAUGHT THE RENAME DAMAGE SEVEN WEEKS EARLIER, and the one most
  # directly relevant to SunUp: a broken UninstallString is exactly what makes a winget upgrade
  # silently install side-by-side instead of upgrading.
  #
  # Extracting a testable path is the fiddly part, and getting it wrong produces false positives
  # that train you to ignore the output:
  #   - UninstallString may be quoted, may carry arguments, may be a bare exe followed by switches
  #   - DisplayIcon carries a trailing ,<index> icon selector
  #   - msiexec/rundll32 style entries reference no real file path and must be skipped
  # ---------------------------------------------------------------------------------------------
  try {
    $roots = @(
      'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $valueNames = 'UninstallString','QuietUninstallString','BundleCachePath','DisplayIcon'
    $skipHosts  = 'msiexec.exe','rundll32.exe','cmd.exe','powershell.exe','pwsh.exe'

    foreach ($root in $roots) {
      foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        if (-not $props -or -not $props.DisplayName) { continue }
        foreach ($vn in $valueNames) {
          $value = $props.$vn
          if (-not $value) { continue }
          $v = "$value".Trim()
          $path = $null
          if ($v.StartsWith('"')) {
            $end = $v.IndexOf('"', 1)
            if ($end -gt 0) { $path = $v.Substring(1, $end - 1) }
          } else {
            # Unquoted: take everything up to the first .exe so spaces in the directory survive.
            $m = [regex]::Match($v, '^(.+?\.exe)', 'IgnoreCase')
            if ($m.Success) { $path = $m.Groups[1].Value }
          }
          if (-not $path) { continue }
          $path = $path -replace ',\d+$', ''             # strip DisplayIcon's ,0 selector
          if ([System.IO.Path]::GetFileName($path) -in $skipHosts) { continue }
          if ($path -notlike '?:\*') { continue }        # not an absolute local path; nothing to verify
          if (-not (Test-Path $path)) {
            $findings.Add("$($props.DisplayName) :: $vn -> missing: $path") | Out-Null
          }
        }
      }
    }
  } catch { $findings.Add("hygiene: uninstall-entry check failed — $($_.Exception.Message)") | Out-Null }

  # ---------------------------------------------------------------------------------------------
  # 4. Free space. The one threshold worth keeping: 256 GB NVMe, and build caches grow unbounded.
  # ---------------------------------------------------------------------------------------------
  try {
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                    Where-Object { $null -ne $_.Used -and $null -ne $_.Free })) {
      $freeGB = [math]::Round($d.Free / 1GB, 1)
      if ($freeGB -lt $MinFreeGB) {
        $findings.Add("drive $($d.Name): only $freeGB GB free (threshold $MinFreeGB GB)") | Out-Null
      }
    }
  } catch { $findings.Add("hygiene: free-space check failed — $($_.Exception.Message)") | Out-Null }

  return $findings.ToArray()
}

# Run directly -> print. Dot-sourced -> just define the function. $MyInvocation.InvocationName is
# '.' when dot-sourced, which is the standard way to tell the two apart.
if ($MyInvocation.InvocationName -ne '.') {
  $f = @(Get-HygieneFindings)
  if ($f.Count -eq 0) { Write-Host 'HYGIENE: clean' -ForegroundColor Green; exit 0 }
  foreach ($x in $f) { Write-Host "  ! $x" -ForegroundColor Yellow }
  Write-Host "HYGIENE: $($f.Count) finding(s)" -ForegroundColor Yellow
  exit 1
}
