<#
Which OEM is this machine, and what do that OEM's updates look like on the paths SunUp uses?

WHY THIS IS A TABLE AND NOT AN `if ($manufacturer -eq 'Dell')`
--------------------------------------------------------------
Win32_ComputerSystem.Manufacturer is not the brand you would guess. Measured on caldera:

    Manufacturer : 'Alienware'
    SystemFamily : 'Alienware'
    BIOS vendor  : 'Alienware'

Not "Dell Inc." anywhere — so the obvious `-match 'Dell'` misses a Dell outright. Vendors also
rebrand (Toshiba -> Dynabook), sub-brand (Lenovo/ThinkPad, HP/Compaq) and disagree with themselves
across the three fields, which is why detection matches a PATTERN against all three joined rather
than testing one field for equality.

WHAT THE PROFILE CARRIES
------------------------
Not "how to run this vendor's updater" — deliberately. v0.14.0 removed the Dell Command Update
integration because in 34 runs it delivered nothing while carrying the most security-sensitive code
in the project, and a generic version of that would multiply the problem across vendors we cannot
test. What is left is the part that matters and is testable: the patterns that identify an OEM's
updates on the two paths that DO deliver here —

  wuTitle : Windows Update publishes OEM driver/firmware with the publisher in the title
            ("Dell Inc. - Firmware - 1.2.4"), which PSWindowsUpdate can exclude via -NotTitle.
  winget  : OEM tools and utilities carry the publisher as an id prefix (Dell.CommandUpdate,
            Lenovo.Vantage), which winget's exclude pattern can match.

So `vendorUpdates: "block"` means "do not let this machine's OEM push driver, firmware or utility
updates through Windows Update or winget" — enforced on whatever OEM the box turns out to be,
without anybody hand-maintaining a regex per machine.

Adding a vendor is one row. Keep `match` anchored enough not to catch unrelated names (bare 'hp'
would match plenty), and keep `wuTitle` publisher-shaped rather than a bare brand word.

ANCHOR THE PATTERNS. `wuTitle` and `winget` are tested with `-match` against update titles and
package ids/names, so an unanchored brand word matches anything CONTAINING it — and the result is a
legitimate update silently classified as OEM junk and skipped. Two real examples, both caught in
review before they shipped:

    winget  'HP\.'      matches  PHP.PHP.8.4                 -> PHP upgrades skipped on any HP
    wuTitle 'Framework' matches  ".NET Framework 4.8 update" -> .NET updates skipped on a Framework

Publishers lead the string in both worlds (winget ids are `Publisher.Product`; WU titles read
"Dell Inc. - Firmware - 1.2.4"), so every alternative below is anchored with ^ and the collisions
cannot occur. Same reason the name forms carry a trailing space: '^HP ' matches "HP Support
Assistant" without matching "HPE".
#>

$script:SunUpVendorProfiles = @(
  [pscustomobject]@{ name = 'Dell';      match = 'dell|alienware';             wuTitle = '^Dell|^Alienware';           winget = '^Dell\.|^Dell |^Alienware' }
  [pscustomobject]@{ name = 'Lenovo';    match = 'lenovo|thinkpad|think';      wuTitle = '^Lenovo';                    winget = '^Lenovo' }
  [pscustomobject]@{ name = 'HP';        match = 'hewlett|\bhp\b|compaq';      wuTitle = '^HP Inc\.|^Hewlett|^HP ';    winget = '^HP\.|^HP |^Hewlett' }
  [pscustomobject]@{ name = 'ASUS';      match = 'asus';                       wuTitle = '^ASUS';                      winget = '^ASUS' }
  [pscustomobject]@{ name = 'Acer';      match = 'acer';                       wuTitle = '^Acer';                      winget = '^Acer' }
  [pscustomobject]@{ name = 'MSI';       match = 'micro-star|\bmsi\b';         wuTitle = '^MSI|^Micro-Star';           winget = '^MSI\.|^Micro-Star' }
  [pscustomobject]@{ name = 'Surface';   match = 'microsoft.*surface|surface'; wuTitle = '^Surface|^Microsoft.*Surface'; winget = '^Microsoft\.Surface|^Surface' }
  [pscustomobject]@{ name = 'Samsung';   match = 'samsung';                    wuTitle = '^Samsung';                   winget = '^Samsung' }
  [pscustomobject]@{ name = 'Framework'; match = 'framework';                  wuTitle = '^Framework';                 winget = '^Framework' }
  [pscustomobject]@{ name = 'Gigabyte';  match = 'gigabyte';                   wuTitle = '^GIGABYTE';                  winget = '^GIGABYTE' }
  [pscustomobject]@{ name = 'Razer';     match = 'razer';                      wuTitle = '^Razer';                     winget = '^Razer' }
  [pscustomobject]@{ name = 'Dynabook';  match = 'toshiba|dynabook';           wuTitle = '^TOSHIBA|^Dynabook';         winget = '^TOSHIBA|^Dynabook' }
)

# Returns the matching profile, or $null when the OEM is not one we have a profile for. Callers must
# treat $null as "cannot enforce" and SAY so rather than silently applying nothing — an unrecognized
# manufacturer is exactly when a user who asked for blocking is most likely to be surprised.
# Parameters are explicit so this is testable without the hardware; omitted, they come from CIM.
function Get-SystemVendor {
  param([string]$Manufacturer, [string]$Family, [string]$BiosVendor)
  if (-not $PSBoundParameters.ContainsKey('Manufacturer')) {
    # Queried INDEPENDENTLY. Sharing one try/catch meant a transient Win32_BIOS failure discarded an
    # already-retrieved Manufacturer and returned $null — so `block` would quietly enforce nothing on
    # a machine that had just said "Dell Inc." Whatever is retrievable is used; the BIOS vendor is
    # supplementary (it is what identifies this box, but plenty of machines need only the first two).
    try {
      $cs           = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
      $Manufacturer = "$($cs.Manufacturer)"
      $Family       = "$($cs.SystemFamily)"
    } catch { }
    try { $BiosVendor = "$((Get-CimInstance Win32_BIOS -ErrorAction Stop).Manufacturer)" } catch { }
  }
  # All three fields together: this box says 'Alienware' in every one of them and 'Dell' in none,
  # while other machines put the useful string in only one.
  $hay = (@($Manufacturer, $Family, $BiosVendor) | Where-Object { "$_".Trim() }) -join ' '
  if (-not $hay) { return $null }
  foreach ($p in $script:SunUpVendorProfiles) {
    if ($hay -match $p.match) { return $p }
  }
  $null
}
