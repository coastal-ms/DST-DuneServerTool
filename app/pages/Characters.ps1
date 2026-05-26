# Characters page — top picker + 7 collapsible sub-editor sections.
# Layout decision (popup B): top character picker dropdown + accordion of all 7 sections,
# all collapsed by default. Backend wiring will be added in subsequent iterations.

# -----------------------------------------------------------------------------
# Stat definitions (the 8 player stats) with their JSON-path mappings into
# `actors.properties` or `actors.gas_attributes`. Sourced from the reference
# index.html data-field/data-path attributes.
# -----------------------------------------------------------------------------
$script:V6CharStatDefs = @(
    @{ Key='MaxHealth';     Label='Max Health';            Field='properties';     Path='DamageableActorComponent.m_TotalMaxHealth';                 Min=1;     Max=10000; Step=1;   Default=100 }
    @{ Key='TechPoints';    Label='Tech Knowledge Points'; Field='properties';     Path='TechKnowledgePlayerComponent.m_TechKnowledgePoints';        Min=0;     Max=10000; Step=1;   Default=0 }
    @{ Key='Hydration';     Label='Hydration';             Field='gas_attributes'; Path='DuneHydrationAttributeSet.CurrentHydration';                Min=0;     Max=100;   Step=0.1; Default=100 }
    @{ Key='HeatExhaustion'; Label='Heat Exhaustion';      Field='gas_attributes'; Path='DuneHydrationAttributeSet.HeatExhaustion';                  Min=0;     Max=100;   Step=0.1; Default=0 }
    @{ Key='Spice';         Label='Spice';                 Field='gas_attributes'; Path='DuneSpiceAddictionAttributeSet.CurrentSpice';               Min=0;     Max=10000; Step=1;   Default=0 }
    @{ Key='AddictionLevel'; Label='Addiction Level';      Field='gas_attributes'; Path='DuneSpiceAddictionAttributeSet.SpiceAddictionLevel';        Min=0;     Max=100;   Step=0.1; Default=0 }
    @{ Key='Tolerance';     Label='Tolerance';             Field='gas_attributes'; Path='DuneSpiceAddictionAttributeSet.SpiceTolerance';             Min=0;     Max=100;   Step=0.1; Default=0 }
    @{ Key='EyesOfIbad';    Label='Eyes of Ibad';          Field='properties';     Path='BP_DunePlayerCharacter_C.m_EyesOfIbadValue';                Min=0;     Max=1;     Step=0.05; Default=0 }
)

