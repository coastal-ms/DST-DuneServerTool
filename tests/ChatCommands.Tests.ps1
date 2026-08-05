BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'ChatCommands.ps1'

    # A REAL captured payload. Coastal typed "!large" in proximity chat on
    # 2026-08-04 and this is what landed in a queue bound to chat.intercept -
    # not a hand-written fixture. Keep it verbatim so a Funcom format change
    # breaks this test rather than silently breaking the feature.
    $script:RealEnvelope = '{"content":"{\"m_Id\":\"C6BA73B94B132A51F6B937AC6960C0C1\",\"m_ChannelType\":\"Proximity\",\"m_bUseSpoofedUserName\":false,\"m_SpoofedUserNameFrom\":{\"m_TableId\":\"\",\"m_Key\":\"\",\"m_UnlocalizedName\":\"\"},\"m_FuncomIdFrom\":\"Coastal#45066\",\"m_UserNameTo\":\"F9230538A63A2B3D\",\"m_Message\":{\"m_UnlocalizedMessage\":\"!large\",\"m_LocalizedMessage\":{\"m_TableId\":\"\",\"m_Key\":\"\",\"m_FormatArgs\":[]}},\"m_Timestamp\":\"2026.08.05-00.13.11\",\"m_OriginLocation\":{\"X\":-44405.412464,\"Y\":-288152.710235,\"Z\":22060.135964},\"m_HasSeenMessage\":false}","Type":"TextChat"}'

    function global:New-DstChatState {
        param([bool]$Enabled = $true, [bool]$KitOn = $true, [int]$KitCooldown = 604800)
        @{
            enabled  = $Enabled
            replyTitle = 'Server'
            channels = @('Proximity', 'Map')
            commands = @{
                kit    = @{ enabled = $KitOn; cooldownSeconds = $KitCooldown }
                small  = @{ enabled = $true;  cooldownSeconds = 900 }
                medium = @{ enabled = $true;  cooldownSeconds = 900 }
                large  = @{ enabled = $true;  cooldownSeconds = 900 }
            }
            cooldowns = @{}
        }
    }
}

