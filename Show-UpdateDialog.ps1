<#
Show-UpdateDialog.ps1 — Win11 (acrylic) WPF dialog for a SunUp cycle.

Shown after EVERY cycle (even with no updates). Reads notify\latest-updates.json.
Lists the current run's updates (normal) plus the past N days of updates (greyed,
from the payload's history[]). The dialog re-checks the live pending-reboot state:
  * reboot pending now  -> table + cancellable countdown (Restart now / Postpone)
  * reboot was required but already done (post-reboot) -> table + "Restarted to finish"
  * otherwise           -> table (or "up to date" empty state) + Close

`pendingShow` in the payload gates display: the engine sets it true each run; this
dialog clears it once shown (so the on-logon trigger only re-shows a not-yet-seen
cycle, e.g. the post-reboot summary). A reboot path leaves pendingShow set so the
summary appears after the box returns.

Runs as the interactive user (non-elevated). Must run STA.
  -DataPath <file>   alternate payload
  -Demo              show countdown but never restart; ignore pendingShow (preview)
  -Validate          build the window but don't show it, exit 0
#>
param(
  [string]$DataPath = 'C:\ProgramData\SunUp\notify\latest-updates.json',
  [switch]$Demo,
  [switch]$Validate
)
$ErrorActionPreference = 'Stop'
$Name = 'SunUp'   # window title + self-close key + reboot.log path all derive from this
try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml } catch {}

# ---- payload ----------------------------------------------------------------
if (Test-Path $DataPath) { $data = Get-Content $DataPath -Raw | ConvertFrom-Json }
else { if ($Validate) { Write-Host 'validate OK: no payload'; exit 0 } else { exit 0 } }

# Gate: nothing new to show (e.g. a logon when the last cycle was already seen).
if (-not $Demo -and -not $Validate -and -not $data.pendingShow) { exit 0 }

# Pre- vs post-reboot: the box has restarted iff it has BOOTED since the run finished. This is robust
# even for a run-signal reboot (winget/MSI 3010) that sets no OS pending flag — the old Test-PendingReboot
# proxy would misread that as "already rebooted" and silently skip the countdown. On any uncertainty we
# default to pre-reboot (show the cancellable countdown) so a needed reboot is never silently skipped.
$needsReboot = [bool]$data.rebootRequired
$rebootedSinceRun = $false
if (-not $Demo -and $needsReboot -and $data.runEndUtc) {
  try {
    $runEnd = [datetime]::Parse($data.runEndUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    $boot   = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime()
    $rebootedSinceRun = $boot -gt $runEnd
  } catch { $rebootedSinceRun = $false }   # can't tell → assume not yet rebooted → show countdown
}
$showCountdown = if ($Demo) { [bool]$data.rebootRequired } else { $needsReboot -and -not $rebootedSinceRun }
$postReboot    = $needsReboot -and $rebootedSinceRun   # required, and the box has since restarted

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
$countdown = if ($data.rebootCountdownSec -and $data.rebootCountdownSec -gt 0) { [int]$data.rebootCountdownSec } else { 300 }
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

# Mark this cycle as seen so the logon trigger won't re-show it (skip if a reboot is coming).
function Clear-PendingShow {
  if ($script:rebooting) { return }
  try { $d = Get-Content $script:dataPath -Raw | ConvertFrom-Json
        $d.pendingShow = $false
        $d | ConvertTo-Json -Depth 6 | Set-Content $script:dataPath } catch {}
}
function Invoke-Restart {
  if ($script:demo) { $script:countText.Text=''; $script:rebootLbl.Text='Demo — restart skipped.'; return }
  $script:rebooting = $true
  $rl = "C:\ProgramData\$Name\notify\reboot.log"
  # Restart-Computer -Force is the primary path: in this elevated interactive-task context
  # shutdown.exe returns exit=1 even with the privilege held (observed 2026-06-27 — only the
  # Restart-Computer fallback actually rebooted), so lead with the proven call and keep
  # shutdown.exe as the fallback. The visible countdown already served as the warning.
  try {
    "$(Get-Date -Format o) Restart-Computer -Force" | Add-Content $rl
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
  $restartBtn.Add_Click({ if ($script:timer){$script:timer.Stop()}; Invoke-Restart })
  $closeBtn.Add_Click({ if ($script:timer){$script:timer.Stop()}; try { & shutdown.exe /a 2>$null } catch {}; $script:rebootLbl.Text='Restart postponed.'; $script:countText.Text=''; Clear-PendingShow; $script:win.Close() })
}
elseif ($postReboot) {
  $rebootIcon.Text = [char]0x2714; $rebootIcon.Foreground = $okGreen   # real ✔ glyph (not the XML entity — this is a runtime .Text assignment, not XAML)
  $script:rebootLbl.Text = 'Restarted to finish updates.'
  $restartBtn.Visibility = 'Collapsed'; $closeBtn.Content = 'Close'
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

if ($Validate) { Write-Host "validate OK: $($rows.Count) rows ($count current + $(@($data.history).Count) history), countdown=$showCountdown, postReboot=$postReboot"; exit 0 }
# Replace any already-open SunUp dialog (a newer cycle supersedes the old one). Mine isn't
# shown yet, so its title isn't "$Name" yet — only prior dialogs match.
try { Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -eq $Name } | ForEach-Object { $_.CloseMainWindow() | Out-Null } } catch {}
$script:win.ShowDialog() | Out-Null
