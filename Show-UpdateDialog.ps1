<#
Show-UpdateDialog.ps1 — Win11 (acrylic) WPF dialog for a SunUp cycle.

Shown after EVERY cycle (even with no updates). Reads notify\latest-updates.json
and notify\restart-state.json. Lists the current run's updates (normal) plus the
past N days of updates (greyed, from the payload's history[]). Four modes, decided
by the pure Get-RestartDisplayState below:
  * countdown       restart expected, not yet issued -> cancellable countdown
  * postReboot      issued and the box came back -> "Restarted ... back up ..." + times
  * awaitingRestart issued but the box is STILL ON THE SAME BOOT (aborted or blocked
                    shutdown) -> says so, offers a MANUAL restart, retries nothing
  * none            table, or the "up to date" empty state

As of v0.17.0 the countdown here is the FALLBACK path. Show-RestartToast.ps1 owns
the restart normally; this window takes over only when the toast cannot be shown.

Which mode applies is decided on BOOT IDENTITY, not on comparing two timestamps.
Until v0.17.0 it was the latter, and this script re-parsed a value ConvertFrom-Json
had already turned into a [datetime] -- which added the local offset, put the run's
end seven hours in the future, and made "has the box rebooted yet?" permanently
false. It armed a fresh countdown at every logon and restarted this machine three
times in seventy minutes on 2026-08-12. See RebootState.ps1's header.

`pendingShow` in the payload gates display: the engine sets it true each run; this
dialog clears it once shown (so the on-logon trigger only re-shows a not-yet-seen
cycle, e.g. the post-reboot summary). A reboot path leaves pendingShow set so the
summary appears after the box returns -- which is safe precisely because the record
now decides, so a surviving pendingShow can no longer re-arm anything.

Runs as the interactive user at RunLevel Highest -- ELEVATED, so it can actually restart the
box. (It was documented as non-elevated for several releases and is not; a security review of
v0.17.0 caught the discrepancy. It matters: anything this window trusts, it trusts with an
administrator token.) Must run STA.
  -DataPath <file>          alternate payload
  -RestartStatePath <file>  alternate restart record (fixtures in tests)
  -Demo                     show countdown but never restart; ignore pendingShow
  -Validate                 build the window but don't show it, print mode, exit 0
#>
param(
  [string]$DataPath = 'C:\ProgramData\SunUp\notify\latest-updates.json',
  [string]$RestartStatePath = 'C:\ProgramData\SunUp\notify\restart-state.json',
  [switch]$Demo,
  [switch]$Validate
)
$ErrorActionPreference = 'Stop'
$Name = 'SunUp'   # window title + self-close key + reboot.log path all derive from this
try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml } catch {}

# Timestamp handling and boot identity are shared verbatim with the engine and the tray
# (RebootState.ps1, deployed alongside this script in bin\). Until v0.17.0 this dialog was the ONE
# consumer that did not dot-source it, and carried its own re-parse of the payload's runEndUtc --
# which is what restarted this box three times in seventy minutes on 2026-08-12. See that file's
# header for the full autopsy. bin\ is readable by BUILTIN\Users, and Install.ps1 now asserts that
# rather than relying on inheritance.
$RebootStateScript = Join-Path $PSScriptRoot 'RebootState.ps1'
if (Test-Path $RebootStateScript) { . $RebootStateScript }
else {
  # Degraded, and deliberately NOT a reimplementation. Without the shared file this dialog will show
  # the update table and nothing else: no countdown, no restart button, no restart decision at all.
  #
  # That is the whole lesson of this release stated as code. A second copy of the restart decision
  # is exactly what restarted this box three times, and a copy written in a hurry inside a fallback
  # nobody exercises is the likeliest of all to drift. Showing a summary without restart controls
  # costs the user a manual restart they were going to be asked for anyway; getting the decision
  # wrong costs them their work. So the fallback answers 'none' and says so, loudly, in the log it
  # can still write.
  function Get-RestartRecord { param([string]$Path) $null }
  function Get-BootLocal { try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { $null } }
  function Get-BootEpoch { $null }
  function Test-BootedSince { param($Utc) $false }
  function ConvertTo-UtcTime { param($Value, [switch]$AllowFuture) $null }
  function Format-LocalStamp { param($Value) '' }
  function Get-RestartDisplayState {
    param($Data, $Record = $null, $BootEpoch = $null, [bool]$BootedSinceRun = $false, $BootLocal = $null, [switch]$Demo)
    [pscustomobject][ordered]@{ Mode = 'none'; CountdownSec = 300; ExecutedLocal = $null
                                BootedLocal = $BootLocal; DowntimeSec = $null; Trigger = $null }
  }
  try {
    "$((Get-Date).ToString('o')) DEGRADED: bin\RebootState.ps1 not found -- summary shown without restart controls" |
      Add-Content "C:\ProgramData\$Name\notify\reboot.log"
  } catch {}
}

