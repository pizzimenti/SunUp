# WuPolicy.ps1 — the Windows Update policy SunUp's design depends on, as code rather than as prose.
#
# WHY THIS FILE EXISTS
# On 2026-08-12 this machine's Windows Update policy was changed by hand, as part of v0.17.0, to stop
# Windows installing updates behind SunUp's back. The change was real, load-bearing, and recorded in
# exactly two places: a paragraph of README and a PR body. It appeared in no diff. Install.ps1
# neither set it nor checked it.
#
# That cost twice over. On a fresh box the policy is simply absent, so the deployed product behaves
# differently from the one it was tested on and nothing says so. And on THIS box the policy produced
# a Windows toast -- "Updates are available / Required updates need to be installed / Your
# organization manages your update settings" -- which reads as a SunUp malfunction, was investigated
# on 2026-08-22 as a missed reboot signal, and was neither. Machine state that the repo cannot see is
# machine state nobody can reason about. So it lives here now, is asserted by Install.ps1, reported
# by -Mode Status, reverted by Uninstall.ps1, and pinned by the suite.
#
# WHAT THE POLICY IS FOR
# SunUp installs Windows updates itself (Comp-WindowsUpdate, via PSWindowsUpdate). For that to mean
# anything, Windows must not also be installing them on its own schedule. AUOptions=3 -- "auto
# download and notify for install" -- is how you say that: Windows keeps delivering everything and
# stops short of installing it.
#
# The durable reason is SELECTIVITY, not ordering, and this is worth stating plainly because the
# ordering argument no longer holds on its own. v0.17.0 justified the policy by pointing at the
# duplicate install of 2026-08-12 -- but that failure is now fixed in code, at the $skipWuForPending
# pre-flight in SunUp.ps1, which skips the Windows Update pass whenever a servicing restart is
# already outstanding. A future reader comparing the two could reasonably conclude the policy is
# redundant belt-and-braces and delete it.
#
# It is not redundant. `windowsUpdate.notTitle` lets SunUp say "everything EXCEPT NVIDIA", and the
# NVIDIA pin is enforced on the vendor path too (v0.11.0) because it matters on this hardware.
# Windows Update has no per-title exclusion mechanism at all -- the closest thing,
# ExcludeWUDriversInQualityUpdate, is all-or-nothing on drivers. A capability the other system cannot
# express is a real division of labour; a scheduling preference is just a race that can be lost.
#
# WHY THE NOTIFICATION HALF
# AUOptions=3 has a second clause, and its name is the giveaway: "notify for install". Suppressing
# Windows' installs necessarily switches on Windows' nagging, because "tell a human to press Install"
# is the only other thing Windows Update is permitted to do. There is no AUOptions value meaning
# "download it, do not install it, and stay quiet" -- from Microsoft's side, a downloaded-but-
# uninstalled update is an open hole somebody must be told about.
#
# The sanctioned way to say "a management layer owns updates on this box" is the Windows Update for
# Business policy UpdateNotificationLevel, which exists precisely so that a fleet running WSUS/Intune
# does not nag its users about work their management tool is already doing. SunUp is that management
# layer, population one. Setting it is not muting an inconvenient message: it is completing a claim
# the machine was already making. Writing ANY value under this branch is what makes Windows display
# "Your organization manages your update settings" -- so v0.17.0 had already asserted ownership and
# then left the nagging half switched on.
#
# LEVEL 1, NOT 2, DELIBERATELY. Level 2 would suppress restart warnings as well. SunUp owns restart
# messaging and does it better -- the toast, the deferral, the live-session stand-down of v0.18.0 --
# but a Windows restart warning is an INDEPENDENT backstop for the case where SunUp itself is broken,
# not running, or reporting clean while doing nothing. That is not a hypothetical failure mode for
# this project: v0.13.1 is "the Dell path was dead for four days, reporting clean". Keep the second
# opinion; silence only the half that duplicates work SunUp is genuinely doing.

# The policy branch. Any value under it flips Windows into "managed by your organization" -- which is
# why a standalone box with no domain, no Entra join and no MDM still shows that wording.
$script:SunUpWuPolicyRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:SunUpWuPolicyAu   = "$script:SunUpWuPolicyRoot\AU"

