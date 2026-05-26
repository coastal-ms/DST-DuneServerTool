# Characters page — top picker + 7 collapsible sub-editor sections.
# Layout decision (popup B): top character picker dropdown + accordion of all 7 sections,
# all collapsed by default. Backend wiring will be added in subsequent iterations.

# -----------------------------------------------------------------------------
# Stat definitions (the 8 player stats from the reference editor)
# -----------------------------------------------------------------------------
$script:V6CharStatDefs = @(
    @{ Key='MaxHealth';          Label='Max Health';            Min=0;   Max=10000; Default=100 }
    @{ Key='TechKnowledgePoints'; Label='Tech Knowledge Points'; Min=0;   Max=10000; Default=0 }
    @{ Key='Hydration';          Label='Hydration';             Min=0;   Max=100;   Default=100 }
    @{ Key='HeatExhaustion';     Label='Heat Exhaustion';       Min=0;   Max=100;   Default=0 }
    @{ Key='Spice';              Label='Spice';                 Min=0;   Max=10000; Default=0 }
    @{ Key='AddictionLevel';     Label='Addiction Level';       Min=0;   Max=100;   Default=0 }
    @{ Key='Tolerance';          Label='Tolerance';             Min=0;   Max=100;   Default=0 }
    @{ Key='EyesOfIbad';         Label='Eyes of Ibad';          Min=0;   Max=100;   Default=0 }
)