$script:V6SpecTracks = @('Combat','Crafting','Exploration','Gathering','Sabotage')
$script:V6CurrencyDefs = @(
    @{ Id=0; Label='Solari' }
    @{ Id=1; Label='House Scrip' }
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
          <StackPanel x:Name="ChInvBody">
            <TextBlock Foreground="{StaticResource ChSubtle}" FontStyle="Italic"
                       Text="Inventory editor coming in the next sub-popup (catalog-driven)."/>
          </StackPanel>
        </Expander>

        <Expander Header="Tech Tree" x:Name="ChExpTech" IsExpanded="False">
          <StackPanel x:Name="ChTechBody"/>
        </Expander>

        <Expander Header="Specializations" x:Name="ChExpSpecs" IsExpanded="False">
          <StackPanel x:Name="ChSpecsBody"/>
        </Expander>

        <Expander Header="Economy" x:Name="ChExpEconomy" IsExpanded="False">
          <StackPanel x:Name="ChEconBody"/>
        </Expander>

        <Expander Header="Faction Reputation" x:Name="ChExpFaction" IsExpanded="False">
          <StackPanel x:Name="ChFactionBody"/>
        </Expander>

        <Expander Header="Cosmetics" x:Name="ChExpCosmetics" IsExpanded="False">
          <StackPanel x:Name="ChCosmeticsBody">
            <TextBlock Foreground="{StaticResource ChSubtle}" FontStyle="Italic"
                       Text="Cosmetics editor coming in the next sub-popup (catalog-driven)."/>
          </StackPanel>
        </Expander>

      </StackPanel>
    </ScrollViewer>
  </Grid>
</Border>
'@
    $page = [Windows.Markup.XamlReader]::Parse($xaml)
    return @{
        Root          = $page
        Picker        = $page.FindName('ChPicker')
        BtnLoad       = $page.FindName('ChBtnLoad')
        BtnBackup     = $page.FindName('ChBtnBackup')
        BtnSave       = $page.FindName('ChBtnSave')
        DirtyPill     = $page.FindName('ChDirtyPill')
        StopBanner    = $page.FindName('ChStopBanner')
        Status        = $page.FindName('ChStatus')

        StatsBody     = $page.FindName('ChStatsBody')
        TechBody      = $page.FindName('ChTechBody')
        SpecsBody     = $page.FindName('ChSpecsBody')
        EconBody      = $page.FindName('ChEconBody')
        FactionBody   = $page.FindName('ChFactionBody')
        InvBody       = $page.FindName('ChInvBody')
        CosmeticsBody = $page.FindName('ChCosmeticsBody')

        ExpStats      = $page.FindName('ChExpStats')

        StatControls    = @{}    # statKey -> TextBox
        SpecControls    = @{}    # trackType -> @{Level=TextBox; Xp=TextBox}
        CurrencyControls= @{}    # currencyId -> TextBox
        FactionControls = @{}    # factionId -> @{Tb=TextBox; Label=...}
        TechStatusText  = $null  # TextBlock under tech buttons

        Detail        = $null    # last-loaded Get-V6CharacterDetail result
        Dirty         = $false
        Characters    = @()
        SelectedId    = $null
        Vm            = $null    # last seen Get-VmStatus result
    }
}

function _V6ChSetDirty {
    param($c, [bool]$Value)
    $c.Dirty = $Value
    $c.DirtyPill.Visibility = if ($Value) { 'Visible' } else { 'Collapsed' }
}

function _V6ChMakeLabel {
    param([string]$Text, [string]$Hint = '')
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $sp.Margin = '0,0,0,5'
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $Text
    $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xD8,0xCD,0xB5))
    $lbl.FontSize = 12
    $sp.Children.Add($lbl) | Out-Null
    if ($Hint) {
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = "  $Hint"
        $h.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x8E,0x82,0x70))
        $h.FontSize = 11
        $sp.Children.Add($h) | Out-Null
    }
    return $sp
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
        $cell.Children.Add((_V6ChMakeLabel "$($s.Label)" "(min $($s.Min), max $($s.Max))")) | Out-Null

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

function _V6ChBuildTechBody {
    param($state)
    $sp = New-Object System.Windows.Controls.StackPanel

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = '0,0,0,8'

    $unlock = New-Object System.Windows.Controls.Button
    $unlock.Content = 'Unlock All Recipes'
    $unlock.Width = 170; $unlock.Height = 30; $unlock.Margin = '0,0,8,0'
    $unlock.IsEnabled = $false
    $unlock.Tag = 'tech-unlock'
    $unlock.Add_Click({ Invoke-V6CharTechAction -Action 'unlock' })

    $lock = New-Object System.Windows.Controls.Button
    $lock.Content = 'Lock All Recipes'
    $lock.Width = 170; $lock.Height = 30
    $lock.IsEnabled = $false
    $lock.Tag = 'tech-lock'
    $lock.Add_Click({ Invoke-V6CharTechAction -Action 'lock' })

    $row.Children.Add($unlock) | Out-Null
    $row.Children.Add($lock) | Out-Null
    $sp.Children.Add($row) | Out-Null

    $status = New-Object System.Windows.Controls.TextBlock
    $status.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x8E,0x82,0x70))
    $status.FontSize = 11
    $status.Text = 'Select a character to enable. Bulk unlock/lock affects all 49 recipes server-side immediately.'
    $sp.Children.Add($status) | Out-Null

    $state.TechStatusText = $status
    $state.TechBody.Children.Add($sp) | Out-Null
}