# Get-RestartRecord / Save-RestartRecord / New-RestartRecord / Get-RestartDisplayState /
# Format-LocalStamp all come from RebootState.ps1, shared verbatim with Show-RestartToast.ps1 (which
# runs under 5.1 and needs the identical answer) and exercised directly by the test suite. Keeping
# the decision here, in a WPF file that cannot be loaded headlessly, is what left it untested and
# wrong for nine months.

# ---- payload ----------------------------------------------------------------
if (Test-Path $DataPath) { $data = Get-Content $DataPath -Raw | ConvertFrom-Json }
else { if ($Validate) { Write-Host 'validate OK: no payload'; exit 0 } else { exit 0 } }

# Gate: nothing new to show (e.g. a logon when the last cycle was already seen).
if (-not $Demo -and -not $Validate -and -not $data.pendingShow) { exit 0 }

# Pre- vs post-reboot: the box has restarted iff it has BOOTED since the run finished. This is robust
# even for a run-signal reboot (winget/MSI 3010) that sets no OS pending flag — the old Test-PendingReboot
# proxy would misread that as "already rebooted" and silently skip the countdown. On any uncertainty we
# default to pre-reboot (show the cancellable countdown) so a needed reboot is never silently skipped.
#
# The comparison itself now lives in Test-BootedSince (RebootState.ps1), which routes the payload
# value through the ONE guarded reader. The version that used to sit here called
# [datetime]::Parse() on a value ConvertFrom-Json had ALREADY deserialized into a [datetime]; that
# stringifies through the current culture, drops the 'Z', and re-parses as Unspecified, so the
# trailing .ToUniversalTime() added the local offset instead of nothing. runEnd landed seven hours
# in the future, "has it booted since?" was permanently false, and this dialog armed a fresh
# countdown at every logon. Three restarts on 2026-08-12, 08:09 / 09:03 / 09:09.
$needsReboot = [bool]$data.rebootRequired
# runEnd is the v0.17.0 local-with-offset field; runEndUtc is the v0.16.0 spelling, still read so a
# payload written by the previous version is understood rather than treated as unknown.
$runEndValue = if ($data.PSObject.Properties.Name -contains 'runEnd') { $data.runEnd } else { $data.runEndUtc }
$bootedSinceRun = if (-not $Demo -and $needsReboot -and $runEndValue) { [bool](Test-BootedSince $runEndValue) } else { $false }

