<#
Show-UpdateDialog.ps1 — a Win11-styled (acrylic) WPF dialog summarizing an AutoUpdate run.

Reads a JSON payload (default C:\ProgramData\AutoUpdate\latest-updates.json) written
by the engine and renders a gridlined table of each update (package, source, old/new
version, duration, size). When a restart is required it owns a VISIBLE, CANCELLABLE
countdown — the SYSTEM engine never reboots out from under a logged-in user; this dialog
does, only after the countdown or an explicit "Restart now".

Runs in the INTERACTIVE USER session (SYSTEM can't show UI), launched by AutoUpdate-Notify.
Must run STA:  pwsh -STA -File Show-UpdateDialog.ps1
  -DataPath <file>   alternate payload
  -Demo              show countdown but never actually restart (safe preview)
  -Validate          build the window but don't show it, exit 0
#>
param(
  [string]$DataPath = 'C:\ProgramData\AutoUpdate\latest-updates.json',
  [switch]$Demo,
  [switch]$Validate
)
$ErrorActionPreference = 'Stop'
try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml } catch {}

# ---- payload ----------------------------------------------------------------
if (Test-Path $DataPath) { $data = Get-Content $DataPath -Raw | ConvertFrom-Json }
else { $data = [pscustomobject]@{ title='Updates installed'; runDate=''; items=@(); totalDurationSec=0; totalSizeMB=0; rebootRequired=$false; rebootCountdownSec=300 } }

function Format-Size { param($mb)
  if ($null -eq $mb -or $mb -le 0) { return '—' }
  if ($mb -ge 1024) { return ('{0:N1} GB' -f ($mb / 1024)) }
  return ('{0:N0} MB' -f $mb)
}
function Format-Dur { param($s)
  if ($null -eq $s -or $s -le 0) { return '—' }
  $s = [int][math]::Round($s)
  if ($s -lt 60) { return "${s}s" }
  return ('{0}m {1:00}s' -f [math]::Floor($s/60), ($s % 60))
}
function NZ { param($v) if ([string]::IsNullOrWhiteSpace("$v")) { '—' } else { "$v" } }

$rows = @(foreach ($it in $data.items) {
  [pscustomobject]@{
    Package = NZ $it.name; Source = NZ $it.source; OldVer = NZ $it.old
    NewVer  = NZ $it.new;  Duration = Format-Dur $it.durationSec; Size = Format-Size $it.sizeMB
  }
})

$count     = $rows.Count
$totalDur  = Format-Dur $data.totalDurationSec
$totalSize = Format-Size $data.totalSizeMB
$reboot    = [bool]$data.rebootRequired
$subtitle  = if ($data.runDate) { "Completed $($data.runDate)" } else { 'Completed' }
$countdown = if ($data.rebootCountdownSec -and $data.rebootCountdownSec -gt 0) { [int]$data.rebootCountdownSec } else { 300 }

# ---- theme (honor Win11 light/dark + accent) --------------------------------
$light = 1
try { $light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme } catch {}
$accentHex = '#0067C0'
try {
  $a = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor
  $b=($a -shr 16)-band 0xFF; $g=($a -shr 8)-band 0xFF; $r=$a -band 0xFF
  $accentHex = '#{0:X2}{1:X2}{2:X2}' -f $r,$g,$b
} catch {}

if ($light) {
  # 'card' carries an alpha (E6 ≈ 90%) so the acrylic backdrop diffuses through subtly.
  $card='#E6FBFBFB'; $fg='#1A1A1A'; $sub='#5A5A5A'; $grid='#22000000'; $head='#D9ECECEC'; $alt='#0C000000'; $chip='#14000000'
} else {
  $card='#D9262626'; $fg='#F2F2F2'; $sub='#B7B7B7'; $grid='#28FFFFFF'; $head='#33000000'; $alt='#14FFFFFF'; $chip='#1FFFFFFF'
}