Describe 'ConvertFrom-DuneChatMessage' {
    It 'parses the real captured proximity payload' {
        $m = ConvertFrom-DuneChatMessage -Text $script:RealEnvelope
        $m | Should -Not -BeNullOrEmpty
        $m.type | Should -Be 'TextChat'
        $m.channel | Should -Be 'Proximity'
        $m.fromId | Should -Be 'Coastal#45066'
        $m.text | Should -Be '!large'
        $m.timestamp | Should -Be '2026.08.05-00.13.11'
    }

    It 'keeps the origin location, which is what makes a nearest-field command possible' {
        $m = ConvertFrom-DuneChatMessage -Text $script:RealEnvelope
        $m.location | Should -Not -BeNullOrEmpty
        [math]::Round($m.location.x, 2) | Should -Be -44405.41
        [math]::Round($m.location.z, 2) | Should -Be 22060.14
    }

    It 'finds the envelope even when wrapped in a larger term dump' {
        # basic_get hands back an Erlang term, so the envelope arrives embedded
        # in surrounding noise rather than as a clean JSON document.
        $noisy = "{content,60,{'P_basic',<<`"Content`">>},undefined,[" + $script:RealEnvelope + "]}"
        $m = ConvertFrom-DuneChatMessage -Text $noisy
        $m.text | Should -Be '!large'
    }

    It 'normalises an enum-qualified channel name' {
        $env2 = $script:RealEnvelope.Replace('\"Proximity\"', '\"ETextChatChannelType::Whispers\"')
        (ConvertFrom-DuneChatMessage -Text $env2).channel | Should -Be 'Whispers'
    }

    It 'returns null rather than throwing on junk' {
        ConvertFrom-DuneChatMessage -Text ''            | Should -BeNullOrEmpty
        ConvertFrom-DuneChatMessage -Text 'not json'    | Should -BeNullOrEmpty
        ConvertFrom-DuneChatMessage -Text '{"a":1}'     | Should -BeNullOrEmpty
    }
}

Describe 'Get-DuneChatCommand' {
    It 'parses a bare command' {
        $c = Get-DuneChatCommand -Text '!large'
        $c.verb | Should -Be 'large'
        @($c.args).Count | Should -Be 0
    }
    It 'is case-insensitive and tolerates surrounding whitespace' {
        (Get-DuneChatCommand -Text '   !KIT  ').verb | Should -Be 'kit'
    }
    It 'splits arguments' {
        $c = Get-DuneChatCommand -Text '!kit starter please'
        $c.verb | Should -Be 'kit'
        @($c.args) | Should -Be @('starter', 'please')
    }
    It 'ignores ordinary conversation' {
        # The queue carries ALL chat, so this is the overwhelmingly common path.
        Get-DuneChatCommand -Text 'hello everyone'      | Should -BeNullOrEmpty
        Get-DuneChatCommand -Text 'that was great!'     | Should -BeNullOrEmpty
        Get-DuneChatCommand -Text ''                    | Should -BeNullOrEmpty
        Get-DuneChatCommand -Text '!'                   | Should -BeNullOrEmpty
        Get-DuneChatCommand -Text '!   '                | Should -BeNullOrEmpty
    }
    It 'refuses an absurdly long verb rather than carrying it around' {
        Get-DuneChatCommand -Text ('!' + ('a' * 50)) | Should -BeNullOrEmpty
    }
}

Describe 'Test-DuneChatCooldown' {
    BeforeAll {
        # Must be set in BeforeAll, not the Describe body: Pester v5 runs the
        # body during discovery, so a variable assigned there is gone by the
        # time the It blocks execute.
        $script:now = [datetime]::Parse('2026-08-04T12:00:00Z').ToUniversalTime()
    }

    It 'allows when nothing is recorded' {
        (Test-DuneChatCooldown -Cooldowns @{} -Key 'a|kit' -CooldownSeconds 600 -Now $script:now).allowed | Should -BeTrue
    }
    It 'blocks inside the window and reports the remainder' {
        $cd = @{ 'a|kit' = $script:now.AddSeconds(-100).ToString('o') }
        $r = Test-DuneChatCooldown -Cooldowns $cd -Key 'a|kit' -CooldownSeconds 600 -Now $script:now
        $r.allowed | Should -BeFalse
        $r.remainingSeconds | Should -Be 500
    }
    It 'allows once the window has passed' {
        $cd = @{ 'a|kit' = $script:now.AddSeconds(-601).ToString('o') }
        (Test-DuneChatCooldown -Cooldowns $cd -Key 'a|kit' -CooldownSeconds 600 -Now $script:now).allowed | Should -BeTrue
    }
    It 'treats a zero cooldown as no cooldown' {
        $cd = @{ 'a|kit' = $script:now.ToString('o') }
        (Test-DuneChatCooldown -Cooldowns $cd -Key 'a|kit' -CooldownSeconds 0 -Now $script:now).allowed | Should -BeTrue
    }
    It 'does not lock a player out forever on an unparseable stamp' {
        $cd = @{ 'a|kit' = 'not-a-date' }
        (Test-DuneChatCooldown -Cooldowns $cd -Key 'a|kit' -CooldownSeconds 600 -Now $script:now).allowed | Should -BeTrue
    }
    It 'keys per player AND per command so cooldowns never bleed across' {
        (Get-DuneChatCooldownKey -FromId 'A#1' -Verb 'kit') |
            Should -Not -Be (Get-DuneChatCooldownKey -FromId 'A#1' -Verb 'large')
        (Get-DuneChatCooldownKey -FromId 'A#1' -Verb 'kit') |
            Should -Not -Be (Get-DuneChatCooldownKey -FromId 'B#2' -Verb 'kit')
    }
}

Describe 'Resolve-DuneChatCommandAction' {
    It 'runs an enabled command from the real payload' {
        $m = ConvertFrom-DuneChatMessage -Text $script:RealEnvelope
        $r = Resolve-DuneChatCommandAction -Message $m -State (New-DstChatState)
        $r.action | Should -Be 'run'
        $r.verb | Should -Be 'large'
        $r.from | Should -Be 'Coastal#45066'
    }

    It 'does nothing at all while the master switch is off' {
        # The safety default. Off means off even for a valid, enabled command.
        $m = ConvertFrom-DuneChatMessage -Text $script:RealEnvelope
        $r = Resolve-DuneChatCommandAction -Message $m -State (New-DstChatState -Enabled $false)
        $r.action | Should -Be 'ignore'
        $r.reason | Should -Be 'disabled'
    }

    It 'ignores a command that is individually disabled' {
        $st = New-DstChatState
        $st.commands['large'].enabled = $false
        $m = ConvertFrom-DuneChatMessage -Text $script:RealEnvelope
        $r = Resolve-DuneChatCommandAction -Message $m -State $st
        $r.action | Should -Be 'ignore'
        $r.reason | Should -Be 'command-disabled'
    }

    It 'ignores a channel it was not told to listen on' {
        $st = New-DstChatState
        $st.channels = @('Map')
        $m = ConvertFrom-DuneChatMessage -Text $script:RealEnvelope   # Proximity
        (Resolve-DuneChatCommandAction -Message $m -State $st).reason | Should -Be 'channel-not-listened'
    }

    It 'ignores ordinary chat without treating it as an error' {
        $st = New-DstChatState
        $m = @{ type = 'TextChat'; channel = 'Proximity'; fromId = 'A#1'; text = 'anyone around?' }
        (Resolve-DuneChatCommandAction -Message $m -State $st).reason | Should -Be 'not-a-command'
    }

    It 'ignores an unknown verb' {
        $st = New-DstChatState
        $m = @{ type = 'TextChat'; channel = 'Proximity'; fromId = 'A#1'; text = '!definitelynotreal' }
        (Resolve-DuneChatCommandAction -Message $m -State $st).reason | Should -Be 'unknown-command'
    }

    It 'reports a cooldown with a human remainder instead of running' {
        $st = New-DstChatState
        $st.cooldowns[(Get-DuneChatCooldownKey -FromId 'Coastal#45066' -Verb 'large')] =
            ([datetime]::UtcNow.AddSeconds(-60)).ToString('o')
        $m = ConvertFrom-DuneChatMessage -Text $script:RealEnvelope
        $r = Resolve-DuneChatCommandAction -Message $m -State $st
        $r.action | Should -Be 'cooldown'
        $r.remainingSeconds | Should -BeGreaterThan 0
        $r.reply | Should -BeLike '*cooldown*'
    }

    It 'never runs on a non-TextChat envelope' {
        $st = New-DstChatState
        $m = @{ type = 'SystemMessage'; channel = 'Proximity'; fromId = 'A#1'; text = '!large' }
        (Resolve-DuneChatCommandAction -Message $m -State $st).reason | Should -Be 'not-text-chat'
    }
}

Describe 'Format-DuneChatCooldownRemaining' {
    It 'scales the unit' {
        Format-DuneChatCooldownRemaining -Seconds 30     | Should -Be '30s'
        Format-DuneChatCooldownRemaining -Seconds 90     | Should -Be '2m'
        Format-DuneChatCooldownRemaining -Seconds 7200   | Should -Be '2h'
        Format-DuneChatCooldownRemaining -Seconds 172800 | Should -Be '2d'
        Format-DuneChatCooldownRemaining -Seconds 0      | Should -Be 'now'
    }
}

Describe 'readiness' {
    It 'is not ready when no command is enabled' {
        # A listener that can never respond to anything is a misconfiguration,
        # not a working feature - say so rather than silently doing nothing.
        $d = New-DuneChatCommandsDefault
        $r = Test-DuneChatCommandsReady -State $d
        $r.ready | Should -BeFalse
        $r.reason | Should -Be 'no-commands-enabled'
    }

    It 'is ready once a command is turned on' {
        (Test-DuneChatCommandsReady -State (New-DstChatState)).ready | Should -BeTrue
    }

    It 'refuses to act when enabled but with every command off' {
        $st = New-DstChatState
        foreach ($k in @($st.commands.Keys)) { $st.commands[$k].enabled = $false }
        $m = ConvertFrom-DuneChatMessage -Text $script:RealEnvelope
        (Resolve-DuneChatCommandAction -Message $m -State $st).reason | Should -Be 'no-commands-enabled'
    }
}

Describe 'defaults' {
    It 'ships everything off' {
        # If this ever flips, players gain world-affecting powers on upgrade
        # without the admin choosing to grant them.
        $d = New-DuneChatCommandsDefault
        $d.enabled | Should -BeFalse
        foreach ($k in $d.commands.Keys) { $d.commands[$k].enabled | Should -BeFalse }
    }

    It 'registers kit and all three spice field sizes' {
        $d = New-DuneChatCommandsDefault
        @($d.commands.Keys | Sort-Object) | Should -Be @('kit', 'large', 'medium', 'small')
    }
}

Describe '!kit argument handling' {
    It 'asks which kit when no name is given' {
        # Several kits can exist; silently picking one would hand players the
        # wrong thing.
        $st = New-DstChatState
        $m = @{ type = 'TextChat'; channel = 'Proximity'; fromId = 'A#1'; text = '!kit' }
        $act = Resolve-DuneChatCommandAction -Message $m -State $st
        $act.action | Should -Be 'run'
        $act.verb | Should -Be 'kit'
        @($act.args).Count | Should -Be 0
    }

    It 'passes a multi-word kit name through intact' {
        $c = Get-DuneChatCommand -Text '!kit Deep Desert Starter'
        $c.verb | Should -Be 'kit'
        (@($c.args) -join ' ') | Should -Be 'Deep Desert Starter'
    }
}

Describe 'spice field verbs' {
    It 'recognises all three sizes' {
        $st = New-DstChatState
        foreach ($size in @('small', 'medium', 'large')) {
            $m = @{ type = 'TextChat'; channel = 'Proximity'; fromId = 'A#1'; text = "!$size" }
            $act = Resolve-DuneChatCommandAction -Message $m -State $st
            $act.action | Should -Be 'run'
            $act.verb | Should -Be $size
        }
    }
}