# -----------------------------------------------------------------------------
# Page construction
# -----------------------------------------------------------------------------
function New-V6CharactersPage {
    $xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Padding="24" Background="#14110D">
  <Border.Resources>
    <SolidColorBrush x:Key="ChInputBg"     Color="#0F0C09"/>
    <SolidColorBrush x:Key="ChInputFg"     Color="#F0E6D0"/>
    <SolidColorBrush x:Key="ChInputBorder" Color="#4A361F"/>
    <SolidColorBrush x:Key="ChIbadBlue"    Color="#5DD3FF"/>
    <SolidColorBrush x:Key="ChIbadBlueDim" Color="#2A6F8E"/>
    <SolidColorBrush x:Key="ChGold"        Color="#E8B872"/>
    <SolidColorBrush x:Key="ChSubtle"      Color="#8E8270"/>
    <SolidColorBrush x:Key="ChCardBg"      Color="#1C1813"/>
    <SolidColorBrush x:Key="ChCardBorder"  Color="#4A361F"/>

    <Style TargetType="TextBox">
      <Setter Property="Background"    Value="{StaticResource ChInputBg}"/>
      <Setter Property="Foreground"    Value="{StaticResource ChInputFg}"/>
      <Setter Property="BorderBrush"   Value="{StaticResource ChInputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CaretBrush"    Value="{StaticResource ChIbadBlue}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource ChIbadBlue}"/>
      <Setter Property="Padding"       Value="6,3"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="BorderBrush" Value="{StaticResource ChIbadBlue}"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter Property="BorderBrush" Value="{StaticResource ChIbadBlue}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="{StaticResource ChInputBg}"/>
      <Setter Property="Foreground" Value="{StaticResource ChInputFg}"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource ChIbadBlue}"/>
                <Setter Property="Foreground" Value="#000000"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource ChIbadBlueDim}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Background"      Value="{StaticResource ChInputBg}"/>
      <Setter Property="Foreground"      Value="{StaticResource ChInputFg}"/>
      <Setter Property="BorderBrush"     Value="{StaticResource ChInputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding"         Value="6,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="22"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="CbBorder" Grid.ColumnSpan="2"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"
                      CornerRadius="2"/>
              <ContentPresenter Grid.Column="0" Margin="8,0,0,0" VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                IsHitTestVisible="False"/>
              <ToggleButton Grid.Column="1" Focusable="False"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                            ClickMode="Press" Background="Transparent" BorderThickness="0">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent">
                      <Path HorizontalAlignment="Center" VerticalAlignment="Center"
                            Data="M 0 0 L 8 0 L 4 5 Z" Fill="{StaticResource ChInputFg}"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="{StaticResource ChInputBg}" BorderBrush="{StaticResource ChInputBorder}"
                        BorderThickness="1" MinWidth="{TemplateBinding ActualWidth}">
                  <ScrollViewer MaxHeight="280">
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="CbBorder" Property="BorderBrush" Value="{StaticResource ChIbadBlue}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="CbBorder" Property="BorderBrush" Value="{StaticResource ChIbadBlue}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Expander: use default template, just restyle colors -->
    <Style TargetType="Expander">
      <Setter Property="Background" Value="{StaticResource ChCardBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ChCardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{StaticResource ChGold}"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Padding" Value="14"/>
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
  </Border.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- Title row -->
    <Grid Grid.Row="0" Margin="0,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Text="Characters" FontFamily="Segoe UI Semibold" FontSize="22"
                   Foreground="{StaticResource ChGold}"/>
        <TextBlock Margin="0,4,0,0" Foreground="{StaticResource ChSubtle}"
                   Text="Pick a character, then expand a section to view or edit. Writes hit the live Postgres DB on the VM \u2014 always take a backup first."/>
      </StackPanel>
      <Border Grid.Column="1" x:Name="ChDirtyPill" Background="#3F2A10" BorderBrush="{StaticResource ChGold}"
              BorderThickness="1" CornerRadius="10" Padding="10,4" VerticalAlignment="Center" Visibility="Collapsed">
        <TextBlock Text="Unsaved changes" Foreground="{StaticResource ChGold}" FontSize="11"/>
      </Border>
    </Grid>

    <!-- Stop-bg banner -->
    <Border x:Name="ChStopBanner" Grid.Row="1" Margin="0,0,0,12" Padding="14,10"
            Background="#3A2410" BorderBrush="#E89C42" BorderThickness="1" CornerRadius="6" Visibility="Collapsed">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="!" Foreground="#E89C42" FontSize="18" FontWeight="Bold" Margin="0,0,10,0"/>
        <TextBlock Foreground="#F0D8A8" VerticalAlignment="Center" TextWrapping="Wrap"
                   Text="Battlegroup is running. Stop it from the Terminal pane before applying writes \u2014 live edits can corrupt active sessions."/>
      </StackPanel>
    </Border>

    <!-- Picker row -->
    <Border Grid.Row="2" Background="{StaticResource ChCardBg}" BorderBrush="{StaticResource ChCardBorder}"
            BorderThickness="1" CornerRadius="6" Padding="14" Margin="0,0,0,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="Character:" VerticalAlignment="Center" Margin="0,0,12,0"
                   Foreground="{StaticResource ChInputFg}"/>
        <ComboBox  Grid.Column="1" x:Name="ChPicker" Height="30" IsEditable="False"/>
        <Button    Grid.Column="2" x:Name="ChBtnLoad"    Content="Load List"  Width="100" Height="30" Margin="12,0,8,0"/>
        <Button    Grid.Column="3" x:Name="ChBtnBackup"  Content="Backup DB"  Width="100" Height="30" Margin="0,0,8,0"/>
        <Button    Grid.Column="4" x:Name="ChBtnSave"    Content="Save"       Width="100" Height="30"/>
      </Grid>
    </Border>

    <!-- Status row -->
    <TextBlock Grid.Row="3" x:Name="ChStatus" Margin="2,0,0,10" Foreground="{StaticResource ChSubtle}" FontSize="11"
               Text="Click Load List to fetch characters from the VM Postgres database."/>

    <!-- Accordion scroll -->
    <ScrollViewer Grid.Row="4" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel x:Name="ChAccordion">

        <Expander Header="Stats" x:Name="ChExpStats" IsExpanded="False">
          <StackPanel x:Name="ChStatsBody"/>
        </Expander>

        <Expander Header="Inventory" x:Name="ChExpInventory" IsExpanded="False">
          <StackPanel>
            <TextBlock Foreground="{StaticResource ChSubtle}" FontStyle="Italic"
                       Text="Inventory editor \u2014 add/remove items from the 981-entry catalog. (Coming next sub-popup.)"/>
          </StackPanel>
        </Expander>

        <Expander Header="Tech Tree" x:Name="ChExpTech" IsExpanded="False">
          <StackPanel>
            <TextBlock Foreground="{StaticResource ChSubtle}" FontStyle="Italic"
                       Text="49 recipes with unlock-all / lock-all and per-row toggle. (Coming next sub-popup.)"/>
          </StackPanel>
        </Expander>

        <Expander Header="Specializations" x:Name="ChExpSpecs" IsExpanded="False">
          <StackPanel>
            <TextBlock Foreground="{StaticResource ChSubtle}" FontStyle="Italic"
                       Text="5 trees (Combat, Crafting, Exploration, Gathering, Sabotage) + 205 keystones. (Coming next sub-popup.)"/>
          </StackPanel>
        </Expander>

        <Expander Header="Economy" x:Name="ChExpEconomy" IsExpanded="False">
          <StackPanel>
            <TextBlock Foreground="{StaticResource ChSubtle}" FontStyle="Italic"
                       Text="Solari + House Scrip balance setters. (Coming next sub-popup.)"/>
          </StackPanel>
        </Expander>

        <Expander Header="Faction Reputation" x:Name="ChExpFaction" IsExpanded="False">
          <StackPanel>
            <TextBlock Foreground="{StaticResource ChSubtle}" FontStyle="Italic"
                       Text="Atreides / Harkonnen / Smuggler sliders. (Coming next sub-popup.)"/>
          </StackPanel>
        </Expander>

        <Expander Header="Cosmetics" x:Name="ChExpCosmetics" IsExpanded="False">
          <StackPanel>
            <TextBlock Foreground="{StaticResource ChSubtle}" FontStyle="Italic"
                       Text="Weapon skins / armor skins / dye packs / vehicle cosmetics. (Coming next sub-popup.)"/>
          </StackPanel>
        </Expander>

      </StackPanel>
    </ScrollViewer>
  </Grid>