# ---- XAML -------------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AutoUpdate" Width="800" SizeToContent="Height" ResizeMode="CanResizeWithGrip"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Text, Segoe UI"
        Background="Transparent" MinHeight="340">
  <Window.Resources>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="$head"/>
      <Setter Property="Foreground" Value="$sub"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="BorderBrush" Value="$grid"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="$fg"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
  </Window.Resources>

  <!-- frosted card; its alpha lets the acrylic backdrop diffuse through -->
  <Border Background="$card" CornerRadius="0">
    <Grid Margin="24,20,24,20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- header -->
      <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,14">
        <Border Width="44" Height="44" CornerRadius="22" Background="$accentHex" VerticalAlignment="Center">
          <TextBlock Text="&#x2913;" FontSize="22" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="$($data.title)" FontSize="22" FontWeight="SemiBold" Foreground="$fg"/>
          <TextBlock Text="$subtitle" FontSize="12.5" Foreground="$sub" Margin="0,2,0,0"/>
        </StackPanel>
      </StackPanel>

      <!-- summary chips -->
      <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,14">
        <Border Background="$chip" CornerRadius="14" Padding="12,5" Margin="0,0,8,0">
          <TextBlock Foreground="$fg" FontSize="12.5"><Run FontWeight="SemiBold" Text="$count"/><Run Text=" updates"/></TextBlock></Border>
        <Border Background="$chip" CornerRadius="14" Padding="12,5" Margin="0,0,8,0">
          <TextBlock Foreground="$fg" FontSize="12.5"><Run Text="&#x2913; "/><Run FontWeight="SemiBold" Text="$totalSize"/></TextBlock></Border>
        <Border Background="$chip" CornerRadius="14" Padding="12,5">
          <TextBlock Foreground="$fg" FontSize="12.5"><Run Text="&#x23F1; "/><Run FontWeight="SemiBold" Text="$totalDur"/></TextBlock></Border>
      </StackPanel>

      <!-- table -->
      <Border Grid.Row="2" CornerRadius="8" BorderBrush="$grid" BorderThickness="1" SnapsToDevicePixels="True">
        <DataGrid x:Name="Grid" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                  GridLinesVisibility="All" HorizontalGridLinesBrush="$grid" VerticalGridLinesBrush="$grid"
                  Background="Transparent" RowBackground="Transparent" AlternatingRowBackground="$alt"
                  BorderThickness="0" CanUserAddRows="False" CanUserResizeRows="False"
                  ColumnHeaderHeight="38" RowHeight="40" SelectionMode="Single" Foreground="$fg"
                  ScrollViewer.HorizontalScrollBarVisibility="Disabled" MaxHeight="340">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Package"     Binding="{Binding Package}"  Width="2.2*"/>
            <DataGridTextColumn Header="Source"      Binding="{Binding Source}"   Width="1*"/>
            <DataGridTextColumn Header="Old version" Binding="{Binding OldVer}"   Width="1.5*"/>
            <DataGridTextColumn Header="New version" Binding="{Binding NewVer}"   Width="1.5*"/>
            <DataGridTextColumn Header="Duration"    Binding="{Binding Duration}" Width="1*"/>
            <DataGridTextColumn Header="Size"        Binding="{Binding Size}"     Width="1*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Border>

      <!-- footer: countdown (only if reboot) + buttons -->
      <Grid Grid.Row="3" Margin="0,16,0,0">
        <StackPanel x:Name="RebootPanel" Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Left">
          <TextBlock Text="&#x21BB;" FontSize="16" Foreground="$accentHex" VerticalAlignment="Center"/>
          <TextBlock x:Name="RebootLabel" Foreground="$fg" FontSize="13" VerticalAlignment="Center" Margin="8,0,0,0"
                     Text="Restart required to finish updates — restarting in "/>
          <TextBlock x:Name="CountText" Foreground="$accentHex" FontWeight="SemiBold" FontSize="13" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="RestartBtn" Content="Restart now" Height="34" MinWidth="110" Margin="0,0,8,0"
                  Background="$accentHex" Foreground="White" BorderThickness="0" FontSize="13" Cursor="Hand"/>
          <Button x:Name="CloseBtn" Height="34" MinWidth="100" Background="$chip" Foreground="$fg"
                  BorderThickness="0" FontSize="13" Cursor="Hand"/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:win = [Windows.Markup.XamlReader]::Load($reader)
$grid = $script:win.FindName('Grid'); $grid.ItemsSource = $rows
$script:countText  = $script:win.FindName('CountText')
$script:rebootLbl  = $script:win.FindName('RebootLabel')
$rebootPanel = $script:win.FindName('RebootPanel')
$restartBtn  = $script:win.FindName('RestartBtn')
$closeBtn    = $script:win.FindName('CloseBtn')
$script:demo = [bool]$Demo
$script:remain = $countdown

function Invoke-Restart {
  if ($script:demo) { $script:countText.Text=''; $script:rebootLbl.Text='Demo — restart skipped.'; return }
  Start-Process shutdown.exe -ArgumentList '/r','/t','5','/c','Restarting to finish updates.'
  $script:win.Close()
}
function Stop-Countdown { if ($script:timer) { $script:timer.Stop() } ; try { & shutdown.exe /a 2>$null } catch {} }

if ($reboot) {
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
  $closeBtn.Add_Click({ Stop-Countdown; $script:rebootLbl.Text='Restart postponed.'; $script:countText.Text=''; $script:win.Close() })
} else {
  $rebootPanel.Visibility = 'Collapsed'
  $restartBtn.Visibility  = 'Collapsed'
  $closeBtn.Content = 'Close'
  $closeBtn.Add_Click({ $script:win.Close() })
}

# Acrylic backdrop + theme-matched title bar (Win11 22H2+; degrades gracefully).
$script:win.Add_SourceInitialized({
  try {
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:win).Handle
    Add-Type -Namespace W -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);' -ErrorAction SilentlyContinue
    $dark = [int]([int]$using:light -eq 0)
    [W.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$dark, 4) | Out-Null     # immersive dark title bar
    $acrylic = 3; [W.Dwm]::DwmSetWindowAttribute($h, 38, [ref]$acrylic, 4) | Out-Null  # 3 = Acrylic (diffused)
  } catch {}
  if ($reboot) { $script:timer.Start() }
})

if ($Validate) { Write-Host "validate OK: $count rows, reboot=$reboot, countdown=$countdown"; exit 0 }
$script:win.ShowDialog() | Out-Null
