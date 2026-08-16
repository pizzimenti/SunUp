# Changelog

All notable changes to SunUp (formerly AutoUpdate). Format: [Keep a Changelog](https://keepachangelog.com/).

## [0.18.0] - 2026-08-15

### Added — unattended restarts stand down for blocker processes

On 2026-08-15 08:01 the self-host pass upgraded PowerShell 7.6.5 while two live Claude Code
sessions sat in terminal pwsh tabs; Restart Manager closed both mid-conversation. No reboot was
even involved — but the incident made the adjacent gap obvious: under `rebootPolicy=ifRequired`
with a user logged in, the only thing between a required reboot and those same sessions was a
300-second countdown that nobody away from the desk would ever see.

A restart now distinguishes *approved* from *merely unopposed*. `Get-RebootBlockers`
(RebootState.ps1, shared; config key `rebootBlockProcesses`, default `claude`) is consulted at
three places:

- **the engine's reboot decision** — a policy-allowed reboot with a blocker running becomes
  `rebootAction=deferred-blocker`: no countdown is armed, event 2012 is written, and a
  `[SUNUP]` alert tells the human a restart is waiting on them;
- **the restart toast at countdown expiry** — the moment of truth re-checks, because the
  engine's check ran minutes earlier and a session may have started since. On a hit the
  countdown toast is replaced by a plain "Restart deferred" toast (no Restart button: the
  process showing it is about to exit, so the button's command file would have no reader);
- **the summary dialog at countdown expiry** — same stand-down, same alert line.

`user-clicked` restarts skip all three checks on purpose: the human pressing "Restart now"
owns the sessions the list exists to protect. Known limit: a deferred *run-signal* reboot
(one that sets no OS flag) survives only as the alert and event — the stale-pending watchdog
tracks OS-flagged states only.

### Added — SelfHost defers self-hosting upgrades while a blocker runs

Disabling Restart Manager from inside the pass measurably does not work (v0.11.0, removed
v0.12.0), so the only real protection for processes RM would close is to not run the installer
while they exist. After its engine/user-pass waits, `SelfHost.ps1` now checks the blocker list
and, on a hit, records the whole handoff as **deferred** (`selfhost.json` gains a `deferred`
field; ok=0, failed=0), writes event 2022 and a `[SUNUP]` alert, and exits 0. The engine hands
the packages off again next run. Deferred is not failed: yesterday's "0 ok, 1 failed" toast
for an upgrade that was going to kill two sessions was wrong twice over.

The blocker default is duplicated in SelfHost by design (the script is self-contained,
5.1-only, ASCII-only); the comment at both sites says to keep them in sync by hand.

### Fixed — the mutex-race loser no longer reports the peer's success as its own failure

Both scopes' handoffs can carry `Microsoft.PowerShell`. On 2026-08-15 the user pass won the
winget lock and installed 7.6.5 (exit 0, 129s); the SYSTEM pass then ran, found nothing to do,
got `0x8A15002B` ("No applicable update found"), retried without `--custom`, got it again, and
recorded **FAILED** — event 2021, a failure toast, and a `selfhost.log` that says an upgrade
failed on the very run where it succeeded. `0x8A15002B` is now a benign no-op ("already up to
date -- a peer pass likely upgraded it first"): counted as ok, never retried, never alerted.

Note recorded while verifying the fix: PowerShell parses 32-bit hex literals by bit pattern
into negative Int32s (`0x8A150077` *is* `-1978335113`), so the existing `-contains
$LASTEXITCODE` comparisons were always correct. Do not "fix" them with unsigned conversions.

### Fixed — SelfHost's ALERTS.md lines now use the shared format

`SelfHost.ps1` wrote `- <ts> SunUp: <msg>` — un-bolded, un-categorised — so SysSentry's parser
filed it under the fallback category and the toast said "SysSentry: ALERT" with no hint of the
source. It now writes the same `- **<ts>** [SUNUP] <msg>` shape as the engine.

## [0.17.1] - 2026-08-12

### Fixed — the installer force-killed any PowerShell that merely mentioned the tray script

`Install.ps1` restarts the tray so a new build takes over, and to get past the tray's single-instance
mutex it first kills the old one:

```powershell
Where-Object { $_.CommandLine -like '*SunUp-Tray.ps1*' } | ForEach-Object { Stop-Process -Force ... }
```

That is a substring match on a **bare filename**, anywhere in the command line — not a match on the
process actually running the script. Any elevated `pwsh` that so much as named the file qualified:
an editor, a log tail, a script listing the deployed files.

Measured while deploying v0.17.0. A shell verifying the deployment listed the bin filenames to
hash-compare them against the repo, which put `SunUp-Tray.ps1` in its command line. `Install.ps1`
killed it — and since it happened to be `Install.ps1`'s own caller, the install died with it at exit
255, **after** registering every task but **before** `Start-ScheduledTask`. Every task was
registered, every file was copied, the version was correct, and the tray was left stopped. It
looked like a clean install.

Both kill filters now anchor on the deployed path after `-File`, and neither will kill the process
doing the killing. `Uninstall.ps1` was already narrower — it builds full paths rather than bare
filenames — but shares the class and is tightened to the same shape so the two read alike.

The regression guard checks the source shape *and* exercises the pattern against real command lines:
the actual tray process must still match (quoted and unquoted `-File`), and a shell that merely
hashes or names that path must not. Verified to fail five ways against the unfixed code.

- Suite is 379 checks (was 370).

## [0.17.0] - 2026-08-12

### Fixed — the summary dialog restarted this box three times in seventy minutes

`notify\reboot.log`, this morning:

```
2026-08-12T08:09:53  Restart-Computer -Force   <- correct: 300s after the 08:00 run
2026-08-12T09:03:18  Restart-Computer -Force   <- wrong
2026-08-12T09:09:45  Restart-Computer -Force   <- wrong
```

Each of the last two fired about five minutes after a logon. `Show-UpdateDialog.ps1` could not tell
that the machine had already restarted, so the `SunUp-Notify` logon trigger armed a fresh countdown
every time the user signed in, and the countdown did what it was built to do.

The cause was one line, and it is the same class of bug v0.13.2 already fixed once:

```powershell
$runEnd = [datetime]::Parse($data.runEndUtc, $null, [DateTimeStyles]::RoundtripKind).ToUniversalTime()
```

`$data` came from `ConvertFrom-Json`, which had **already** deserialized `runEndUtc` into a
`[datetime]` with `Kind=Utc`. Passing a `DateTime` to `[datetime]::Parse` stringifies it through the
current culture first, and that drops the `Z`:

```
runEndUtc                    2026-08-12T15:04:43.8905354Z    (Kind=Utc)
stringified for Parse        "08/12/2026 15:04:43"           <- the Z is gone
reparsed                     Kind=Unspecified
.ToUniversalTime()           2026-08-12T22:04:43Z            <- +7h, permanently in the future
```

So `$boot -gt $runEnd` could never be true. Note the failure is sign-dependent: west of UTC the
timestamp moves forward and the box restarts repeatedly; east of UTC the same line moves it backward
and the dialog would have **silently skipped every restart it was supposed to warn about**. Same
line, opposite symptom, decided by geography.

`RebootState.ps1` had the guard that prevents this all along — `if ($Utc -is [datetime])` in
`Test-BootedSince` — and the tray, which used it, was right the whole time. The dialog was the one
consumer that never dot-sourced the shared file. That is the actual defect: the detection *source*
has now been rewritten four times (v0.3.1 per-run signal, v0.4.0 registry `Test-PendingReboot`,
v0.8.0 the `rebootPolicy` switch, v0.16.0 the classified verdict), and every single fix landed in
the engine while the consumers drifted.

### Fixed — SunUp reinstalled updates Windows had already installed, and that is what started it

The loop above repeated the restart. This is what caused the first one, and it was hiding in the
same blind spot.

```
08-11 21:24  MoUpdateOrchestrator     2026-08 .NET Framework Security Update (KB5120708)
08-11 21:45  MoUpdateOrchestrator     2026-08 Security Update (KB5121003) (26200.9168)
08-12 08:03  <<PROCESS>>: pwsh.exe    2026-08 .NET Framework Security Update (KB5120708)   <- SunUp, again
08-12 08:04  <<PROCESS>>: pwsh.exe    2026-08 Security Update (KB5121003) (26200.9168)     <- SunUp, again
```

Windows Update's own orchestrator installed both the previous evening and left the box waiting. The
CBS Setup log timestamps the hold at **21:45:40**, ten hours before the run:

```
08-11 21:45:40  A reboot is necessary before package KB5121003 can be changed to the Installed state.
08-12 08:04:08  Initiating changes for package KB5121003. Current state is Installed. Target state is Installed.
```

The WU agent reports an installed-but-pending-restart update as **not installed**, so it offers it
again, and `-IgnoreReboot` lets us take the offer. `result.json` recorded "6 installed, 0 failed
(6 offered)" — two KBs, offered three times each, all of them finished work.

It cost 242 seconds. What it cost that actually mattered was `rebootRequiredByRun`, which under the
default `ifRequired` policy is the **only** thing that triggers a restart — a pre-existing pending
state alone never does. The 08-11 run proves it: `rebootPending=True`, `rebootRequiredByRun=False`,
`rebootAction=suppressed`, no restart. So redoing finished work is what escalated "pending, nag in
three days" into "restarting in five minutes".

`Get-RebootState` is now asked **before** the components run, not only after. If a servicing signal
is already outstanding, the Windows Update pass is skipped: the updates are installed and waiting to
be committed, and the engine's job at that point is to get the box restarted, not to install more on
top. That is Windows' own model. Two rules keep it honest:

- **The skip still requests the restart**, so it is self-limiting — it lasts one cycle, not forever.
- **It never applies under `rebootPolicy: never`**, where no restart is coming and skipping would
  mean the updates are never installed at all. Redundant work beats no work.

Only *servicing* signals qualify (`cbs`, `cbsInProgress`, `cbsPackages`, `windowsUpdate`,
`wuPostReboot`). A queued temp-file deletion must never suppress the update pass — that is the
false positive v0.16.0 exists to disarm, and it is exactly what the 08-11 run's pending state was.

Separately, and because the same run reported installing **93 GB**: Windows Update rows no longer
carry a size. PSWindowsUpdate's `Size` is the WUA `MaxDownloadSize`, a worst-case figure for the
entire bundle rather than what this machine transferred — measured at 93,184 MB for the August
cumulative and 1,489 MB for a Defender signature update roughly a tenth that size. An honest blank
beats a confident wrong number; the raw value is kept in `meta.maxDownloadMB` for forensics, and
winget rows still show a real size because those are HEAD-probed from the actual download.

### Changed — the restart decision rests on boot identity, not on comparing two clocks

Timestamp hygiene alone would have fixed the instance and left the class, so the decision no longer
depends on a timestamp at all. `notify\restart-state.json` records that a restart was **issued**, for
which run, and **which boot the machine was on** when it was issued. The test is then:

> A restart is complete iff `Get-BootEpoch() -ne $rec.bootAtRequestEpoch`.

`-ne`, not `-gt`. Both sides are readings of the same counter, taken by SunUp, as integers: no parse,
no culture, no offset, no DST, no second clock to disagree. Even with every timestamp on disk
mangled, that comparison still answers correctly — which is the point.

Two rules come with it:

- **Record first, restart second, and if the record cannot be written, do not restart.** A restart
  nothing can prove happened is one the next logon re-arms a countdown for. Refusing costs one
  postponed update; restarting unrecorded costs the user their work, repeatedly.
- **A payload with no `runStamp` may never arm a countdown.** One written by v0.16.0 or earlier
  cannot be tied to any record, so nothing can prove a restart was not already issued for it. Showing
  a stale summary costs a day of the watchdog nag; arming a countdown on an unprovable payload *is*
  the incident. This is also the upgrade path, and it lasts exactly one run cycle.

A third display state falls out of the record: **`awaitingRestart`** — issued, but the machine is
still on the same boot. An aborted or blocked shutdown (`shutdown /a`, a driver veto, an app refusing
to close). That state was real before and completely invisible: it presented as "restart needed" and
re-armed. It now says a restart was requested and did not happen, and offers a manual button only.
Nothing automatic asks a machine to restart twice.

### Added — a "Restarting Soon" toast that says what and why, with Restart now / Pause

`Show-RestartToast.ps1` replaces the WPF countdown as the normal path:

- header **Restarting Soon**, the update that is asking (named, not "an update"), and a smaller line
  saying what is still exposed until the restart;
- a live countdown that updates **in place** — `<progress>` fields are data-bound and rewritten by
  `ToastNotifier.Update()`, so it does not re-pop once a second;
- **[Restart now]** and **[Pause]**, where Pause toggles to **Unpause** and holds the countdown
  indefinitely. There is no auto-resume and no cap: if you paused it, you meant it.

Windows PowerShell 5.1, not pwsh 7, because the WinRT toast APIs have no .NET Core projection — the
same carve-out `SelfHost.ps1` makes for a different reason, with the same pure-ASCII constraint,
now enforced against the real 5.1 parser for `RebootState.ps1` too (it had ten em dashes and failed
with six errors).

Three things had to be measured rather than assumed, all on 2026-08-12:

- `NotificationData.Values` comes back as a bare `System.__ComObject` under 5.1. Indexing throws,
  `.Insert()` does not exist, and it will not cast to `IDictionary[string,string]`. The only route
  that works is handing the whole dictionary to the **constructor**, and the unary comma in
  `-ArgumentList (,$d)` is load-bearing.
- `scenario="reminder"` is what keeps the toast on screen; a default toast auto-dismisses in about
  five seconds, which is useless for something you are being asked to act on.
- Buttons activate by **protocol** (`Invoke-ToastAction.ps1`, the `sunup:` scheme). Foreground and
  background activation both need a registered COM CLSID an unpackaged script cannot provide, and
  `system` only dismisses.

The dialog keeps its countdown as the fallback for when a toast cannot be shown, and the toast starts
it on every give-up path — the process that tried to show a toast is the only one that knows whether
one appeared. The dialog stands down while the toast is running, so one run can never produce two
countdowns.

Do Not Disturb is asserted off rather than worked around, per the machine's owner: the documented
levers (`NOC_GLOBAL_SETTING_TOASTS_ENABLED`, the per-app `AllowUrgentNotifications`, the
`NoQuietHours` policy) are set at install and re-asserted at toast time. The Windows 11 DND toggle
itself lives in an undocumented CloudStore blob, which is **detected and reported**, never written.

### Added — the post-reboot summary says when it restarted and when it came back

`Restarted to finish updates.` gave no way to tell a restart you slept through from the third one in
an hour. It now reads, in local time:

```
Restarted to finish updates.  restarted 9:09:45 AM, back up 9:10:15 AM (down 30s)
```

Executed time comes from the record; the return time is `LastBootUpTime` read live at display time
(already `Kind=Local`, so no conversion — which is the point); the gap between them is the outage.

### Added — the notification can finally explain itself

`RebootState.ps1`'s full-sentence `Reasons` existed since v0.16.0 but only ever reached `result.json`,
and `Comp-WindowsUpdate` read `Description`, `KBArticleIDs`, `MoreInfoUrls`, `MsrcSeverity` and
`Categories` off every update and threw them all away. Both now reach the payload, alongside a plain
-language consequence table keyed on the reboot sources — written to a rule: no CVE numbers, no KB
numbers, no "servicing stack", say what is still running or still exposed.

Accuracy over drama: a Windows security update almost never makes a feature *unavailable* until you
restart, it leaves the old vulnerable code running. Claiming otherwise would be easier to write and
false, and a notification that overstates its case once is ignored forever after.

One footnote, because it is the kind of thing that only shows up when you run it: the duplicate-row
collapse rebuilds every row from a fresh literal, so it silently dropped the new `meta` field on any
run with two or more updates — precisely the runs where the notification most needs to say what it
is restarting for. Caught by deploying v0.17.0 and watching the first live run emit no metadata at
all. Same shape as the `$Name` bug already documented in that same block, for the same reason.

The `notify.explain` policy is read by the toast **from `config.json` directly**, which is the
admin-owned file that owns it. It briefly travelled in the notify payload instead, justified in a
comment as "the toast runs non-elevated and config.json is admin-only" — a security review of this
branch established that both halves were false. Every interactive task is registered
`RunLevel Highest` and measures High integrity, and `config.json` is world-*readable*
(`Users:RX`), merely admin-*writable*. So a switch deciding whether to execute an external program
had been relocated out of a file only an administrator can change and into `notify\`, which is
granted Modify to the interactive user — for no benefit, since the reader could always open the
original. Nothing could have escalated through it (writer and reader are the same account, with no
privilege boundary between them), but "the engine tells the toast what it is allowed to do" is not
a sentence a user-writable file gets to say. Absent, corrupt or unreadable config now reads as
`off`, so every failure mode disables the feature rather than enabling it.

The same review found the "non-elevated" claim repeated in five other comments across
`Install.ps1`, `Show-UpdateDialog.ps1`, `RebootState.ps1` and `SunUp.ps1`. All corrected: these
tasks hold an administrator token, and it matters that the code says so, because anything they
trust they trust with that token.

Optional on top of that, `notify.explain = auto` (default `off`) asks Claude for the specific version
in plain words, cached per KB in `notify\why-cache.json` so each update is researched once ever.
Bounded by a 30s timeout — 12.4s measured for a warm call, so the original 12s budget timed out every
time — and every failure path falls back to the table. A restart warning must never wait on a network
call, and it never blocks: enrichment runs only once a toast is definitely going up.

### Fixed — three more instances of the same timestamp class, found by looking for them

- `$nextCursor` carried the ingest cursor forward as `"$($stamp.ingestCursor)"`. That interpolates a
  `[datetime]` `ConvertFrom-Json` had already produced, writing culture text to disk; the next run
  read it as local and added the offset, putting the cursor **seven hours in the future** — where it
  would consume-unread every detached helper record written in that window, losing their upgrades and
  their reboot requests silently. `ConvertTo-UtcTime` now clamps a future timestamp, which self-heals
  a `lastrun.json` already damaged this way.
- `$pendingSince` degraded the same way on its first carry, turning a round-trippable field into a
  culture-dependent one.
- `processStartUtc` was written as `Z` and re-parsed by `Test-RunAlive` with no trailing
  `.ToUniversalTime()` — accidentally correct, and one edit away from declaring a live run dead.

The writer contract that prevents all of them: **SunUp never writes `Z` into its own JSON.**
`Get-SunUpTimestamp` emits local-with-offset, which round-trips correctly *even through the buggy
parse* — the only layer that makes an already-deployed, un-upgraded consumer right rather than seven
hours wrong. Restart-gating values are additionally stored as epoch integers, which nothing can
coerce into a date. And `[datetime]::Parse(` may now appear exactly once in the product, asserted by
the suite.

### Changed — `latest-updates.json` is published atomically, and `pendingShow` is serialized

The payload was written with bare `Set-Content`. A torn write still satisfies `Test-Path`, and the
dialog runs with `$ErrorActionPreference = 'Stop'`, so a truncated payload killed it before it drew
anything: no window, no error, no trace, just no summary. It now goes through `Publish-JsonFile`.
The three unlocked read-modify-write writers of that file (engine as SYSTEM, dialog, tray) now take
`Global\SunUp-Notify` and publish by rename.

Worth recording what the tray's **Show last summary** used to be able to do: with the payload still
saying `rebootRequired` and the dialog unable to tell the box had already restarted, one click armed
a fresh five-minute countdown and rebooted the machine. It is now inert.

### Tests

Suite is 370 checks (was 238), in two new sections:

- **[12] the restart loop** — the incident as a unit test, including the assertion that a `runEnd`
  seven hours in the future **cannot** re-arm a restart that a record says already happened; the
  migration guard; `awaitingRestart`; and — deliberately, so that "never re-arm" cannot pass by
  simply never arming — that a genuinely new `runStamp` still does. `Test-BootedSince` is exercised
  for the first time, over every shape `ConvertFrom-Json` can produce.
- **[13] the toast** — 5.1 parseability, XML well-formedness against an update title containing
  `&` and `<`, the button contract and the Pause/Unpause toggle, and that every give-up path hands
  the countdown back to the dialog.

Two of the new guards had to be written twice, which is worth noting because it is a trap in a
codebase that documents its bugs by quoting them: `-notmatch 'the old broken form'` matched the
comment explaining that the form is no longer used. Negative assertions now run against source with
comments stripped.

## [0.16.0] - 2026-08-11

### Fixed — `rebootPending` was true continuously for a week, on a box that had rebooted twice

`Test-PendingReboot` returned `$true` for **any** non-empty `PendingFileRenameOperations`. That
value is not a reboot signal. It is a work queue for `smss.exe` — "perform these file operations
before anything else loads" — and while Windows Update genuinely uses it to swap in-use system
files, *any* process can call `MoveFileEx(path, NULL, MOVEFILE_DELAY_UNTIL_REBOOT)` to have a file
it cannot unlink deleted at the next boot. The two intents are indistinguishable from the value's
mere existence, which is all the old check looked at.

Something on this box does the second thing constantly. Claude Code is a Bun-compiled standalone
binary, and a bundled native addon cannot be `dlopen`'d from inside the executable — so at load
time it is written out to `%TEMP%` under a content-hash name and immediately queued for
delete-on-boot, because a loaded DLL cannot unlink itself on Windows. A fresh entry appears within
minutes of every startup, and more accumulate as the day goes on:

```
*1\??\C:\Users\bradley\AppData\Local\Temp\.78eefce1f7f6b7d6-0.node   ->   (empty = delete at boot)
```

Every consequence was silent:

- `rebootPending` was `true` in every run's `result.json`, so the field meant nothing.
- The tray icon sat in its alert state permanently, so it signalled nothing.
- Under `rebootPolicy: "always"` the box would have been restarted on account of a temp file.
- The stale-reboot watchdog fired on **2026-08-04** and stayed latched. `pendingSince` reset only
  when a run observed the state *clear* — which quietly assumes a pending signal persists until a
  restart consumes it. A self-renewing signal breaks that assumption outright: re-armed ~2 minutes
  into each boot, with the engine running an hour later, no run ever caught it clear. So the
  tracker ratcheted backwards indefinitely, reporting a reboot "pending 7.0 days" on 08-11 across
  intervening restarts on **08-08** and **08-11** — and being once-only, the alert never repeated,
  never corrected itself, and gave no indication of what was supposedly holding.

The watchdog now also resets when the box has **booted since the last run**, using the
`$bootedSinceLastRun` predicate the handoff logic already computed a hundred lines earlier. A boot
satisfies every reboot outstanding before it, so anything still pending afterwards is by definition
new and is dated from the boot. The alert names the signals responsible.

### Added — `RebootState.ps1`: one classified detector, shared

Reboot detection was previously duplicated: the engine had a `Test-PendingReboot`, the tray had its
own copy, and both were wrong in the same way independently. There is now a single dot-sourced
implementation used by both (and by the tests), so the icon in the notification area and the
engine's restart decision cannot drift apart.

It returns a **verdict**, not a boolean — `Required`, `Sources`, `Labels`, `Reasons`, `Advisory` —
because a boolean could never explain itself. Signals are grouped by how far they can be trusted:

| Class | Signals |
|---|---|
| Authoritative | CBS `RebootPending` / `RebootInProgress` / `PackagesPending`, WU `RebootRequired` and `PostRebootReporting`, a queued machine rename, a staged domain join |
| Run signals | an MSI `3010` or winget restart exit code from this run, or carried from a detached helper — these set **no** OS flag anywhere |
| Classified | `PendingFileRenameOperations`, per entry |

`PendingFileRenameOperations` is parsed into real source/destination pairs (stripping the `\??\` NT
prefix, the `!` replace-existing marker and the `*N` source marker) and judged pair by pair:

- a rename **into** a destination is a file being put in place — servicing, so it counts;
- a delete-on-boot of a file under a temp directory is an application cleaning up, so it does not;
- anything else, including anything unparseable, **counts**. It fails open on purpose: a spurious
  sunset icon costs a glance, a missed servicing reboot leaves the box half-patched.

Temp directories are matched by pattern (`\Users\*\AppData\Local\Temp\`, `\Windows\Temp\`, …) rather
than against `$env:TEMP`, because the engine runs as SYSTEM — whose `TEMP` is `C:\Windows\TEMP` —
and the entries that matter are left by interactive users whose profiles it knows nothing about.

Dismissed signals are recorded rather than discarded: they appear in the run log, in `-Mode Status`
and in `result.json` as `rebootIgnored`, so a misclassification is visible instead of silent.

### Changed — the tray shows a **sunset** when a restart is needed, and says what is asking

The two icon states were both full suns separated by one shade of amber (`255,201,64` against
`255,170,0`) — a distinction that survives neither the 16px the notification area actually renders
at nor a light taskbar behind it. The alert state is now a **setting sun**: the disc clipped at a
horizon line, rays fanning upward only, amber falling to dusk orange down the face. The states now
differ in *shape*.

The tray also folds in the reboots SunUp itself caused. Those never reach the registry — an MSI
`3010` or a winget restart code lives in the run payload and nowhere else — so the one case where a
restart is certainly needed was precisely the case the old registry-only icon could not show. A
run-signalled restart is retired by an actual boot, mirroring the dialog's own pre/post test.

The tooltip now reads `Restart needed — Windows Update` instead of a bare "Reboot pending". With no
attribution there was no way to tell a real servicing hold from the false positive above.

### Changed — `-Mode Status` and `result.json` explain the verdict

`Status` prints the reasons beneath the verdict, and the signals it dismissed:

```
  Reboot now    : False
                    ~ ignored: 4 queued file deletion(s) under a temp directory — application
                      cleanup, not a restart requirement
```

`result.json` gains `rebootSources`, `rebootReasons` and `rebootIgnored` alongside the existing
`rebootPending` / `rebootRequiredByRun`. `rebootPolicy: "always"` now keys off the classified
verdict, which makes it a genuine policy choice rather than the blunt instrument it was.

## [0.15.1] - 2026-08-05

### Fixed — the dialog's history list was alphabetical by package, not newest-first

`Get-UpdateHistory` built its rows as `[ordered]` hashtables, and `Sort-Object -Property` does not
bind to dictionary *keys* — only to real properties like `Count`. Both of its sorts were silent
no-ops:

- The final `Sort-Object when -Descending` did nothing, so the list shipped in whatever order the
  collapse step left it — and `Group-Object` emits groups sorted by key, i.e. **alphabetical by
  `name|source`**. The dialog rendered ".NET → fzf → Git → … → winghostty" with dates interleaved.
- The collapse's inner `Sort-Object when | Select-Object -Last 1` ("keep the latest per package")
  actually meant "keep the last row in *file order*". Benign for the normal append-only path, but a
  detached result imported late could beat a newer row and pin a stale version in the list.

Rows are now `[pscustomobject]`, which property binding sees, so both sorts actually run. And they
sort on a new `stamp` field carrying the full `runStamp` (`yyyy-MM-dd_HHmmss`, falling back to the
date for pre-runStamp lines) rather than the date-only `when`: with dates alone, two same-day runs
tie and the stable sort degrades to file order again — the detached-import edge above in miniature.
`when` stays date-only for the dialog's When column; the extra payload field is ignored by the
dialog's name-based bindings. The list launches newest-first again.

## [0.15.0] - 2026-08-03

### Added — `vendorUpdates`, a generic OEM policy that detects the machine it is on

v0.14.0 removed a *Dell-specific* integration. This adds the generic thing that was actually wanted:
a single switch that keeps **this machine's OEM** — whichever one that turns out to be — from
pushing driver, firmware and utility updates through the paths SunUp uses.

```jsonc
"vendorUpdates": "allow"   // default: OEM updates arrive like any other
"vendorUpdates": "block"   // exclude this machine's OEM from Windows Update AND winget
```

On this box `block` resolves to:

```
WU  -NotTitle   : NVIDIA|^Dell|^Alienware
winget exclude  : …|^Dell\.|^Dell |^Alienware
log             : vendorUpdates=block — Dell updates excluded from Windows Update
                  (title ~ '^Dell|^Alienware') and winget (id ~ '^Dell\.|^Dell |^Alienware')
```

On a Lenovo the same config line resolves to Lenovo, on a Surface to Surface. Nothing is
hand-maintained per machine.

- **Detection is a pattern table, not an equality check, and that is not pedantry.** Measured here:
  `Manufacturer`, `SystemFamily` and the BIOS vendor **all report `Alienware`, and none report
  `Dell`** — so the obvious `-match 'Dell'` concludes "not a Dell" on an actual Dell and silently
  blocks nothing. `Get-SystemVendor` matches a pattern against all three fields joined. Profiles
  ship for Dell/Alienware, Lenovo, HP, ASUS, Acer, MSI, Surface, Samsung, Framework, Gigabyte,
  Razer and Toshiba/Dynabook; adding one is a single row in `VendorProfiles.ps1`.
- **It blocks the paths that actually deliver.** OEM firmware arrives through Windows Update titled
  with the publisher (`Dell Inc. - Firmware - 1.2.4`), and OEM utilities arrive through winget with
  the publisher as an id prefix (`Dell.CommandUpdate`, `Lenovo.Vantage`). Both are filtered.
- **Deliberately not "run the OEM's updater".** That is what v0.14.0 deleted after it delivered
  nothing in 34 runs while carrying the project's most security-sensitive code; a generic version
  would multiply that across vendors nobody can test.
- **A block that cannot be enforced is reported, never silent.** An OEM matching no profile, or a
  missing `VendorProfiles.ps1`, logs a WARN naming the manufacturer string — the case where a user
  who asked for blocking is most likely to be wrongly reassured.
- Policy is **shared with the user-scope pass**, like `excludePattern`: an OEM utility blocked on the
  machine pass would otherwise reinstall itself from HKCU. Both dot-source the same profile table so
  they cannot disagree about what "Dell" means.
- **Every pattern alternative is anchored (`^`)**, because these are `-match`ed against winget ids and
  WU titles: unanchored, `HP\.` matches `PHP.PHP.8.4` and `Framework` matches ".NET Framework 4.8
  update" — silently reclassifying a legitimate update as OEM junk and skipping it. Both were live
  until review; a test now asserts anchoring across the whole table, not just those two rows.
- Suite is 209 checks (was 169), including the Alienware-is-a-Dell case, nine manufacturer strings
  across vendors, unprofiled and empty-string machines, the PHP and .NET false positives, a
  regex-validity check on every profile row, and machines where only one CIM query succeeded.

## [0.14.0] - 2026-08-03

### Removed — the Dell Command Update integration, entirely

SunUp is now **hardware-agnostic**: every remaining component ships with Windows or with winget, so
it runs on any Windows box rather than on a Dell.

The Dell path was removed on evidence, not taste. Across **34 recorded runs over five weeks** it
installed **zero** updates:

| Source | Updates delivered |
|---|---|
| Defender | 22 |
| winget | 20 |
| Windows Update | 5 |
| winget (user scope) | 1 |
| **Dell** | **0** |

Every successful Dell run reported the same thing — *"no applicable driver/firmware updates; no BIOS
update"*. The machine is an Alienware 13 R3 whose BIOS (1.2.4) was **released 2018-04-22**; dcu-cli
reports nothing newer exists. The only update it ever found is a SupportAssist plugin of type
`Application`, which `dell.applyTypes` (`driver,firmware,utility`) excludes by design — so even its
one finding was out of scope.

Against that, the cost was substantial and concentrated in the riskiest code in the project:

- ~370 lines of the engine (`Comp-Dell`, `Split-DcuUpdates`, `ConvertTo-DcuCategory`,
  `Parse-DcuReport`, `Get-DcuReportDir`, `Protect-Directory`, `Test-PathHasReparsePoint`) and 50 of
  the 218 test checks.
- The **entire `C:\SunUp` staging apparatus** — DACL replacement, ownership seizure, reparse-point
  refusal, foreign-parent refusal, per-run subdirectories — existed *solely* because dcu-cli refuses
  to write its report into `C:\ProgramData`. That report decided which updates were allowed to
  install, which made it the most security-sensitive file SunUp touched.
- Four of the fifteen defects found in the v0.13.0 review were Dell's, including the one that left
  the whole path dead for four days while reporting clean; roughly a third of the twenty findings
  from the review rounds that followed were about that staging directory.

It also **removes a class of risk rather than defending against it**: the Dell path was the only
route by which a Dell-packaged GeForce driver could overwrite the pinned GTX 1060 (580.97). That is
why the pin needed a third enforcement point at all. With dcu gone the bypass does not exist, and the
pin rests on two simple name filters (`windowsUpdate.notTitle`, `winget.excludePattern`).

What you lose: nothing tells you if Dell ships a BIOS or firmware update. For this hardware that is
close to hypothetical. Removing the integration does **not** uninstall Dell Command Update, so
`dcu-cli /scan` can still be run by hand *where the tool happens to be installed* — but a fresh
v0.14.0 install no longer bootstraps it, and on caldera itself DCU was subsequently uninstalled
outright (freeing ~510 MB and one always-running service), so the honest fallback there is Dell's
support site rather than a local command.

- Config: the `dell` block is gone. An existing `config.json` carrying it still loads (unknown keys
  are ignored), so no migration is needed.
- `Install.ps1` no longer attempts to bootstrap Dell Command Update.
- `Uninstall.ps1 -Purge` still cleans up `C:\SunUp\dcu` from a v0.13.x install, and still removes the
  parent only when left empty — it may pre-date SunUp and hold unrelated data.
- Suite is 169 checks (was 218): the 50 Dell/staging checks went with the code they covered.

## [0.13.1] - 2026-08-02

### Fixed — the Dell update path had been dead for four days, reporting clean

- **`dcu-cli` refuses to write its scan report into a reserved folder, and `C:\ProgramData` is one.**
  Every run since 2026-07-29 logged `The path provided for option '-report' is a reserved folder
  that may not be used.` / `return code: 107` and applied **nothing** — while `dell` reported `warn`,
  which `$errors` (status `-eq 'error'`) does not count, so the run raised event 2001 "clean" and
  exited 0. Measured this time: `C:\ProgramData\…`, `C:\Windows\Temp\…` and `C:\Users\Public\…` all
  return 107; `C:\SunUp\dcu` returns 0 with a real report. The scan now stages there (locked to
  SYSTEM + Administrators on every run, since the drive root lets anyone create folders) and the
  report is copied into the run dir for the record.
- An unusable scan is now status **`error`**, not `warn` — it blocks every Dell update, so it must
  reach event 2010 and SysSentry instead of reading as a clean run.
- **`-updateDeviceCategory` was being fed values dcu-cli does not accept.** It takes exactly
  `(audio,video,network,storage,input,chipset,others)`; the scan report is free text, and the real
  report on caldera says `<category>Application</category>`. Dell also ships categories containing
  commas and spaces ("Mouse, Keyboard & Input Devices", "Serial ATA"), which `-join ','` split into
  extra bogus tokens. dcu-cli rejects the whole command for an unknown value: the apply exits
  non-zero having installed nothing, for as long as a pinned update keeps the exclusion path alive.
  New `ConvertTo-DcuCategory` maps report text onto dcu's own vocabulary (`Application` → `others`,
  `Serial ATA` → `storage`, …) and the apply refuses to run if a token ever escapes that mapping.
- **The fail-closed guard did not check the parse.** `Parse-DcuReport` swallowed every XML error into
  `return @()`, which is indistinguishable from "nothing to exclude" — so a truncated, locked or
  schema-changed report produced no exclusions, no category restriction, and an **unrestricted**
  `/applyUpdates` over the pinned GTX 1060. It now returns `$null` for "unreadable" and an empty
  array for "empty", and the caller fails closed on the difference.
- A Dell run where updates are deferred **only** as collateral (or where the split failed closed on
  an uncategorized exclusion) returned `ok`. Every driver/firmware update on the box can be blocked
  that way, indefinitely; it is now `warn` with the reason. A run with warnings raises new event
  **2002** instead of 2001 "clean".

### Fixed — handoffs that reported success without doing anything

- **`SelfHost.ps1` resolved `winget.exe` once and kept using it while upgrading
  `Microsoft.DesktopAppInstaller`** — the package that owns the versioned `WindowsApps` folder that
  path points into. The next iteration's launch raised `CommandNotFoundException`, which `2>&1` does
  **not** capture, leaving `$LASTEXITCODE` at the previous package's `0`: `Microsoft.PowerShell
  upgraded (exit 0x00000000)`, `ok=2/failed=0`, event 2020 — for a package winget never saw, every
  run, forever. It now re-resolves per package, catches the launch failure, and records
  `(not launched)` rather than a success.
- **The retry gate lost two of its three markers.** Dropping `--custom REBOOT=ReallySuppress` and
  retrying is only safe when winget rejected the *argument*; gating on `Starting package install`
  alone meant a failure mid-**download** was retried without the suppression, leaving the PowerShell
  MSI free to restart the box unannounced under `/qn`. `Test-InstallStarted` restores the
  `Downloading …` / `Successfully verified installer hash` checks the deleted
  `Test-WingetArgsRejected` had, with the tests that went with them.
- **`Start-ScheduledTask` on an `IgnoreNew` task silently no-ops when an instance is already
  running**, and the engine logged "started …" plus event 2020 on that call regardless. New
  `Start-TaskVerified` refuses to start over a live instance and confirms the task really entered
  Running before anything is claimed; a no-op is reported as `did NOT start`.
- **`UserScope.ps1` dropped HKCU-registered self-hosting packages and logged them as "left to the
  SYSTEM handoff"** — a handoff that cannot see HKCU packages at all, which is the entire premise of
  that script. Nobody upgraded them, ever. It now launches the same helper itself: Windows
  PowerShell 5.1 (outside Restart Manager's blast radius), as the interactive user (so HKCU is
  visible), waiting for the pass to exit, writing `user-selfhost.json`.

### Fixed — records and reboots the engine threw away

- **Nothing read `selfhost.json` / `user-winget.json`.** Self-hosting packages leave `$pending`
  before the upgrade loop, which deleted their `Add-Update` call, so a successful PowerShell 7
  upgrade never appeared in `updates[]`, the dialog or the history — and a failing one left the run
  reporting `winget = ok`. A winget "restart required" exit code was lost outright: the engine had
  already made its reboot decision, and such a reboot sets no OS pending flag for the stale-reboot
  watchdog to find either. New `Import-DetachedResults` folds the previous run's records in (once,
  marked `ingested`, newest three run dirs) **before** the reboot decision, as a `handoff` component.
- **The user-scope pass had no `$willReboot` guard** — the guard its sibling handoff has had all
  along. With a 300 s countdown on screen and a pass that routinely runs longer, the box restarted on
  top of a live `winget upgrade`. It is now skipped when a reboot is due, and `winget.userScope`
  is finally honoured by the engine (it only ever checked `winget.enabled`).
- **The self-host handoff skipped itself on `$willReboot` alone**, but with a user logged in that
  only means the dialog offers a *cancellable* countdown: every Postpone cost a day, for a reboot
  that never happened. It now skips only the headless case and otherwise passes `-InitialDelaySec`
  so the helper sits out the countdown and proceeds if the box is still up.
- **The engine started `SunUp-User` (pwsh 7) seconds before handing PowerShell 7 to the upgrade
  helper.** Restart Manager shuts down 'PowerShell 7' and killed that pass mid-`winget upgrade` — no
  `user-winget.json`, no event, no alert. The helper now also waits for the `SunUp-User` task to go
  idle (`-WaitForTask`), and a machine-wide `Global\SunUp-Winget` mutex serializes the two helpers
  so they cannot collide with "Another installation is already in progress".

### Fixed — uninstall

- The process-kill loop matched only `SunUp-Tray.ps1` under `pwsh.exe`, so a detached
  `SelfHost.ps1` (Windows PowerShell **5.1**) went on upgrading PowerShell 7 minutes after the admin
  was told SunUp was removed, and `UserScope.ps1` kept upgrading against a deleted config dir.
  Uninstall now stops both hosts by script name, `Stop-ScheduledTask`s each task before
  unregistering it (unregistering does not stop a running instance), and `-Purge` also removes the
  `C:\SunUp` scan-report staging dir.

### Hardened after review

- The scan-report staging dir is locked down by **replacing** its DACL (`Set-Acl`, protected, SYSTEM
  + Administrators) and taking ownership, not by `icacls /inheritance:r /grant` — which strips only
  *inherited* entries, so an unprivileged process that created `C:\SunUp` first kept its explicit ACE
  **and its ownership**, and an owner can put the DACL back. Verified by squatting the directory.
  A reparse point there is refused outright, and a lockdown that fails **fails closed** (the
  component errors rather than trusting a report a non-admin may be able to rewrite).
- An exit-0 scan whose report contains **no recognized update records** is unusable, not empty:
  dcu-cli has a separate code for "nothing applicable" (500), so a parse that disagrees with a
  successful scan means a schema change — which would otherwise read as "nothing to exclude".
- Detached results are discovered across **every retained run dir** (a helper can finish several
  `-Force` runs later) and bounded by an ingestion cursor taken **before** the scan, so a record
  written while the run was in flight is not consumed unread.
- A reboot a detached pass asked for is carried in the stamp until a boot is actually observed —
  postponing the dialog's countdown no longer loses it — and one whose helper finished *before* the
  last boot is treated as already satisfied rather than triggering a second restart.
- `Start-TaskVerified` requires `LastRunTime` to advance past its own start call; observing `Running`
  confirmed only that *an* instance was up, which is precisely the one `IgnoreNew` dropped ours for.
- The winget mutex is created with an explicit SYSTEM + Administrators ACL (its two holders are
  different principals) and a failure to take it is logged rather than silently running unserialized.
- `UserScope.ps1` checks that the helper it launches did not exit immediately — `Start-Process`
  reports only that the *host* started, so a non-elevated child dying on `#Requires` read as success.
- `Uninstall.ps1 -Purge` reports only the paths it actually removed, removes only the `dcu` subtree
  (`C:\SunUp` may pre-date SunUp and hold unrelated data — the parent goes only when left empty), and
  kills only processes running the **installed** scripts under `C:\ProgramData\SunUp\bin`.
- Concurrency, throughout: one ingest at a time (`Global\SunUp-Ingest`), one task start at a time
  (`Global\SunUp-TaskStart`), one winget pass at a time (`Global\SunUp-Winget`) — a documented
  `-Mode Run -Force` really can overlap a scheduled run. Every one of those locks **fails closed**:
  no lock means no ingest and no upgrade, since the records persist and the next run picks them up.
  The stamp write is the deliberate exception — it also carries the once-per-day gate, so skipping it
  would re-run the entire update pass; it merges, verifies and retries instead.
- Detached records are published atomically by their producers (`.tmp` + rename) and timed in **UTC**
  by the file's write time — a reader that caught a `Set-Content` mid-write treated the record as
  lost, and a local-time comparison would bury a fresh record during a DST fall-back.
- **Found by running it, not by reading it:** the stamp verification compared timestamps as *text*.
  `ConvertFrom-Json` parses an ISO-8601 value back into a `[datetime]`, whose string form is
  culture-formatted **local** time (`08/03/2026 06:18:05`) and never equals the round-trip string it
  was written from — so every single run logged a phantom `a concurrent run rewrote it` and wrote the
  stamp three times. New `ConvertTo-UtcTime` normalizes either form and the comparison is on
  instants. A false alarm on every run is the same class of defect as a missed one.

### Tests

- Suite is 218 checks (was 97). New coverage: every shipped script parses (UserScope, Install and
  Uninstall had none); `Parse-DcuReport`'s `$null`-vs-empty contract; the dcu category vocabulary,
  including the real `Application` category and comma-bearing Dell categories; `Test-InstallStarted`
  against real winget output; the detached-result ingest, including that ingesting twice does not
  double-count; and the uninstall kill list.

## [0.13.0] - 2026-07-28

### Added — the per-user packages the engine structurally could not see

- winget resolves installed packages **per user**. The engine runs as SYSTEM, so anything
  registered under **HKCU** is invisible to it — not skipped, not failed, simply absent from
  `winget upgrade`. Measured on caldera: SYSTEM's list and the interactive user's list were
  **disjoint**.
- Six of the user's seven packages — Deno, yt-dlp FFmpeg, fzf, ripgrep, Rufus, Sysinternals —
  matched **nothing** in `excludePattern`. They were never a policy decision; SunUp had simply
  never updated them. ripgrep was sitting at 15.1.0 against 15.2.0.
- The distinction matters because `excludePattern`'s comment reasons that per-user apps "are HKCU
  so SYSTEM never sees them", treating invisibility as equivalent to exclusion. That is true for
  apps that self-update or refuse to install while running (Claude, Spotify, Discord, Slack, Teams,
  LM Studio) and false for ordinary CLI tools.
- New **`UserScope.ps1`**, run by a new **`SunUp-User`** task on the same principal as the notify
  and tray tasks (Interactive, RunLevel Highest) — no new security posture. The engine starts it at
  the end of a run, and only when a user is logged on (an Interactive task cannot run otherwise);
  a headless run leaves those packages for the next run that has a session.
- **Policy is shared, deliberately:** `excludePattern` and `selfHostPattern` are read from the same
  `config.json` the engine uses, so there is one policy and one place to change it. LM Studio stays
  excluded in user scope; self-hosting packages remain the SYSTEM handoff's job. New
  `winget.userScope` (default `true`) disables the pass without touching those patterns.
- Results land in the same run dir (`user-winget.log` / `user-winget.json`) plus events 2030/2031.
- **Known limitation:** the summary dialog's payload is written by the engine *before* this runs, so
  packages upgraded here appear in the logs and event log but not that run's dialog. They show up in
  the next run's 30-day history.
- The parser reads winget's **fixed-width table by column position**, copied from the engine's
  `Parse-WingetUpgrades`. A split-on-2+-spaces parser was written first and **dropped 3 of the 7
  real rows** — winget pads columns to a fixed width, so a value that fills its column is followed
  by exactly one space ("Sysinternals Suite" and "LM Studio 0.4.16+2" fill the 18-char Name column;
  yt-dlp's `N-124716-...` fills Version). It failed by silently dropping rows, so the pass would
  have upgraded a subset and reported success. Caught by testing against the real captured output.
- Suite is 97 checks.

## [0.12.0] - 2026-07-28

### Fixed — the engine killed itself upgrading PowerShell, and v0.11.0's fix did not work

- Three consecutive runs (2026-07-22, 2026-07-27, 2026-07-28) died at the same package,
  `Microsoft.PowerShell 7.6.3.0 -> 7.6.4.0`, leaving no `result.json`, no reboot decision, no
  summary dialog and no day stamp. Because the day stamp is written at the *end* of a run, the
  next trigger re-ran and re-died at the same package — a silent retry loop that presented as
  "updates just aren't running". `lastrun.json` sat at 2026-07-20 for eight days.
- Cause: the engine runs under `pwsh`, so upgrading PowerShell has Windows Installer's Restart
  Manager enumerate every process holding files under the install target and shut them down —
  including the engine that requested the install.
- **v0.11.0's mitigation did not work.** It passed `MSIRESTARTMANAGERCONTROL=Disable` via winget's
  `--custom`. The 2026-07-28 run applied those args and RM ran regardless, logging
  `10002 Shutting down application or service 'PowerShell 7'` and terminating all five `pwsh`
  processes on the box while the MSI itself returned success (`1033 ... error status: 0`). Whether
  winget dropped the property or Windows Installer ignored it across the major-upgrade transaction
  was never established. The deeper flaw was structural: the mitigation had **no feedback loop**, so
  a silent no-op was indistinguishable from success until the engine died.
- **New approach — leave the blast radius instead of trying to survive it.** Self-hosting packages
  are no longer upgraded by the engine at all. `Comp-Winget` splits them out and the engine hands
  them to a new **`SelfHost.ps1`**, run by a one-shot `SunUp-SelfHost` scheduled task under
  **Windows PowerShell 5.1** — a separate installation that RM's "shut down PowerShell 7" cannot
  reach. The helper waits for the engine's PID to exit before touching winget, so the run always
  completes first. The task self-deletes.
- The handoff is registered as the engine's last act, and is **skipped when a reboot is imminent**
  (it would race the shutdown); the packages stay on the upgrade list for the next run.
- The helper never reboots — the engine owns that decision. A reboot requirement found here is
  recorded in `selfhost.json` and escalated by the next run's stale-pending-reboot watchdog.
- **Accepted limitation:** interactive `pwsh` terminals are still killed when PowerShell 7 upgrades.
  That is Restart Manager, and nothing short of a reboot-time install avoids it.
- `winget.selfHostInstallerArgs` is retained but unused, so an existing `config.json` still loads.
- `SelfHost.ps1` is kept strictly ASCII and 5.1-compatible: 5.1 reads a BOM-less file as ANSI, so
  em dashes in comments broke the parse outright during development. Both constraints are asserted
  in its header.
- **Found by the first live handoff test:** `powershell.exe -File` passes every argument as a
  literal string and cannot bind an array parameter. `-Ids a,b` arrives as the single string
  `"a,b"`; `-Ids a b` binds only `a` and silently drops the rest. The helper originally declared
  `[string[]]$Ids`, so winget was handed one glued-together package name and answered *"No installed
  package found matching input criteria"* — upgrading nothing while every other part of the handoff
  reported success. It now takes one comma-delimited string and splits it itself, and both binding
  behaviours are pinned by tests.
- **Test harness fix:** a terminating error inside a check's *condition* (an invalid regex) unwound
  past the failure counter to the summary, which printed `ALL TESTS PASSED` while the remaining
  checks never ran. Unhandled errors now count as failures and say so.

### Fixed — the update-collapse block silently renamed the product

- The duplicate-row collapse assigned `$name` for a row label. PowerShell variable names are
  **case-insensitive**, and that block runs at **script scope**, so it overwrote the global
  `$Name = 'SunUp'` with the last collapsed update's product name.
- Every `$Name` use after that point was wrong: real runs logged
  `===== Google Chrome run end =====` (2026-07-18) and raised event 2001 as
  `Tailscale run 2026-07-28_231314 clean: ...` (2026-07-28). It only triggered on runs with 2+
  updates, so it read as random corruption rather than a variable collision.
- Renamed to `$rowName`. Pinned by a test that lifts the real block out of the source, runs it, and
  asserts `$Name` survives — verified by mutation (reintroducing `$name` fails the test).
- Suite is 83 checks.

## [0.11.0] - 2026-07-27

### Fixed — the NVIDIA pin was enforced on two of three update paths, not three

- Prompted by a Dell Command Update notification appearing on the box while SunUp had
  `dell.enabled: false`. Reviewing what enabling it would do exposed the gap: the pinned GPU driver
  (GTX 1060 held at 580.97, Pascal EOL) is protected on the **Windows Update** path by
  `windowsUpdate.notTitle` and on the **winget** path by `winget.excludePattern` — but `Comp-Dell`
  ran `dcu-cli /applyUpdates -updateType="driver,firmware,utility"` with **no filter at all**. A
  Dell-packaged GeForce driver would have installed straight over the pin.
- New **`dell.excludePattern`** (default `NVIDIA|GeForce`), matched against each update's name in the
  dcu-cli scan report, so the same policy now holds on all three paths.
- `dcu-cli` can filter by update **type** and **device category**, never by name — so an excluded
  update is avoided by dropping its whole device category from that apply. `Split-DcuUpdates` works
  this out and the run **says what it cost**: an unrelated update deferred only because it shares a
  category with an excluded one is logged as such (WARN) and counted separately in the status line,
  rather than silently disappearing. A silently skipped driver is indistinguishable from a missing one.
- Two fail-safe cases apply **nothing** rather than risk installing what was excluded: an excluded
  update carrying no device category (nothing to filter on), and a remaining set with no categories
  at all. A deferred driver costs a day; an overwritten pinned GPU driver costs a manual rollback.
- Tests: 68 checks — the pinned driver never reaches the apply set, its category is dropped, a
  same-category update is reported as collateral, unrelated categories still apply, a non-matching
  pattern filters nothing, and an uncategorized exclusion blocks the apply.

## [0.10.1] - 2026-07-27

### Fixed — the v0.10.0 installer-type gate would have disabled the fix on the one package it exists for

- Caught by live data minutes after v0.10.0 was tagged, while checking whether PowerShell 7.6.4 would
  now install by itself. `Get-WingetInstallerType` read the **default** installer out of
  `winget show`, and for `Microsoft.PowerShell` that answer is **`msix`** — so the gate would have
  withheld `MSIRESTARTMANAGERCONTROL=Disable` and left Restart Manager free to kill the engine again:

  | probe | answer |
  |---|---|
  | `winget show --id Microsoft.PowerShell` | `Installer Type: msix` |
  | `winget show … --installer-type wix` | **`Installer Type: wix`** ← the `.msi` |

  The package publishes **both**, and an *upgrade* matches the installed package's installer
  technology rather than the manifest default — which is why the 2026-07-22 run installed
  `PowerShell-7.6.4-win-x64.msi` (per the `MsiInstaller` events) while `winget show` says msix.
  "What is the default installer type" was simply the wrong question.
- Replaced with **`Test-WingetHasMsiInstaller`**, which asks whether the package offers an MSI-family
  installer **at all** (`--installer-type wix|msi|burn`). Verified against live winget 1.29.280:
  `Microsoft.PowerShell` → true, `Microsoft.DesktopAppInstaller` → false, `Google.Chrome.EXE` → false.
- Added a **retry**: if an upgrade carrying the Restart Manager args fails with anything other than a
  reboot-required code, it is retried once without them. The probe can only prove an MSI-family
  installer *exists*, not that winget chose it, and a package left un-upgraded is a worse outcome
  than one upgraded with Restart Manager still active — especially now that such a kill is reported
  as event 2011 instead of vanishing.
- The retry is **gated on nothing having installed yet** (`Test-WingetArgsRejected`). Retrying on any
  failure would have been actively dangerous: a download error or a mid-install failure on
  `Microsoft.PowerShell` would trigger a second attempt that both reruns an installer against
  partially changed state *and* drops `MSIRESTARTMANAGERCONTROL=Disable` — re-arming, within the same
  run, the exact kill this release exists to prevent. So the claim "an argument rejection happens
  before any install work" is now **verified** rather than assumed: if winget reached a download, a
  verified hash, or the installer launch, the args were accepted, the failure is something else, and
  the package is left for the next run with a WARN saying exactly that. (Caught as a P1 by Codex.)

## [0.10.0] - 2026-07-27

### Fixed — SunUp no longer kills itself while upgrading PowerShell
- On **2026-07-22** the run died mid-flight and nothing said so for five days. Root cause:
  winget's `Microsoft.PowerShell 7.6.3 → 7.6.4` upgrade. SunUp runs under `pwsh`, and the MSI's
  **Restart Manager** enumerates processes holding files under the install target and shuts them
  down — including the engine that asked for the install. Event log, 14:15:19–14:15:23:
  `RestartManager 10002 Shutting down application or service 'PowerShell 7'` →
  `10010 Application 'pwsh.exe' cannot be restarted — Application SID does not match Conductor SID` →
  `MsiInstaller 11708 Product: PowerShell 7-x64 — Installation failed` (rolled back; the box stayed on
  7.6.3). The engine was terminated ~200 lines before its reboot decision, so it never rebooted, never
  showed the dialog, and never wrote `result.json`. The `ifRequired` policy was not at fault — the
  code that evaluates it never executed. (Collateral: the same sweep killed ProcWatch's engine, which
  stayed dead until the box was rebooted by hand.)
- Packages that host the engine's own process are now identified by **`winget.selfHostPattern`**
  (default `Microsoft\.PowerShell|Microsoft\.DesktopAppInstaller`) and handled two ways:
  - **Upgraded last**, after every other package — a surprise kill can no longer cost the packages
    that hadn't been reached yet.
  - **Installed with Restart Manager disabled**, via `winget --custom` carrying
    **`MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress`** (`winget.selfHostInstallerArgs`).
    With RM off, files in use fall back to PendingFileRename: the install completes, the engine
    **survives**, and the MSI returns `3010`, which SunUp already maps to "reboot required" — so the
    restart happens where it belongs, in the one coordinated reboot at the end of the run.
  - `--custom` (appends to winget's defaults), never `--override` (which would *replace* them and
    drop the `/qn` that keeps the install silent).
- Those args are **Windows Installer properties**, so they are only attached when they can actually
  apply. `Get-WingetInstallerType` asks `winget show` what is about to run and
  `Test-MsiPropertiesApply` gates on it: `msi`/`wix`/`burn` (bundles forward properties to the MSIs
  they wrap) get the args; `msix` — which is what `Microsoft.DesktopAppInstaller` is — along with
  `exe`/`inno`/`nullsoft` and an unreadable type do not, since those would receive the properties as
  junk on their command line. Such packages are still **deferred to last**, and the run logs that
  Restart Manager could not be disabled for them. (Raised in review by CodeRabbit.)

### Added — a killed run is no longer silent (event 2011)
- A run terminated mid-flight produced **no signal whatsoever**: `result.json`, `history.jsonl`,
  events 2001/2010, the SysSentry echo and the summary dialog are all written *after* the component
  loop, and `lastrun.json` is never stamped — so the next day's run looked like an ordinary
  first-run-of-the-day. The only trace of 2026-07-22 was ProcWatch's unrelated stale-heartbeat alert.
- Each run now scans for the fingerprint of a dead run — a previous run dir with `run.log` but **no**
  `result.json` — and reports it once with **event 2011** + a SysSentry alert quoting the last line
  that run logged, so the message says *where* it stopped. `incomplete.json` marks a dir as reported
  so the alert can't repeat.
- "No `result.json`" alone would also match a run **still in progress**. `MultipleInstances=IgnoreNew`
  only serializes *task-launched* runs — the documented `SunUp.ps1 -Mode Run -Force` is a standalone
  process the scheduler never sees, so a manual run and a scheduled one genuinely can overlap. Every
  run therefore writes a **`running.json`** liveness marker (PID **plus that process's start time**,
  because PIDs are recycled) before touching a single component, and deletes it once `result.json`
  exists. `Test-RunAlive` clears a candidate only when the marked PID is running *and* the image name
  and start time still match; if the start time can't be read it assumes **alive**, so a live peer is
  never mislabelled. A dir with no marker predates v0.10.0 or died before writing one — either way
  its owner is gone, so it still counts as crashed. (Caught in review by Codex.)
- Two further concurrency holes closed, also from review:
  - **Run dirs are now claimed atomically.** The stamp has second resolution, so two runs starting in
    the same second were handed the *same* dir — interleaved logs, one `running.json` overwriting the
    other, and whichever finished first writing a `result.json` that made the dir look complete even
    if its peer was killed later. `New-RunDirectory` claims a dir by **creating** it (`New-Item`
    without `-Force` fails if it exists, so the claim is atomic against a racing peer) and falls back
    to a PID-qualified name, then a counter.
  - **The marker is dropped only once `result.json` is really on disk.** `$ErrorActionPreference` is
    `Continue`, so a transient lock or I/O error let `Set-Content` fail quietly while the marker was
    deleted regardless — leaving a run with neither file, which a peer could read as a crash or the
    next run could read as a completed run that was killed. The write is now terminating and
    verified; if it fails the marker stays and the run is reported unfinished, which is the truth.
  - **`result.json` is published atomically.** `Set-Content` truncates the destination first, so a
    kill or I/O error partway through left a truncated file that still satisfied "result.json
    exists" — and the crash check would read that interrupted run as a normal finish. `Save-RunResult`
    serializes and **parse-verifies** into a temp file, then renames it over the destination: a run
    is declared complete only by a file that was already whole.
  - **A crash report is claimed before it is emitted.** Two concurrent runs could both pass the
    "no `incomplete.json`" check before either wrote one, and both would fire event 2011 and append
    to `ALERTS.md`. The marker is now created first (`New-Item` without `-Force`, so a peer that got
    there first makes this scanner skip the dir), and only the winner reports.
  - **An abandoned claim no longer suppresses the report forever.** A scanner killed *between*
    claiming and reporting used to leave a marker that silenced every later scan — this feature's own
    failure mode, turned on itself. A marker now means one of three distinct things: a completed
    report (`reported: true`, never re-emitted), a report a peer is making right now (claim newer
    than 15 min, left alone), or an abandoned claim (older, unreported — retaken and reported, with a
    WARN saying so). At-least-once beats never for a crash notification.
  - **The claim is a real lock.** Building mutual exclusion out of file operations — create-if-absent
    for a fresh claim, rename-to-lease for a stale retake — kept leaving windows in which the marker
    did not exist *as itself*, which a scanner arriving mid-take reads as "unclaimed", so both would
    report. The marker is now opened with `FileShare::None` and the OS handle **is** the lock: the
    file is always present and recognizable, exactly one process can hold it, a peer that probes
    while it is held simply finds an unreported claim and leaves it alone, and Windows releases the
    handle automatically if the holder is killed. One mechanism now covers the fresh claim and the
    retake identically, and `reported: true` is written through that handle last of all.
  - **Completion is rechecked under the lock.** A live peer can publish `result.json` and drop
    `running.json` in the window between the scan and the liveness probe, which would make a
    normally-completed run look crashed. `result.json` is rechecked as late as possible — after the
    lock is taken — and a marker created for a run that turns out to have finished is removed again.
  - **`running.json` is written the same atomic, verified way.** It was still using a plain
    `Set-Content`, which under `$ErrorActionPreference = 'Continue'` could fail without entering the
    `catch` — leaving a live run with no marker, which a peer would then read as crashed. All three
    JSON files now go through one `Publish-JsonFile` helper; a failure to write it is logged
    explicitly as "a concurrent run could mistake this live run for a crashed one".

### Added — `tests\Test-SunUp.ps1`
- First tests in the repo, covering both changes above without performing a real update run: the
  engine parses; `Report-CrashedRuns` (lifted from source via the PowerShell AST, so the test
  exercises the shipped code) flags exactly the dead run dirs and exactly once, ignoring finished
  runs, empty dirs and the live run; the self-hosting partition loses no package, orders PowerShell
  last, and attaches `--custom` to that package alone. `pwsh -File .\tests\Test-SunUp.ps1`

## [0.9.0] - 2026-07-08

### Fixed — winget rows now show a real download size instead of "—"
- winget updates always displayed `—` in the dialog's **size** column. Root cause: `Get-WingetSizeMB`
  scraped the size from winget's animated `/ N MB` download progress, but SunUp installs with
  `--silent --disable-interactivity`, which suppresses that progress entirely — winget's captured
  output logs only a bare `Downloading <url>` line with no byte count, so the regex never matched and
  size was always `$null`. This was a source-text problem, not a parsing bug: the number simply wasn't
  in the text.
- Replaced `Get-WingetSizeMB` with **`Get-WingetDownloadSizeMB`**, which reads the true installer size
  over HTTP. It extracts every `Downloading <url>` line from the install output and issues a `HEAD`
  request per artifact with **`Accept-Encoding: identity`** — identity is load-bearing: it forces the
  server off on-the-fly gzip, which otherwise omits `Content-Length` (Google's CDN does exactly this,
  the reason a naive HEAD returned nothing). Sizes are summed across artifacts so installs that pull
  dependencies count them all. Verified live: Google Chrome now reports **466.5 MB**.
- The lookup runs **after** the package has already upgraded, so a network hiccup, chunked-transfer
  server, or expired signed URL only blanks the size cell — never the update or its status. Returns
  `$null` (→ `—`) honestly when there is no URL (msstore packages install via the Store) or no
  `Content-Length`. Runs under `pwsh` (PS7+), whose default TLS needs no pinning.

## [0.8.1] - 2026-07-03

### Fixed — duplicate update rows no longer triple-count sizes
- A single run could record the **same logical update multiple times**. Windows Update offers an
  Audio Processing Object (APO) driver package **once per matching audio endpoint**, so the
  2026-07-02 run stored three byte-identical `AudioProcessingObject Driver Update (1.0.4.7057)`
  rows (same `name|source|old|new|sizeMB`). This bloated `updates[]` in `history.jsonl` and, worse,
  tripled the dialog's `totalSizeMB` — **87 MB reported for 29 MB of actual bytes** (WU downloads
  the package once regardless of how many endpoints claim it).
- The engine now collapses rows identical in `name|source|old|new|sizeMB` into a single row before
  the result is persisted, annotating the count as `×N` (e.g. `AudioProcessingObject Driver Update
  (1.0.4.7057) ×3`) and keeping **one representative size** so totals reflect reality. Rows that
  merely share a name but differ in version or size stay separate — size is part of the collapse key.

## [0.8.0] - 2026-07-02

### Changed — `rebootPolicy: "ifRequired"` is the new default (no more reboots you didn't need)
- SunUp already computed two reboot signals but decided on the wrong one: `rebootPending` (a blunt
  OS-level flag that a PnP/driver install trips even when nothing needs a restart) drove the reboot,
  while `rebootRequiredByRun` (whether a component **this run** actually reported `reboot=true`) was
  only recorded. The reboot decision is now a `rebootPolicy` switch:
  - **`ifRequired`** (new default) — reboot only when a component this run required it.
  - **`always`** — reboot on any OS pending flag (the old 0.1.0–0.7.0 behavior; still available).
  - **`never`** — never auto-reboot.
  - Motivating case: a 2026-07-02 run installed only a Defender signature + a Microsoft
    AudioProcessingObject **driver**; the driver set the OS pending flag, so `always` rebooted the box
    even though `rebootRequiredByRun` was `false`. Under `ifRequired` that morning would not reboot.
- When an OS pending flag is set but no component this run required a reboot, `ifRequired` logs it
  quietly (INFO) instead of raising a daily SysSentry "reboot pending" alert. `never` still nudges.
- Tray **Auto-reboot when needed** toggle is now three-state aware: the checkmark means *enabled*
  (`ifRequired` **or** `always`); toggling on sets the smart `ifRequired` default, toggling off sets
  `never`. Balloon reads "Auto-reboot is now ON (only when required)".

### Added — hardening for the `ifRequired` blind spot + winget observability
- **Stale pending-reboot watchdog.** `ifRequired` deliberately leaves an OS pending flag that no run
  required — but a *genuinely* needed reboot (missed detection, or a flag set outside SunUp) could
  then sit forever. The engine now tracks how long a flag has persisted (via `pendingSince` in
  `lastrun.json`) and raises a **one-time** WARN + event `2006` + SysSentry alert once it exceeds
  `pendingRebootAlertDays` (default `3`, `0` disables). Rebooting or the flag clearing resets it.
- **winget list-exit logging.** A non-zero exit from `winget upgrade` (network/source hiccup) parses
  to zero rows and used to masquerade as "up to date"; the list exit code is now logged (and a WARN
  emitted) so an incomplete scan is visible.
- **Skipped packages surfaced.** Excluded winget packages now show as a count in the component detail
  (`up to date, 2 skipped` / `1 upgraded, 0 failed (of 1), 2 skipped`), not just buried in the raw log.
- **Dialog honors run-signal reboots (PR review, Codex P1).** Under `ifRequired` a reboot can be
  required by the run (e.g. a winget/MSI `3010` exit) while no OS pending flag is set. The dialog now
  decides pre- vs post-reboot by whether the box has **booted since the run finished** (`runEndUtc`
  vs `LastBootUpTime`) instead of the OS pending flag — which previously misread a flag-less reboot as
  "already rebooted" and silently skipped the interactive countdown. Defaults to showing the countdown
  on any uncertainty. Headless reboots were unaffected.
- **A failed winget upgrade-list no longer reports "up to date" (PR review).** A non-zero list exit
  with zero parsed rows now returns `warn` ("upgrade list incomplete") so `result.json`/`Status`
  reflect the partial run, not just the log.

### Fixed — winget no longer warns every run on unupgradable UWP framework packages
- `Microsoft.VCLibs.140.00` / `.UWPDesktop` are UWP **framework** packages that winget can't deploy
  (they fail `0x8A15005C` "Failed to extract the contents of the archive" every run) and are serviced
  by the Store / dependent apps, not winget. They're now in the default `winget.excludePattern`, so a
  clean run stops flipping to **warn** over an unactionable, perennial failure.
- Excluded winget packages are now logged (count + ids) to `winget.log` and the run log — a skip is a
  deliberate decision, not a silent no-op.

## [0.7.0] - 2026-06-27

### Added — system-tray presence (`SunUp-Tray.ps1`)
- Windows has no service-manager face for a scheduled task, so SunUp now has a **tray icon** (a sun;
  turns amber when a reboot is pending) with a right-click menu: a header (last run + next scheduled
  run), **Run now** (triggers the SYSTEM task), **Show last summary** (re-opens the dialog), **Open
  logs folder**, an **Auto-reboot when needed** toggle (flips `rebootPolicy` in config; the checkmark
  reflects state), and **Exit**. Double-clicking the icon opens the last summary. The tip/icon refresh
  on a 45s timer, and a **balloon** pops when a new run completes.
- Launched at logon by a new **`SunUp-Tray`** task (interactive user, single-instance via a named
  mutex + `MultipleInstances=IgnoreNew`, `RunLevel Highest` so its actions can drive the SYSTEM task
  and edit config). `Install.ps1` registers and starts it; `Uninstall.ps1` stops and removes it.

## [0.6.0] - 2026-06-27

### Changed — capture every column the sources actually expose (no more avoidable blanks)
- **Dell now records real name + version + download size** per applied update, parsed from
  `dcu-cli /scan -report` XML (`<name>`/`<version>`/`<bytes>`), instead of the old generic
  `'installed'` / `—`. The engine scans to an XML report first, partitions into apply (driver/
  firmware/utility) vs BIOS (report-only), applies, then records the applied set from the report.
- **Dell exit codes are interpreted correctly.** Previously every result was labelled
  "drivers/firmware applied (exit N)" even when nothing applied. Now: `0`=applied, `1`=applied+reboot,
  `5`=reboot pending from a prior op (nothing applied now), `500`=no applicable updates, else=warn.
- **Windows Update fills the "old" column for OS updates** by snapshotting the build (`CurrentBuild.UBR`)
  before/after the run — a Cumulative/Feature/Servicing-Stack update shows `26200.8737 -> 26200.9xxx`
  instead of a blank. Per-update size is still taken from WU when it reports it.
- **Batch installers (WU, Dell) now show a Duration** — the measured install/apply batch span. Exact
  for a single-item batch; the shared batch total when several install together (documented).

### Notes — the only two cells that can still legitimately show "—"
- **Defender download size**: no Defender API exposes the signature-package size.
- **Dell "old" version**: dcu-cli's report lists only the *available* version, never the installed one.
These are source limitations, not logging gaps — the data doesn't exist to capture.

## [0.5.0] - 2026-06-27

### Changed
- **Renamed `AutoUpdate` → `SunUp`** (it runs at dawn so you start the day with fresh updates, and
  keeps the "up" of Update). Every path, scheduled-task name (`SunUp` / `SunUp-Notify`), event-log
  source, and the dialog title now derive from a single `$Name` constant in each script. `Install.ps1`
  performs an **idempotent live migration**: it quiesces the old tasks, `Move-Item`s
  `C:\ProgramData\AutoUpdate` → `C:\ProgramData\SunUp` (preserving config, logs, history, notify
  state, ACLs), registers the new-named tasks *before* removing the old ones, swaps the event source,
  and refreshes the SysSentry baseline last. Re-running heals a partial migration.

### Added
- **30-day update history in the dialog.** Below the current run (normal color), the dialog lists the
  past `notify.historyDays` (default 30) of updates **greyed out but legible**, with a new **When**
  column. The engine (SYSTEM) assembles the list from `history.jsonl` and embeds it in the
  user-readable notify payload, since the non-elevated dialog can't read `logs\`. `notify.historyCollapse`
  (default **true**) keeps only the latest occurrence per package so daily Defender-signature bumps
  don't flood the list; `notify.historyMaxRows` (default 500) caps it. Greying is a DataGridCell
  `DataTrigger` on a per-row `IsPast` flag using the existing muted-grey theme color.

### Fixed
- **Per-update Duration column was empty for Defender.** The engine timed each component but discarded
  it for the per-row record. Defender's `Update-MpSignature` is now wrapped in its own Stopwatch so its
  Duration populates. Windows Update / Dell per-row Duration stays "—" on purpose: they install items as
  a batch and expose no per-item timing, and stamping each row with the shared batch time would be a lie
  (per-row durations are display-only, not summed into totals). Defender/Dell download **size** stays "—"
  (those sources expose no size).

## [0.4.3] - 2026-06-27

### Fixed
- **Post-reboot dialog showed the literal text `&#x2714;`** instead of a green ✔. The two
  checkmarks in the *XAML string* render fine (XamlReader decodes XML entities), but the
  post-reboot branch assigned `"&#x2714;"` directly to a `TextBlock.Text` property at runtime —
  not XAML, so it displayed verbatim. Now assigns the real glyph via `[char]0x2714`.

### Changed
- **Dialog restart now leads with `Restart-Computer -Force`**, with `shutdown.exe` as the fallback
  (was the reverse). In the elevated interactive-task context `shutdown.exe` returns **exit=1 even
  with the privilege held** (observed during the 0.4.2 real-reboot test — only the
  `Restart-Computer` fallback actually rebooted), so the proven call now goes first. The visible
  countdown already serves as the user warning.
- **PowerShell module updates moved to weekly** (`psModules.everyDays`, default 7), gated by their
  own `psmodules-lastrun.json` stamp — the slowest component (~5–7 min) for the rarest payload now
  runs ~once a week instead of daily, cutting the typical daily run to ~2–3 min. The rest of the
  cycle still runs every day. A failed module run isn't stamped, so it retries the next day.

## [0.4.2] - 2026-06-27

### Fixed
- **Restart from the dialog silently did nothing.** Two stacked bugs: the `AutoUpdate-Notify` task
  ran `RunLevel Limited`, so `shutdown.exe` was Access-Denied (the CLI needs an elevated token even
  though the privilege is held); and `Invoke-Restart` used `Start-Process` with no `-Wait/-PassThru`,
  discarding the error. Now the notify task runs `RunLevel Highest`, and `Invoke-Restart` captures
  `shutdown.exe`'s exit code to `notify\reboot.log` and falls back to `Restart-Computer -Force`.

## [0.4.1] - 2026-06-27

### Fixed
- Dialog title bar stayed light on a dark system theme: the `SourceInitialized` handler used
  `$using:light`, which is only valid in remoting/job scriptblocks — in a WPF event handler it
  throws, and the `try/catch` silently skipped BOTH DWM calls (dark title bar *and* acrylic).
  Switched to a script-scope `$script:isDark`. Title bar now follows the theme and the acrylic
  backdrop actually applies.

## [0.4.0] - 2026-06-27

### Changed
- **Dialog shows after EVERY cycle**, even when nothing was updated (friendly "You're up to date"
  empty state).
- **Reboot trigger reverted to "is a reboot pending when checked"** (`Test-PendingReboot`), not the
  v0.3.1 per-run signal. Chrome sets no pending flag → never prompts; Dell/WU drivers do → countdown
  — even if a *prior* run installed them. (Removes the v0.3.1/0.3.2 "only this run" gating.)
- **Pre- and post-reboot dialogs both show the changes table.** One payload drives both; the dialog
  re-checks the live pending-reboot state at display time: pending now → table + cancellable
  countdown (Restart now / Postpone); already rebooted → table + "Restarted to finish" + Close.
- **A newer cycle replaces an open dialog** (`AutoUpdate-Notify` → `MultipleInstances=StopExisting`).
- Post-reboot (and headless-run) summaries appear at next sign-in via an **AtLogon trigger** on the
  notify task; display is gated by a `pendingShow` flag the dialog clears once seen.

### Added
- `notify\` subfolder (payload `latest-updates.json` moved here); installer grants the interactive
  user **Modify** on it so the non-elevated dialog can clear `pendingShow`.

## [0.3.2] - 2026-06-27

### Changed
- `winget.excludePattern` now also skips load-bearing per-user/Electron apps whose uninstaller
  refuses to run while open: **LM Studio** (the `:1234` API), Spotify, Discord, Slack (added
  `ElementLabs|LM ?Studio|Spotify|Discord|Slack`). Surfaced when a per-package winget upgrade tried
  to update a *running* LM Studio and its uninstall step failed (harmless — winget aborted, install
  left intact). Note: these are per-user (HKCU) installs, so the real SYSTEM task never sees them;
  this guards manual/user-session runs and documents intent. Such apps self-update anyway.

## [0.3.1] - 2026-06-27

### Changed
- **Restart is offered only when an update installed THIS RUN actually requires it** — never for a
  pre-existing/unrelated pending-reboot state. A Chrome-only run (winget exit 0) never prompts a
  restart. The per-run signal comes from each installer: winget reboot exit codes (MSI 3010 +
  `0x8A150077/78/79`, treated as success-with-reboot), Windows Update's per-update/post-install
  reboot status, and dcu-cli exit **1** (reboot required by this apply) — exit **5** (reboot pending
  from a prior op) explicitly does NOT count. `result.json` gains `rebootRequiredByRun`; the global
  `rebootPending` is kept for Status/info only. A pre-existing pending reboot is logged quietly,
  never prompted.

## [0.3.0] - 2026-06-27

### Added
- **Win11 summary dialog after each run that changed something** (`Show-UpdateDialog.ps1`): an
  acrylic-backdrop WPF window with a gridlined table — package, source, old version, new version,
  duration, download size — plus summary chips (count / total size / total time). Light/dark + accent
  aware. Shown via a new on-demand **`AutoUpdate-Notify`** task that runs in the interactive user
  session (SYSTEM can't show UI); engine fires it with `Start-ScheduledTask`.
- **Per-item update capture**: winget now upgrades packages individually so each one's old→new
  version, duration, and download size are recorded; Windows Update items carry KB + size; Dell
  drivers and Defender signature bumps are recorded too. Written to `latest-updates.json` and into
  `result.json` (`updates[]`).
- **Reboot ownership split** (fixes the restart-race): when a user is logged in, the dialog owns a
  visible, cancellable countdown (`rebootGraceInteractiveSec`, default 300s) with Restart now /
  Postpone — the engine no longer reboots out from under an interactive user. Headless (no user),
  the engine reboots itself after `rebootDelaySeconds` as before. `policy=never` never reboots.
- `winget.excludePattern` (default `NVIDIA|GeForce|Claude|Anthropic`) — per-item skip of pinned/
  self-updating packages now that winget upgrades one at a time. `notify.enabled` config toggle.
- `Get-Config` merges the on-disk config over defaults, so a config written by an older version
  still resolves keys added later.

## [0.2.0] - 2026-06-27

### Added
- **Three-tier logging for fast failure diagnosis:**
  - `logs\autoupdate.log` — curated rolling timeline, now rotated at 5MB × 5.
  - `logs\runs\<yyyy-MM-dd_HHmmss>\` — isolated per-run directory (retention: last `keepRuns`, default 30),
    holding `run.log` (this run's timeline), `transcript.log` (full Start-Transcript capture), a
    `<component>.log` with the **raw output of every tool** (defender/windowsupdate/winget/dell-apply/
    dell-bios-scan/psmodules), and `result.json` (structured per-component result).
  - `logs\history.jsonl` — one compact JSON line per run (queryable trail of every run's outcome).
- Per-component **timing** + **full exception capture** (message + ScriptStackTrace) via a uniform
  `Invoke-Component` runner; each component returns a structured `{status, detail, error}`.
- New query modes: `-Mode Errors` (last failed runs with error text + tail of the relevant component
  log) and `-Mode Tail` (tail of the most recent run.log). `Status` now shows per-component status,
  durations, and flags failures with a pointer to drill in.
- `keepRuns` config key (per-run log retention).

### Changed
- Reboot is decided/recorded (`rebootAction`) in `result.json`; transcript is stopped before reboot.

## [0.1.0] - 2026-06-27

### Added
- Initial release. Deterministic once-per-day update routine replacing flaky Windows Update timing.
- SYSTEM scheduled task `AutoUpdate` with three triggers (Daily 08:00 if awake, Boot+1h, Resume+1h),
  de-duplicated to once/day via `lastrun.json` stamp.
- Components (toggleable in `config.json`): Microsoft Defender signatures, Windows + Microsoft Update
  (PSWindowsUpdate, NVIDIA driver excluded to preserve the pinned 580.97), winget upgrades,
  Dell Command Update drivers/firmware (BIOS reported only, never auto-flashed), PowerShell modules.
  pip/npm stubs present but off by default.
- Coordinated end-of-run reboot (`rebootPolicy: always`, 120s abortable countdown).
- Logging to `logs\autoupdate.log` + `REPORT.md` digests + Application event log (source `AutoUpdate`).
  Failures also raised into SysSentry `ALERTS.md`.
- `Install.ps1` installs PSWindowsUpdate + registers Microsoft Update service, best-effort installs
  Dell Command Update, registers the task, and refreshes the SysSentry baseline.

[0.8.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.8.0
[0.7.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.7.0
[0.6.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.6.0
[0.5.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.5.0
[0.4.3]: https://github.com/pizzimenti/SunUp/releases/tag/v0.4.3
[0.4.2]: https://github.com/pizzimenti/SunUp/releases/tag/v0.4.2
[0.4.1]: https://github.com/pizzimenti/SunUp/releases/tag/v0.4.1
[0.4.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.4.0
[0.3.2]: https://github.com/pizzimenti/SunUp/releases/tag/v0.3.2
[0.3.1]: https://github.com/pizzimenti/SunUp/releases/tag/v0.3.1
[0.3.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.3.0
[0.2.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.2.0
[0.1.0]: https://github.com/pizzimenti/SunUp/releases/tag/v0.1.0