function _V6ChBuildSpecsBody {
    param($state)
    $sp = New-Object System.Windows.Controls.StackPanel
    foreach ($track in $script:V6SpecTracks) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = '0,0,0,8'
        $cw1 = New-Object System.Windows.Controls.ColumnDefinition; $cw1.Width = '120'
        $cw2 = New-Object System.Windows.Controls.ColumnDefinition; $cw2.Width = '90'
        $cw3 = New-Object System.Windows.Controls.ColumnDefinition; $cw3.Width = '110'
        $cw4 = New-Object System.Windows.Controls.ColumnDefinition; $cw4.Width = '85'
        $cw5 = New-Object System.Windows.Controls.ColumnDefinition; $cw5.Width = '*'
        foreach ($c in @($cw1,$cw2,$cw3,$cw4,$cw5)) { $row.ColumnDefinitions.Add($c) }

        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $track; $name.VerticalAlignment = 'Center'
        $name.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
        $name.FontFamily = 'Segoe UI Semibold'
        [System.Windows.Controls.Grid]::SetColumn($name, 0)
        $row.Children.Add($name) | Out-Null

        $lvl = New-Object System.Windows.Controls.TextBox
        $lvl.Height = 28; $lvl.Margin = '0,0,8,0'; $lvl.Tag = "$track|level"
        $lvl.IsEnabled = $false
        $lvl.Add_TextChanged({ _V6ChSetDirty $script:V6Ch $true }.GetNewClosure())
        [System.Windows.Controls.Grid]::SetColumn($lvl, 1)
        $row.Children.Add($lvl) | Out-Null

        $xp = New-Object System.Windows.Controls.TextBox
        $xp.Height = 28; $xp.Margin = '0,0,8,0'; $xp.Tag = "$track|xp"
        $xp.IsEnabled = $false
        $xp.Add_TextChanged({ _V6ChSetDirty $script:V6Ch $true }.GetNewClosure())
        [System.Windows.Controls.Grid]::SetColumn($xp, 2)
        $row.Children.Add($xp) | Out-Null

        $apply = New-Object System.Windows.Controls.Button
        $apply.Content = 'Set'; $apply.Width = 75; $apply.Height = 28; $apply.Margin = '0,0,8,0'
        $apply.IsEnabled = $false; $apply.Tag = "$track|apply"
        $apply.Add_Click({
            $btn = $this
            $t = ($btn.Tag -split '\|')[0]
            Invoke-V6CharSpecApply -Track $t
        })
        [System.Windows.Controls.Grid]::SetColumn($apply, 3)
        $row.Children.Add($apply) | Out-Null

        $unlock = New-Object System.Windows.Controls.Button
        $unlock.Content = 'Unlock Keystones'; $unlock.Height = 28; $unlock.HorizontalAlignment = 'Left'; $unlock.Padding = '8,2'
        $unlock.IsEnabled = $false; $unlock.Tag = "$track|unlock"
        $unlock.Add_Click({
            $btn = $this
            $t = ($btn.Tag -split '\|')[0]
            Invoke-V6CharSpecUnlock -Track $t
        })
        [System.Windows.Controls.Grid]::SetColumn($unlock, 4)
        $row.Children.Add($unlock) | Out-Null

        $sp.Children.Add($row) | Out-Null
        $state.SpecControls[$track] = @{ Level=$lvl; Xp=$xp; ApplyBtn=$apply; UnlockBtn=$unlock }
    }
    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Margin = '0,4,0,0'; $hint.FontSize = 11
    $hint.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x8E,0x82,0x70))
    $hint.Text = 'Set writes Level + XP for the track. Unlock Keystones grants every keystone whose name starts with the track prefix.'
    $sp.Children.Add($hint) | Out-Null
    $state.SpecsBody.Children.Add($sp) | Out-Null
}