# The four values, with the reason each one is here. `scope` is which key it lives under.
# Nothing outside this table decides what the policy is -- Install.ps1, Uninstall.ps1, Status and the
# test suite all read it, so the policy has exactly one definition.
$script:SunUpWuPolicyDesired = @(
  @{ name = 'NoAutoUpdate'; scope = 'au'; value = 0
     why  = 'Windows Update stays ON and keeps downloading; only the install step is deferred to SunUp' }
  @{ name = 'AUOptions'; scope = 'au'; value = 3
     why  = 'download but do not install -- SunUp owns install timing, and with it the notTitle exclusions' }
  @{ name = 'SetUpdateNotificationLevel'; scope = 'root'; value = 1
     why  = 'enables the notification-level policy below (the WUfB knob is two values, not one)' }
  @{ name = 'UpdateNotificationLevel'; scope = 'root'; value = 1
     why  = 'suppress "updates are available" nagging, KEEP restart warnings as a backstop' }
)

function Get-SunUpWuPolicyKeyPath {
  param([string]$Scope)
  if ($Scope -eq 'au') { $script:SunUpWuPolicyAu } else { $script:SunUpWuPolicyRoot }
}

# Read the four values as a plain name -> value hashtable. Absent reads as $null, and an unreadable
# hive reads as $null too: this is advisory reporting, never a reason to fail a run.
function Get-SunUpWuPolicyValues {
  $out = @{}
  foreach ($d in $script:SunUpWuPolicyDesired) {
    $path = Get-SunUpWuPolicyKeyPath $d.scope
    $v = $null
    try {
      $p = Get-ItemProperty -Path $path -Name $d.name -ErrorAction Stop
      $v = $p.$($d.name)
    } catch { $v = $null }
    $out[$d.name] = $v
  }
  $out
}

# Classify the policy into something a human can act on.
#
# -Values exists so the classification can be tested without touching HKLM -- the suite's contract is
# that it is safe to run anywhere and touches nothing outside its own folder, and a test that had to
# write real Windows Update policy to assert anything would be a test nobody dares run. Omit it and
# the live registry is read.
#
# Returns:
#   OwnsInstalls  [bool]    SunUp, not Windows, decides when Windows updates install
#   Quiet         [bool]    Windows' "updates are available" nagging is suppressed
#   Summary       [string]  one line for -Mode Status
#   Drift         [string[]] what differs from desired, in the imperative -- each line is a fix
function Get-SunUpWuPolicyState {
  param([hashtable]$Values)
  if (-not $PSBoundParameters.ContainsKey('Values')) { $Values = Get-SunUpWuPolicyValues }

  $drift = [System.Collections.Generic.List[string]]::new()
  foreach ($d in $script:SunUpWuPolicyDesired) {
    $have = $Values[$d.name]
    if ($null -eq $have) {
      $drift.Add("$($d.name) is not set (want $($d.value)) — $($d.why)")
    } elseif ([int]$have -ne [int]$d.value) {
      $drift.Add("$($d.name) is $have (want $($d.value)) — $($d.why)")
    }
  }

  $noAuto  = $Values['NoAutoUpdate']
  $auOpt   = $Values['AUOptions']
  $setLvl  = $Values['SetUpdateNotificationLevel']
  $lvl     = $Values['UpdateNotificationLevel']

  # NoAutoUpdate=1 is NOT a stricter version of what SunUp wants -- it disables Windows Update
  # wholesale, downloads included, which starves the very pass SunUp runs. It is the one drift worth
  # calling dangerous rather than merely wrong.
  $updatesOff = ($null -ne $noAuto) -and ([int]$noAuto -eq 1)
  if ($updatesOff) {
    $drift.Add('NoAutoUpdate=1 turns Windows Update OFF entirely — SunUp cannot install what Windows never downloads')
  }

  $ownsInstalls = (-not $updatesOff) -and ($null -ne $auOpt) -and ([int]$auOpt -eq 3)
  # -in @(1,2) with an explicit array: the bare `-in 1, 2` form is a precedence trap.
  $quiet        = ($null -ne $setLvl) -and ([int]$setLvl -eq 1) -and ($null -ne $lvl) -and ([int]$lvl -in @(1, 2))

  $summary =
    if ($updatesOff)        { 'Windows Update is DISABLED by policy — nothing will download' }
    elseif ($ownsInstalls -and $quiet)  { 'SunUp owns install timing; Windows notifications suppressed' }
    elseif ($ownsInstalls)  { 'SunUp owns install timing; Windows will still nag about pending installs' }
    elseif ($drift.Count -eq 0) { 'as configured' }
    else                    { 'Windows may install updates on its own schedule — notTitle exclusions are not enforced' }

  [pscustomobject]@{
    OwnsInstalls = $ownsInstalls
    Quiet        = $quiet
    Summary      = $summary
    Drift        = @($drift)
    Values       = $Values
  }
}