</Border>
'@
    $page = [Windows.Markup.XamlReader]::Parse($xaml)
    return @{
        Root        = $page
        Picker      = $page.FindName('ChPicker')
        BtnLoad     = $page.FindName('ChBtnLoad')
        BtnBackup   = $page.FindName('ChBtnBackup')
        BtnSave     = $page.FindName('ChBtnSave')
        DirtyPill   = $page.FindName('ChDirtyPill')
        StopBanner  = $page.FindName('ChStopBanner')
        Status      = $page.FindName('ChStatus')
        StatsBody   = $page.FindName('ChStatsBody')
        ExpStats    = $page.FindName('ChExpStats')
        StatControls= @{}
        Original    = @{}
        Dirty       = $false
        Characters  = @()
        SelectedId  = $null
    }
}

function _V6ChSetDirty {
    param($c, [bool]$Value)
    $c.Dirty = $Value
    $c.DirtyPill.Visibility = if ($Value) { 'Visible' } else { 'Collapsed' }
}

function _V6ChBuildStatsBody {
    param($state)
    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

    $row = 0; $col = 0
    foreach ($s in $script:V6CharStatDefs) {
        if ($col -eq 0) {
            $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height=[System.Windows.GridLength]::Auto}))
        }
        $cell = New-Object System.Windows.Controls.StackPanel
        $cell.Margin = '0,0,16,12'
        [System.Windows.Controls.Grid]::SetRow($cell, $row)
        [System.Windows.Controls.Grid]::SetColumn($cell, $col)

        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = "$($s.Label)  ($($s.Min)-$($s.Max))"
        $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xD8,0xCD,0xB5))
        $lbl.FontSize = 12
        $lbl.Margin = '0,0,0,5'
        $cell.Children.Add($lbl) | Out-Null

        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Height = 28
        $tb.Text = "$($s.Default)"
        $tb.IsEnabled = $false
        $tb.Add_TextChanged({ _V6ChSetDirty $script:V6Ch $true }.GetNewClosure())
        $cell.Children.Add($tb) | Out-Null

        $grid.Children.Add($cell) | Out-Null
        $state.StatControls[$s.Key] = $tb

        $col++
        if ($col -ge 2) { $col = 0; $row++ }
    }
    $state.StatsBody.Children.Add($grid) | Out-Null
}

function Initialize-V6CharactersPage {
    if ($script:V6Ch) { return }
    if (-not $ui -or -not $ui.PageCharacters) { return }

    $state = New-V6CharactersPage
    $ui.PageCharacters.Child = $state.Root
    $script:V6Ch = $state

    _V6ChBuildStatsBody -state $state

    $state.BtnLoad.Add_Click({
        $c = $script:V6Ch
        $c.Status.Text = 'Loading characters from VM Postgres... (backend not yet wired - sub-popup checkpoint pending)'
        # Placeholder: pretend to load two characters so the picker is exercisable
        $c.Picker.Items.Clear()
        foreach ($name in @('(demo) Paul Atreides','(demo) Chani','(demo) Stilgar')) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $name
            $item.Tag = $name
            $c.Picker.Items.Add($item) | Out-Null
        }
        if ($c.Picker.Items.Count -gt 0) { $c.Picker.SelectedIndex = 0 }
        $c.Status.Text = "Loaded $($c.Picker.Items.Count) demo characters. Real DB wiring next."
    })

    $state.Picker.Add_SelectionChanged({
        $c = $script:V6Ch
        $sel = $c.Picker.SelectedItem
        if (-not $sel) { return }
        $c.SelectedId = $sel.Tag
        # Demo: enable stat fields so the user can see the editor
        foreach ($k in $c.StatControls.Keys) {
            $c.StatControls[$k].IsEnabled = $true
        }
        _V6ChSetDirty $c $false
        $c.Status.Text = "Selected: $($sel.Content)  -  expand a section to view or edit."
    })

    $state.BtnBackup.Add_Click({
        $c = $script:V6Ch
        $cmd = $script:Commands | Where-Object { $_.Section -eq 'Battlegroup' -and $_.Key -eq '9' } | Select-Object -First 1
        if ($cmd -and (Get-Command Invoke-DuneCmd -ErrorAction SilentlyContinue)) {
            if ($ui.NavTerminal) { $ui.NavTerminal.IsChecked = $true }
            Invoke-DuneCmd -Cmd $cmd
            $c.Status.Text = 'Backup dispatched to Terminal.'
        } else {
            $c.Status.Text = 'Could not find backup command in catalog.'
        }
    })

    $state.BtnSave.Add_Click({
        $c = $script:V6Ch
        $c.Status.Text = 'Save -> Postgres write path not yet wired (sub-popup pending). UI captures dirty state.'
    })

    # Disable buttons until backend is wired
    $state.BtnSave.IsEnabled = $false
}

function Update-V6Characters {
    if (-not $script:V6Ch) { return }
    $c = $script:V6Ch
    $bgRunning = $false
    try {
        $snap = Get-BattlegroupStatusSnapshot
        if ($snap -and $snap.available) {
            $state = Get-BgStateFromStatusText $snap.output
            if ($state -eq 'Running') { $bgRunning = $true }
        }
    } catch {}
    $c.StopBanner.Visibility = if ($bgRunning) { 'Visible' } else { 'Collapsed' }
}