function _V6ChBuildEconomyBody {
    param($state)
    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

    $row = 0; $col = 0
    foreach ($cur in $script:V6CurrencyDefs) {
        $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height=[System.Windows.GridLength]::Auto}))
        $cell = New-Object System.Windows.Controls.StackPanel
        $cell.Margin = '0,0,16,12'
        [System.Windows.Controls.Grid]::SetRow($cell, $row)
        [System.Windows.Controls.Grid]::SetColumn($cell, $col)
        $cell.Children.Add((_V6ChMakeLabel $cur.Label "currency id $($cur.Id)")) | Out-Null

        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Height = 28; $tb.IsEnabled = $false
        $tb.Add_TextChanged({ _V6ChSetDirty $script:V6Ch $true }.GetNewClosure())
        $cell.Children.Add($tb) | Out-Null
        $grid.Children.Add($cell) | Out-Null
        $state.CurrencyControls[$cur.Id] = $tb

        $col++; if ($col -ge 2) { $col = 0; $row++ }
    }
    $state.EconBody.Children.Add($grid) | Out-Null
}

function _V6ChRebuildFactionBody {
    param($state, $factions, $existing)
    $state.FactionBody.Children.Clear()
    $state.FactionControls.Clear()

    if (-not $factions -or $factions.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x8E,0x82,0x70))
        $tb.FontStyle = 'Italic'
        $tb.Text = 'No factions returned from the database. Select a character and Refresh to load.'
        $state.FactionBody.Children.Add($tb) | Out-Null
        return
    }

    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)
    $row = 0; $col = 0
    foreach ($f in $factions) {
        $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height=[System.Windows.GridLength]::Auto}))
        $cell = New-Object System.Windows.Controls.StackPanel
        $cell.Margin = '0,0,16,12'
        [System.Windows.Controls.Grid]::SetRow($cell, $row)
        [System.Windows.Controls.Grid]::SetColumn($cell, $col)
        $cell.Children.Add((_V6ChMakeLabel "$($f.name)" "faction id $($f.id)")) | Out-Null

        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Height = 28
        $existingRep = $existing | Where-Object { [int]$_.faction_id -eq [int]$f.id } | Select-Object -First 1
        $tb.Text = if ($existingRep) { "$($existingRep.reputation_amount)" } else { '0' }
        $tb.Add_TextChanged({ _V6ChSetDirty $script:V6Ch $true }.GetNewClosure())
        $cell.Children.Add($tb) | Out-Null
        $grid.Children.Add($cell) | Out-Null

        $state.FactionControls[[int]$f.id] = @{ Tb=$tb; Name=$f.name }
        $col++; if ($col -ge 2) { $col = 0; $row++ }
    }
    $state.FactionBody.Children.Add($grid) | Out-Null
}

function _V6ChEnableEditorControls {
    param($state, [bool]$Enabled)
    foreach ($k in $state.StatControls.Keys)    { $state.StatControls[$k].IsEnabled = $Enabled }
    foreach ($k in $state.CurrencyControls.Keys) { $state.CurrencyControls[$k].IsEnabled = $Enabled }
    foreach ($k in $state.SpecControls.Keys) {
        $state.SpecControls[$k].Level.IsEnabled    = $Enabled
        $state.SpecControls[$k].Xp.IsEnabled       = $Enabled
        $state.SpecControls[$k].ApplyBtn.IsEnabled = $Enabled
        $state.SpecControls[$k].UnlockBtn.IsEnabled= $Enabled
    }
    foreach ($k in $state.FactionControls.Keys) { $state.FactionControls[$k].Tb.IsEnabled = $Enabled }
    foreach ($child in $state.TechBody.Children) {
        if ($child -is [System.Windows.Controls.StackPanel]) {
            foreach ($inner in $child.Children) {
                if ($inner -is [System.Windows.Controls.Button]) { $inner.IsEnabled = $Enabled }
            }
        }
    }
    $state.BtnSave.IsEnabled = $Enabled
}