# Assert the policy. Called by Install.ps1, so a fresh box gets the behaviour the product was
# designed and tested against instead of silently getting Windows' defaults.
# Returns the lines describing what it did, for the installer to print.
function Set-SunUpWuPolicy {
  $said = [System.Collections.Generic.List[string]]::new()
  foreach ($d in $script:SunUpWuPolicyDesired) {
    $path = Get-SunUpWuPolicyKeyPath $d.scope
    try {
      if (-not (Test-Path $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
      $before = try { (Get-ItemProperty -Path $path -Name $d.name -ErrorAction Stop).$($d.name) } catch { $null }
      New-ItemProperty -Path $path -Name $d.name -Value $d.value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
      if ($null -eq $before)            { $said.Add("  set $($d.name)=$($d.value)  ($($d.why))") }
      elseif ([int]$before -ne [int]$d.value) { $said.Add("  changed $($d.name) $before -> $($d.value)  ($($d.why))") }
    } catch {
      $said.Add("  FAILED to set $($d.name): $_")
    }
  }
  if ($said.Count -eq 0) { $said.Add('  already as desired — no change') }
  $said
}

# Revert it. Uninstall.ps1 calls this, and that is not tidiness -- it is the difference between a
# clean removal and a box that quietly stops patching itself.
#
# AUOptions=3 means "Windows downloads but never installs". While SunUp is present, SunUp is the
# thing that installs. Remove SunUp and leave the policy, and NOTHING installs Windows updates: the
# machine keeps downloading forever, reports no errors, shows a green Windows Update page, and rots.
# An uninstaller that leaves that behind is worse than one that never set the policy at all.
#
# Only the values in the table are removed, and each key is deleted only if it is left empty --
# someone else's policy under the same branch (a real GPO, a management agent) is not ours to take.
function Remove-SunUpWuPolicy {
  $said = [System.Collections.Generic.List[string]]::new()
  foreach ($d in $script:SunUpWuPolicyDesired) {
    $path = Get-SunUpWuPolicyKeyPath $d.scope
    if (-not (Test-Path $path)) { continue }
    try {
      $have = try { (Get-ItemProperty -Path $path -Name $d.name -ErrorAction Stop).$($d.name) } catch { $null }
      if ($null -ne $have) {
        Remove-ItemProperty -Path $path -Name $d.name -Force -ErrorAction Stop
        $said.Add("  removed $($d.name)")
      }
    } catch { $said.Add("  could not remove $($d.name): $_") }
  }
  # Empty keys only, deepest first. A leftover value we did not write means the branch is shared.
  foreach ($path in @($script:SunUpWuPolicyAu, $script:SunUpWuPolicyRoot)) {
    if (-not (Test-Path $path)) { continue }
    try {
      $props = @((Get-Item $path -ErrorAction Stop).Property)
      $subs  = @(Get-ChildItem $path -ErrorAction SilentlyContinue)
      if ($props.Count -eq 0 -and $subs.Count -eq 0) {
        Remove-Item $path -Force -ErrorAction Stop
        $said.Add("  removed empty key $path")
      }
    } catch {}
  }
  if ($said.Count -eq 0) { $said.Add('  no SunUp update policy was set — nothing to revert') }
  $said
}