# Three impure lookups, then one pure decision. The record wins over the timestamp: even if runEnd
# were mangled into next week, an issued record plus a changed boot still reads as postReboot.
$restartRecord = Get-RestartRecord $RestartStatePath
$bootEpochNow  = Get-BootEpoch
$bootLocalNow  = Get-BootLocal
$restart = Get-RestartDisplayState -Data $data -Record $restartRecord -BootEpoch $bootEpochNow `
                                   -BootedSinceRun $bootedSinceRun -BootLocal $bootLocalNow -Demo:$Demo

$showCountdown   = ($restart.Mode -eq 'countdown')
$postReboot      = ($restart.Mode -eq 'postReboot')
$awaitingRestart = ($restart.Mode -eq 'awaitingRestart')

# EXACTLY ONE countdown per run. As of v0.17.0 the toast normally owns it, and this window is the
# fallback for when a toast cannot be shown -- but both read the same payload and would both reach
# mode=countdown, so without this check a logon during a live toast countdown would put a second
# one on screen, racing the first to restart the box. Two countdowns for one restart is a worse
# version of the bug this release is about.
#
# Asked of the task, not of a lock file: the task's Running state IS the fact we need, it cannot go
# stale after a crash, and a failure to answer means "no toast", which lands on showing the
# countdown here -- the safe side.
$toastOwnsCountdown = $false
if ($showCountdown -and -not $Demo) {
  try { $toastOwnsCountdown = ((Get-ScheduledTask -TaskName "$Name-Restart" -ErrorAction Stop).State -eq 'Running') } catch {}
  if ($toastOwnsCountdown) { $showCountdown = $false }
}

function Format-Size { param($mb) if ($null -eq $mb -or $mb -le 0) { '—' } elseif ($mb -ge 1024) { '{0:N1} GB' -f ($mb/1024) } else { '{0:N0} MB' -f $mb } }
function Format-Dur  { param($s) if ($null -eq $s -or $s -le 0) { '—' } elseif ($s -lt 60) { "$([int]$s)s" } else { '{0}m {1:00}s' -f [math]::Floor($s/60), ([int]$s % 60) } }
function NZ { param($v) if ([string]::IsNullOrWhiteSpace("$v")) { '—' } else { "$v" } }

# Current run first (normal), then the past-Ndays history (greyed via IsPast). The When column
# distinguishes them: 'Today' for this run, the run date for history.
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($it in $data.items) {
  $rows.Add([pscustomobject]@{ When='Today'; Package=NZ $it.name; Source=NZ $it.source; OldVer=NZ $it.old; NewVer=NZ $it.new; Duration=Format-Dur $it.durationSec; Size=Format-Size $it.sizeMB; IsPast=$false })
}
foreach ($it in $data.history) {
  $rows.Add([pscustomobject]@{ When=NZ $it.when; Package=NZ $it.name; Source=NZ $it.source; OldVer=NZ $it.old; NewVer=NZ $it.new; Duration=Format-Dur $it.durationSec; Size=Format-Size $it.sizeMB; IsPast=$true })
}
$rows = @($rows)
$count     = @($data.items).Count    # current-run count drives the "N updates" chip
$hasItems  = $count -gt 0            # chips reflect THIS run
$hasRows   = $rows.Count -gt 0       # table shows if there's a current OR past row
$totalDur  = Format-Dur $data.totalDurationSec
$totalSize = Format-Size $data.totalSizeMB
$countdown = $restart.CountdownSec
$subtitle  = if ($data.runDate) { "Completed $($data.runDate)" } else { 'Completed' }

# ---- theme ------------------------------------------------------------------
$light = 1
try { $light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme } catch {}
$accentHex = '#0067C0'
try { $a=(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor
  $accentHex = '#{0:X2}{1:X2}{2:X2}' -f ($a -band 0xFF), (($a -shr 8) -band 0xFF), (($a -shr 16) -band 0xFF) } catch {}
if ($light) { $card='#E6FBFBFB'; $fg='#1A1A1A'; $sub='#5A5A5A'; $grid='#22000000'; $head='#D9ECECEC'; $alt='#0C000000'; $chip='#14000000' }
else        { $card='#D9262626'; $fg='#F2F2F2'; $sub='#B7B7B7'; $grid='#28FFFFFF'; $head='#33000000'; $alt='#14FFFFFF'; $chip='#1FFFFFFF' }
$okGreen = if ($light) { '#107C10' } else { '#6CCB5F' }

$chipsVis  = if ($hasItems) { 'Visible' } else { 'Collapsed' }   # chips summarize THIS run only
$tableVis  = if ($hasRows)  { 'Visible' } else { 'Collapsed' }   # table = current + greyed history
$emptyVis  = if ($hasRows)  { 'Collapsed' } else { 'Visible' }   # "up to date" only when nothing at all
$headGlyph = if ($hasItems) { "&#x2913;" } else { "&#x2714;" }   # down-arrow vs check

# ---- XAML -------------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Name" Width="860" SizeToContent="Height" ResizeMode="CanResizeWithGrip"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Text, Segoe UI"
        Background="Transparent" MinHeight="300">
  <Window.Resources>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="$head"/><Setter Property="Foreground" Value="$sub"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="12,8"/>
      <Setter Property="BorderBrush" Value="$grid"/><Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderBrush" Value="Transparent"/><Setter Property="Foreground" Value="$fg"/>
      <Setter Property="Padding" Value="12,9"/><Setter Property="FontSize" Value="13"/>
      <Style.Triggers>
        <!-- Past (history) rows render greyed but legible. A RowStyle Foreground can't win here:
             this cell style sets Foreground explicitly, so overriding the same property on the
             cell style via a trigger is what takes effect. {Binding IsPast} resolves per row
             because each cell's DataContext is its row data item. -->
        <DataTrigger Binding="{Binding IsPast}" Value="True">
          <Setter Property="Foreground" Value="$sub"/>
        </DataTrigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <Border Background="$card">
    <Grid Margin="24,20,24,20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,14">
        <Border Width="44" Height="44" CornerRadius="22" Background="$accentHex" VerticalAlignment="Center">
          <TextBlock Text="$headGlyph" FontSize="22" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="$($data.title)" FontSize="22" FontWeight="SemiBold" Foreground="$fg"/>
          <TextBlock Text="$subtitle" FontSize="12.5" Foreground="$sub" Margin="0,2,0,0"/>
        </StackPanel>
      </StackPanel>

      <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,14" Visibility="$chipsVis">
        <Border Background="$chip" CornerRadius="14" Padding="12,5" Margin="0,0,8,0">
          <TextBlock Foreground="$fg" FontSize="12.5"><Run FontWeight="SemiBold" Text="$count"/><Run Text=" updates"/></TextBlock></Border>
        <Border Background="$chip" CornerRadius="14" Padding="12,5" Margin="0,0,8,0">
          <TextBlock Foreground="$fg" FontSize="12.5"><Run Text="&#x2913; "/><Run FontWeight="SemiBold" Text="$totalSize"/></TextBlock></Border>
        <Border Background="$chip" CornerRadius="14" Padding="12,5">
          <TextBlock Foreground="$fg" FontSize="12.5"><Run Text="&#x23F1; "/><Run FontWeight="SemiBold" Text="$totalDur"/></TextBlock></Border>
      </StackPanel>

      <Border Grid.Row="2" CornerRadius="8" BorderBrush="$grid" BorderThickness="1" SnapsToDevicePixels="True" Visibility="$tableVis">
        <DataGrid x:Name="Grid" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                  GridLinesVisibility="All" HorizontalGridLinesBrush="$grid" VerticalGridLinesBrush="$grid"
                  Background="Transparent" RowBackground="Transparent" AlternatingRowBackground="$alt"
                  BorderThickness="0" CanUserAddRows="False" CanUserResizeRows="False"
                  ColumnHeaderHeight="38" RowHeight="40" SelectionMode="Single" Foreground="$fg"
                  ScrollViewer.HorizontalScrollBarVisibility="Disabled" MaxHeight="340">
          <DataGrid.Columns>
            <DataGridTextColumn Header="When"        Binding="{Binding When}"     Width="1.1*"/>
            <DataGridTextColumn Header="Package"     Binding="{Binding Package}"  Width="2.0*"/>
            <DataGridTextColumn Header="Source"      Binding="{Binding Source}"   Width="1*"/>
            <DataGridTextColumn Header="Old version" Binding="{Binding OldVer}"   Width="1.4*"/>
            <DataGridTextColumn Header="New version" Binding="{Binding NewVer}"   Width="1.4*"/>
            <DataGridTextColumn Header="Duration"    Binding="{Binding Duration}" Width="1*"/>
            <DataGridTextColumn Header="Size"        Binding="{Binding Size}"     Width="1*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Border>

      <Border Grid.Row="2" Visibility="$emptyVis" CornerRadius="8" Background="$alt" Padding="24,28">
        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
          <TextBlock Text="&#x2714;" FontSize="30" Foreground="$okGreen" HorizontalAlignment="Center"/>
          <TextBlock Text="You're up to date" FontSize="16" FontWeight="SemiBold" Foreground="$fg" HorizontalAlignment="Center" Margin="0,8,0,2"/>
          <TextBlock Text="The update check ran — nothing new was needed." FontSize="12.5" Foreground="$sub" HorizontalAlignment="Center"/>
        </StackPanel>
      </Border>

      <Grid Grid.Row="3" Margin="0,16,0,0">
        <StackPanel x:Name="RebootPanel" Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Left">
          <TextBlock x:Name="RebootIcon" Text="&#x21BB;" FontSize="16" Foreground="$accentHex" VerticalAlignment="Center"/>
          <TextBlock x:Name="RebootLabel" Foreground="$fg" FontSize="13" VerticalAlignment="Center" Margin="8,0,0,0"/>
          <TextBlock x:Name="CountText" Foreground="$accentHex" FontWeight="SemiBold" FontSize="13" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="RestartBtn" Content="Restart now" Height="34" MinWidth="110" Margin="0,0,8,0"
                  Background="$accentHex" Foreground="White" BorderThickness="0" FontSize="13" Cursor="Hand"/>
          <Button x:Name="CloseBtn" Height="34" MinWidth="100" Background="$chip" Foreground="$fg" BorderThickness="0" FontSize="13" Cursor="Hand"/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:win = [Windows.Markup.XamlReader]::Load($reader)
$script:win.FindName('Grid').ItemsSource = $rows
$script:countText = $script:win.FindName('CountText')
$script:rebootLbl = $script:win.FindName('RebootLabel')
$rebootPanel = $script:win.FindName('RebootPanel')
$rebootIcon  = $script:win.FindName('RebootIcon')
$restartBtn  = $script:win.FindName('RestartBtn')
$closeBtn    = $script:win.FindName('CloseBtn')
$script:demo = [bool]$Demo
$script:remain = $countdown
$script:dataPath = $DataPath
$script:rebooting = $false
$script:restartStatePath = $RestartStatePath
$script:runStamp = "$($data.runStamp)"

# Mark this cycle as seen so the logon trigger won't re-show it (skip if a reboot is coming).
#
# latest-updates.json has THREE unlocked read-modify-write writers -- the engine as SYSTEM, this
# dialog, and the tray's "Show last summary" -- so a plain Get/Set pair here could drop a whole
# payload the engine had just written, or leave a truncated file that kills the next dialog before
# it draws anything ($ErrorActionPreference is 'Stop'). Serialize on a named mutex and publish by
# rename, the same way the engine publishes every other JSON file it owns.
#
# Failing to take the lock means NOT writing. The cost is one summary shown twice; the cost of
# writing anyway is losing the run's payload.
function Clear-PendingShow {
  if ($script:rebooting) { return }
  $mx = $null; $held = $false
  try { $mx = New-Object System.Threading.Mutex($false, 'Global\SunUp-Notify') } catch {}
  if ($mx) {
    try { $held = $mx.WaitOne([timespan]::FromSeconds(5)) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }
    catch { $held = $false }
  }
  if (-not $held) { return }
  try {
    $d = Get-Content $script:dataPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $d.pendingShow = $false
    $tmp = "$($script:dataPath).tmp"
    ($d | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
    $null = Get-Content $tmp -Raw -ErrorAction Stop | ConvertFrom-Json
    Move-Item -Path $tmp -Destination $script:dataPath -Force -ErrorAction Stop
  } catch {
  } finally {
    if ($mx -and $held) { try { $mx.ReleaseMutex() } catch {} }
    if ($mx) { try { $mx.Dispose() } catch {} }
  }
}
function Invoke-Restart {
  param([string]$Trigger = 'countdown-expired')
  if ($script:demo) { $script:countText.Text=''; $script:rebootLbl.Text='Demo — restart skipped.'; return }
  $rl = "C:\ProgramData\$Name\notify\reboot.log"

  # RECORD FIRST, RESTART SECOND, and if the record cannot be written DO NOT RESTART.
  #
  # That ordering is the whole safety property. A restart we cannot record is a restart nothing can
  # later prove happened -- so the next logon sees "reboot required, no evidence of a reboot" and
  # arms another countdown, which is precisely the loop of 2026-08-12. Refusing to restart costs
  # the user one postponed update; restarting unrecorded costs them their work, repeatedly.
  #
  # The boot epoch is re-read inside New-RestartRecord rather than reused from the arm step: minutes
  # may have passed, and it is the boot we are actually leaving that has to be recorded.
  $rec = New-RestartRecord -RunStamp $script:runStamp -RequestedBy 'dialog' -Trigger $Trigger -Method 'Restart-Computer'
  $bootNow = $rec.bootAtRequestEpoch
  if (-not (Save-RestartRecord $script:restartStatePath $rec)) {
    try { "$(Get-SunUpTimestamp) ABORTED: could not write restart-state.json -- refusing to restart unrecorded" | Add-Content $rl } catch {}
    if ($script:timer) { $script:timer.Stop() }
    $script:countText.Text = ''
    $script:rebootLbl.Text = 'Could not record the restart, so it was not started. Restart manually when convenient.'
    return
  }

  $script:rebooting = $true
  # Restart-Computer -Force is the primary path: in this elevated interactive-task context
  # shutdown.exe returns exit=1 even with the privilege held (observed 2026-06-27 — only the
  # Restart-Computer fallback actually rebooted), so lead with the proven call and keep
  # shutdown.exe as the fallback. The visible countdown already served as the warning.
  try {
    "$(Get-SunUpTimestamp) run=$($script:runStamp) trigger=$Trigger method=Restart-Computer boot=$bootNow" | Add-Content $rl
    Restart-Computer -Force
  } catch {
    "$(Get-Date -Format o) Restart-Computer failed: $_ -> shutdown.exe fallback" | Add-Content $rl
    try { Start-Process shutdown.exe -ArgumentList '/r','/t','5','/c','Restarting to finish updates.' -WindowStyle Hidden }
    catch { "$(Get-Date -Format o) shutdown.exe also failed: $_" | Add-Content $rl }
  }
  $script:win.Close()
}

if ($showCountdown) {
  $script:rebootLbl.Text = 'Restart required to finish updates — restarting in '
  $closeBtn.Content = 'Postpone'
  $script:countText.Text = ('{0}:{1:00}' -f [math]::Floor($script:remain/60), ($script:remain%60))
  $script:timer = New-Object System.Windows.Threading.DispatcherTimer
  $script:timer.Interval = [TimeSpan]::FromSeconds(1)
  $script:timer.Add_Tick({
    $script:remain--
    if ($script:remain -le 0) { $script:timer.Stop(); Invoke-Restart; return }
    $script:countText.Text = ('{0}:{1:00}' -f [math]::Floor($script:remain/60), ($script:remain%60))
  })
  $restartBtn.Add_Click({ if ($script:timer){$script:timer.Stop()}; Invoke-Restart -Trigger 'user-clicked' })
  $closeBtn.Add_Click({ if ($script:timer){$script:timer.Stop()}; try { & shutdown.exe /a 2>$null } catch {}; $script:rebootLbl.Text='Restart postponed.'; $script:countText.Text=''; Clear-PendingShow; $script:win.Close() })
}
elseif ($postReboot) {
  $rebootIcon.Text = [char]0x2714; $rebootIcon.Foreground = $okGreen   # real ✔ glyph (not the XML entity — this is a runtime .Text assignment, not XAML)
  # Say WHEN, in local time. "Restarted to finish updates." left the user with no way to tell a
  # restart they slept through from one that happened while they were away from the desk -- or, on
  # 2026-08-12, one restart from the third one in an hour. The record supplies the moment we issued
  # it; LastBootUpTime supplies the moment the box came back; the gap between them is the outage.
  $txt = 'Restarted to finish updates.'
  $when = @()
  if ($restart.ExecutedLocal) { $when += "restarted $(Format-LocalStamp $restart.ExecutedLocal)" }
  if ($restart.BootedLocal)   { $when += "back up $(Format-LocalStamp $restart.BootedLocal)" }
  if ($when.Count) { $txt += '  ' + ($when -join ', ') }
  if ($null -ne $restart.DowntimeSec) { $txt += " (down $(Format-Dur $restart.DowntimeSec))" }
  $script:rebootLbl.Text = $txt
  $restartBtn.Visibility = 'Collapsed'; $closeBtn.Content = 'Close'
  $closeBtn.Add_Click({ Clear-PendingShow; $script:win.Close() })
}
elseif ($toastOwnsCountdown) {
  # A restart is coming, but the "Restarting Soon" toast is counting it down. Say so and stay out of
  # the way: no timer, no restart button, nothing here that could start a second one.
  $rebootIcon.Text = [char]0x21BB
  $script:rebootLbl.Text = 'Restart required to finish updates — see the "Restarting Soon" notification.'
  $restartBtn.Visibility = 'Collapsed'; $closeBtn.Content = 'Close'
  $closeBtn.Add_Click({ Clear-PendingShow; $script:win.Close() })
}
elseif ($awaitingRestart) {
  # We issued a restart and the machine is still on the same boot: something aborted or blocked the
  # shutdown (shutdown /a, a driver veto, an app refusing to close). Before v0.17.0 this state was
  # indistinguishable from "restart needed", so the dialog armed ANOTHER countdown and tried again.
  # Now it says what happened and hands the decision back. Manual button only -- nothing automatic
  # retries a restart the machine has already declined once.
  $rebootIcon.Text = [char]0x26A0                                       # warning sign
  $when = if ($restart.ExecutedLocal) { " at $(Format-LocalStamp $restart.ExecutedLocal)" } else { '' }
  $script:rebootLbl.Text = "A restart was requested$when but the machine has not restarted yet."
  $restartBtn.Visibility = 'Visible'; $restartBtn.Content = 'Restart now'
  $closeBtn.Content = 'Close'
  $restartBtn.Add_Click({ Invoke-Restart -Trigger 'user-clicked' })
  $closeBtn.Add_Click({ Clear-PendingShow; $script:win.Close() })
}
else {
  $rebootPanel.Visibility = 'Collapsed'; $restartBtn.Visibility = 'Collapsed'; $closeBtn.Content = 'Close'
  $closeBtn.Add_Click({ Clear-PendingShow; $script:win.Close() })
}
# Closing via the X also counts as "seen".
$script:win.Add_Closed({ Clear-PendingShow })

# NOTE: use $script:isDark here, NOT $using: — $using only works in remoting/job scriptblocks;
# in a WPF event handler it throws and the try/catch would silently skip BOTH DWM calls.
$script:isDark = ($light -eq 0)
$script:win.Add_SourceInitialized({
  try {
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:win).Handle
    Add-Type -Namespace W -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);' -ErrorAction SilentlyContinue
    $dark = [int]$script:isDark
    [W.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$dark, 4) | Out-Null    # 20 = DWMWA_USE_IMMERSIVE_DARK_MODE
    $acrylic = 3; [W.Dwm]::DwmSetWindowAttribute($h, 38, [ref]$acrylic, 4) | Out-Null  # 38 = backdrop, 3 = Acrylic
  } catch {}
  if ($showCountdown) { $script:timer.Start() }
})

if ($Validate) {
  # Mode is the load-bearing value, so -Validate prints it: that turns this switch into a real
  # integration check (run the shipped script against a fixture payload + record, assert the mode)
  # rather than only a "does it build" smoke test.
  Write-Host ("validate OK: $($rows.Count) rows ($count current + $(@($data.history).Count) history)," +
              " mode=$($restart.Mode), countdown=$showCountdown, postReboot=$postReboot," +
              " executed=$($restart.ExecutedLocal), bootedLocal=$($restart.BootedLocal), downtimeSec=$($restart.DowntimeSec)")
  exit 0
}
# Replace any already-open SunUp dialog (a newer cycle supersedes the old one). Mine isn't
# shown yet, so its title isn't "$Name" yet — only prior dialogs match.
try { Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -eq $Name } | ForEach-Object { $_.CloseMainWindow() | Out-Null } } catch {}
$script:win.ShowDialog() | Out-Null