function Initialize-V6CharactersPage {
    if ($script:V6Ch) { return }
    if (-not $ui -or -not $ui.PageCharacters) { return }

    $state = New-V6CharactersPage
    $ui.PageCharacters.Child = $state.Root
    $script:V6Ch = $state

    _V6ChBuildStatsBody    -state $state
    _V6ChBuildTechBody     -state $state
    _V6ChBuildSpecsBody    -state $state
    _V6ChBuildEconomyBody  -state $state
    _V6ChRebuildFactionBody -state $state -factions @() -existing @()

    $state.BtnLoad.Add_Click({ Invoke-V6CharLoadList })
    $state.Picker.Add_SelectionChanged({
        $c = $script:V6Ch
        $sel = $c.Picker.SelectedItem
        if (-not $sel) { return }
        $c.SelectedId = [int]$sel.Tag
        Invoke-V6CharLoadDetail -Id $c.SelectedId
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

    $state.BtnSave.Add_Click({ Invoke-V6CharSave })
    $state.BtnSave.IsEnabled = $false
}

function _V6ChResolveVm {
    if (-not (Get-Command Get-VmStatus -ErrorAction SilentlyContinue)) { return $null }
    try {
        $vm = Get-VmStatus
        if ($vm -and $vm.running -and $vm.ip) { return $vm }
    } catch {}
    return $null
}

function Invoke-V6CharLoadList {
    $c = $script:V6Ch
    if (-not $c) { return }
    $vm = _V6ChResolveVm
    if (-not $vm) {
        $c.Status.Text = 'VM not running. Start the VM from the Terminal pane first.'
        return
    }
    $c.Vm = $vm
    $c.Picker.Items.Clear()
    $c.BtnLoad.IsEnabled = $false
    $c.Status.Text = 'Querying Postgres for characters...'
    try {
        $list = Get-V6CharacterList -Ip $vm.ip
    } catch {
        $c.Status.Text = "Failed to load characters: $($_.Exception.Message)"
        $c.BtnLoad.IsEnabled = $true
        return
    } finally {
        $c.BtnLoad.IsEnabled = $true
    }
    if (-not $list -or $list.Count -eq 0) {
        $c.Status.Text = 'No characters returned. Has anyone joined this server yet?'
        return
    }
    foreach ($ch in $list) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = "$($ch.name)  (ID: $($ch.id))"
        $item.Tag = $ch.id
        $c.Picker.Items.Add($item) | Out-Null
    }
    $c.Characters = $list
    $c.Status.Text = "Loaded $($list.Count) characters from the VM."
    if ($c.Picker.Items.Count -gt 0) { $c.Picker.SelectedIndex = 0 }
}

function Invoke-V6CharLoadDetail {
    param([int]$Id)
    $c = $script:V6Ch
    if (-not $c) { return }
    $vm = _V6ChResolveVm
    if (-not $vm) { $c.Status.Text = 'VM not running.'; return }
    $c.Vm = $vm
    $c.Status.Text = "Loading character $Id..."
    try {
        $detail = Get-V6CharacterDetail -Ip $vm.ip -Id $Id
        $c.Detail = $detail
        foreach ($s in $script:V6CharStatDefs) {
            $val = Get-V6StatValue -Detail $detail -Field $s.Field -PathStr $s.Path
            $c.StatControls[$s.Key].Text = "$val"
        }
        $econ = Get-V6Economy -Ip $vm.ip -Id $Id
        foreach ($cur in $script:V6CurrencyDefs) {
            $match = $econ.Currency | Where-Object { [int]$_.currency_id -eq [int]$cur.Id } | Select-Object -First 1
            $c.CurrencyControls[$cur.Id].Text = if ($match) { "$($match.balance)" } else { '0' }
        }
        _V6ChRebuildFactionBody -state $c -factions $econ.Factions -existing $econ.FactionRep
        $specs = Get-V6Specializations -Ip $vm.ip -Id $Id
        foreach ($t in $script:V6SpecTracks) {
            $match = $specs.Tracks | Where-Object { $_.track_type -eq $t } | Select-Object -First 1
            if ($match) {
                $c.SpecControls[$t].Level.Text = "$([int]$match.level)"
                $c.SpecControls[$t].Xp.Text    = "$($match.xp_amount)"
            } else {
                $c.SpecControls[$t].Level.Text = '0'
                $c.SpecControls[$t].Xp.Text    = '0'
            }
        }
        _V6ChEnableEditorControls -state $c -Enabled $true
        _V6ChSetDirty $c $false
        $c.Status.Text = "Loaded character $Id at $(Get-Date -Format 'HH:mm:ss')."
    } catch {
        $c.Status.Text = "Failed to load character ${Id}: $($_.Exception.Message)"
    }
}

function Invoke-V6CharSave {
    $c = $script:V6Ch
    if (-not $c -or -not $c.Detail) { $c.Status.Text = 'Nothing to save.'; return }
    $vm = _V6ChResolveVm
    if (-not $vm) { $c.Status.Text = 'VM not running.'; return }

    $confirm = [System.Windows.MessageBox]::Show(
        ("Apply edits to character {0}?`n`nDirect writes to the live Postgres DB. We strongly recommend a DB backup first (use the Backup DB button)." -f $c.SelectedId),
        'Save character',
        [System.Windows.MessageBoxButton]::OKCancel,
        [System.Windows.MessageBoxImage]::Warning)
    if ($confirm -ne [System.Windows.MessageBoxResult]::OK) { return }

    $c.BtnSave.IsEnabled = $false
    $c.Status.Text = 'Computing stat diffs and writing to DB...'

    try {
        # Stats
        $updates = @()
        foreach ($s in $script:V6CharStatDefs) {
            $newRaw = ($c.StatControls[$s.Key].Text).Trim()
            if ([string]::IsNullOrEmpty($newRaw)) { continue }
            $newVal = $null
            if ($s.Step -lt 1) {
                try { $newVal = [double]$newRaw } catch { continue }
            } else {
                try { $newVal = [int]$newRaw } catch { continue }
            }
            $cur = Get-V6StatValue -Detail $c.Detail -Field $s.Field -PathStr $s.Path
            if ("$cur" -eq "$newVal") { continue }
            $pathParts = $s.Path -split '\.'
            if ($s.Field -eq 'gas_attributes' -and $pathParts.Count -eq 2) {
                $updates += @{ Field=$s.Field; Path=@($pathParts[0], $pathParts[1], 'BaseValue');    Value=$newVal }
                $updates += @{ Field=$s.Field; Path=@($pathParts[0], $pathParts[1], 'CurrentValue'); Value=$newVal }
            } elseif ($s.Field -eq 'properties' -and $s.Path -eq 'DamageableActorComponent.m_TotalMaxHealth') {
                $updates += @{ Field=$s.Field; Path=$pathParts;                                    Value=$newVal }
                $updates += @{ Field=$s.Field; Path=@('DamageableActorComponent','m_CurrentMaxHealth'); Value=$newVal }
            } else {
                $updates += @{ Field=$s.Field; Path=$pathParts; Value=$newVal }
            }
        }
        if ($updates.Count -gt 0) {
            Set-V6CharacterStats -Ip $vm.ip -Id $c.SelectedId -Updates $updates
        }

        # Currency
        foreach ($cur in $script:V6CurrencyDefs) {
            $raw = ($c.CurrencyControls[$cur.Id].Text).Trim()
            if ([string]::IsNullOrEmpty($raw)) { continue }
            $bal = 0
            try { $bal = [int]$raw } catch { continue }
            Set-V6Currency -Ip $vm.ip -Id $c.SelectedId -CurrencyId $cur.Id -Balance $bal
        }

        # Faction reputation
        foreach ($fid in $c.FactionControls.Keys) {
            $raw = ($c.FactionControls[$fid].Tb.Text).Trim()
            if ([string]::IsNullOrEmpty($raw)) { continue }
            $amt = 0
            try { $amt = [int]$raw } catch { continue }
            Set-V6FactionReputation -Ip $vm.ip -Id $c.SelectedId -FactionId $fid -Amount $amt
        }

        $c.Status.Text = "Saved $($updates.Count) stat ops + currency + faction reputation for character $($c.SelectedId)."
        _V6ChSetDirty $c $false
        # Refresh in-memory detail so subsequent diffs are based on new baseline
        try { $c.Detail = Get-V6CharacterDetail -Ip $vm.ip -Id $c.SelectedId } catch {}
    } catch {
        $c.Status.Text = "Save failed: $($_.Exception.Message)"
    } finally {
        $c.BtnSave.IsEnabled = $true
    }
}

function Invoke-V6CharTechAction {
    param([ValidateSet('unlock','lock')][string]$Action)
    $c = $script:V6Ch
    if (-not $c -or -not $c.SelectedId) { return }
    $vm = _V6ChResolveVm
    if (-not $vm) { $c.Status.Text = 'VM not running.'; return }
    $verb = if ($Action -eq 'unlock') { 'Unlock' } else { 'Lock' }
    $confirm = [System.Windows.MessageBox]::Show(
        ("$verb ALL tech recipes for character {0}?`n`nThis is a single bulk write to the live DB." -f $c.SelectedId),
        "$verb All Tech",
        [System.Windows.MessageBoxButton]::OKCancel,
        [System.Windows.MessageBoxImage]::Warning)
    if ($confirm -ne [System.Windows.MessageBoxResult]::OK) { return }
    $c.Status.Text = "Bulk $Action of all tech recipes..."
    try {
        if ($Action -eq 'unlock') { Invoke-V6TechUnlockAll -Ip $vm.ip -Id $c.SelectedId }
        else                       { Invoke-V6TechLockAll   -Ip $vm.ip -Id $c.SelectedId }
        $c.Status.Text = "Tech tree: all recipes ${Action}ed for character $($c.SelectedId)."
    } catch {
        $c.Status.Text = "Tech $Action failed: $($_.Exception.Message)"
    }
}

function Invoke-V6CharSpecApply {
    param([string]$Track)
    $c = $script:V6Ch
    if (-not $c -or -not $c.SelectedId) { return }
    $vm = _V6ChResolveVm
    if (-not $vm) { $c.Status.Text = 'VM not running.'; return }
    $lvlRaw = ($c.SpecControls[$Track].Level.Text).Trim()
    $xpRaw  = ($c.SpecControls[$Track].Xp.Text).Trim()
    $lvl = 0; $xp = 0
    try { $lvl = [double]$lvlRaw } catch { $c.Status.Text = "Bad level value for $Track"; return }
    try { $xp  = [int]$xpRaw }    catch { $c.Status.Text = "Bad XP value for $Track"; return }
    try {
        Set-V6SpecializationTrack -Ip $vm.ip -Id $c.SelectedId -TrackType $Track -Xp $xp -Level $lvl
        $c.Status.Text = "Specialization $Track set to Lv$([int]$lvl) / $xp XP."
    } catch {
        $c.Status.Text = "Spec apply failed: $($_.Exception.Message)"
    }
}

function Invoke-V6CharSpecUnlock {
    param([string]$Track)
    $c = $script:V6Ch
    if (-not $c -or -not $c.SelectedId) { return }
    $vm = _V6ChResolveVm
    if (-not $vm) { $c.Status.Text = 'VM not running.'; return }
    $confirm = [System.Windows.MessageBox]::Show(
        "Unlock ALL $Track keystones for character $($c.SelectedId)?",
        "Unlock $Track Keystones",
        [System.Windows.MessageBoxButton]::OKCancel,
        [System.Windows.MessageBoxImage]::Warning)
    if ($confirm -ne [System.Windows.MessageBoxResult]::OK) { return }
    try {
        Invoke-V6UnlockKeystonesForTrack -Ip $vm.ip -Id $c.SelectedId -TrackPrefix "${Track}_"
        $c.Status.Text = "All $Track keystones unlocked for character $($c.SelectedId)."
    } catch {
        $c.Status.Text = "Keystone unlock failed: $($_.Exception.Message)"
    }
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
