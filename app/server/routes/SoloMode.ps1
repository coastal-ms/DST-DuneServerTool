function Get-DuneSoloBodyField {
    param($Body, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($Body -is [hashtable] -and $Body.ContainsKey($Name)) { return $Body[$Name] }
    if ($Body -and $Body.PSObject.Properties.Name -contains $Name) { return $Body.$Name }
    return $Default
}

Register-DuneRoute -Method GET -Path '/api/solo/status' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneSoloStatus)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method GET -Path '/api/solo/runtime' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneSoloRuntime)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/discover' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $path = [string](Get-DuneSoloBodyField -Body $body -Name 'path' -Default '')
        if (-not $path.Trim()) {
            Write-DuneError -Response $res -Status 400 -Message 'Select a Solo data folder.'
            return
        }
        Write-DuneJson -Response $res -Body (Get-DuneSoloDiscovery -SelectedPath $path.Trim())
    } catch {
        Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/connect' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $path = [string](Get-DuneSoloBodyField -Body $body -Name 'path' -Default '')
        $dbPath = [string](Get-DuneSoloBodyField -Body $body -Name 'dbPath' -Default '')
        if (-not $path.Trim()) {
            Write-DuneError -Response $res -Status 400 -Message 'Select a Solo data folder.'
            return
        }
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Connect-DuneSoloProfile -SelectedPath $path.Trim() -DbPath $dbPath.Trim()
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method GET -Path '/api/solo/settings' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Read-DuneSoloSettings)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method PUT -Path '/api/solo/settings' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $rawSettings = Get-DuneSoloBodyField -Body $body -Name 'settings'
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        if (-not $rawSettings) {
            Write-DuneError -Response $res -Status 400 -Message 'Missing Solo settings.'
            return
        }
        $settings = @{}
        if ($rawSettings -is [hashtable]) {
            foreach ($key in $rawSettings.Keys) { $settings[[string]$key] = [string]$rawSettings[$key] }
        } else {
            foreach ($property in $rawSettings.PSObject.Properties) {
                $settings[$property.Name] = [string]$property.Value
            }
        }
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Set-DuneSoloSettings -Settings $settings -Confirm $confirm
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method GET -Path '/api/solo/console-settings' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Read-DuneSoloConsoleSettings)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method PUT -Path '/api/solo/console-settings' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $rawSettings = Get-DuneSoloBodyField -Body $body -Name 'settings'
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        if (-not $rawSettings) {
            Write-DuneError -Response $res -Status 400 -Message 'Missing PTC Solo console settings.'
            return
        }
        $settings = @{}
        if ($rawSettings -is [hashtable]) {
            foreach ($key in $rawSettings.Keys) { $settings[[string]$key] = [string]$rawSettings[$key] }
        } else {
            foreach ($property in $rawSettings.PSObject.Properties) {
                $settings[$property.Name] = [string]$property.Value
            }
        }
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Set-DuneSoloConsoleSettings -Settings $settings -Confirm $confirm
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method GET -Path '/api/solo/backups' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body @{ ok = $true; backups = @(Get-DuneSoloBackups); root = Get-DuneSoloBackupRoot }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/backups' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            New-DuneSoloSaveBackup
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method DELETE -Path '/api/solo/backups' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $relativePath = [string](Get-DuneSoloBodyField -Body $body -Name 'relativePath' -Default '')
        $rawRelativePaths = Get-DuneSoloBodyField -Body $body -Name 'relativePaths'
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            if ($null -ne $rawRelativePaths) {
                $relativePaths = @($rawRelativePaths | ForEach-Object { [string]$_ })
                Remove-DuneSoloBackups -RelativePaths $relativePaths -Confirm $confirm
            } else {
                Remove-DuneSoloBackup -RelativePath $relativePath -Confirm $confirm
            }
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/restore' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $relativePath = [string](Get-DuneSoloBodyField -Body $body -Name 'relativePath' -Default '')
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        if (-not $relativePath.Trim()) {
            Write-DuneError -Response $res -Status 400 -Message 'Choose a Solo backup to restore.'
            return
        }
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Restore-DuneSoloBackup -RelativePath $relativePath.Trim() -Confirm $confirm
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/items/grant' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $destination = [string](Get-DuneSoloBodyField -Body $body -Name 'destination' -Default '')
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $rawItems = Get-DuneSoloBodyField -Body $body -Name 'items'
        $items = if ($null -eq $rawItems) { @() } else { @($rawItems) }
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Invoke-DuneSoloGiveItems -Destination $destination -Items $items -Confirm $confirm
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*' -or $_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method GET -Path '/api/solo/blueprints' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneSoloBlueprints)
    } catch {
        Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/blueprints/export' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $blueprintId = [long](Get-DuneSoloBodyField -Body $body -Name 'blueprintId' -Default 0)
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Export-DuneSoloBlueprint -BlueprintId $blueprintId
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/blueprints/import' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $blueprint = Get-DuneSoloBodyField -Body $body -Name 'blueprint'
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        if ($null -eq $blueprint) {
            Write-DuneError -Response $res -Status 400 -Message 'Choose a portable blueprint file to import.'
            return
        }
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Import-DuneSoloBlueprint -Blueprint $blueprint -Confirm $confirm
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*' -or $_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method PUT -Path '/api/solo/currencies' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $solari = [long](Get-DuneSoloBodyField -Body $body -Name 'solari' -Default -1)
        $scrip = [long](Get-DuneSoloBodyField -Body $body -Name 'scrip' -Default -1)
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Set-DuneSoloCurrencies -Solari $solari -Scrip $scrip -Confirm $confirm
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*' -or $_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/fillables/water' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $itemId = [long](Get-DuneSoloBodyField -Body $body -Name 'itemId' -Default 0)
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Fill-DuneSoloWaterContainer -ItemId $itemId -Confirm $confirm
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*' -or $_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/items/augments/max' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Invoke-DuneSoloMaxAugmentAttributes -Confirm $confirm
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*' -or $_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/progression/specializations/max' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Invoke-DuneSoloProgressionAction -Action 'max-specializations' `
                -Confirm $confirm -ExpectedConfirm 'MAX SOLO SPECIALIZATIONS'
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*' -or $_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/progression/find-the-fremen' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Invoke-DuneSoloProgressionAction -Action 'complete-fremen' `
                -Confirm $confirm -ExpectedConfirm 'COMPLETE FIND THE FREMEN'
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*' -or $_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/progression/npe/complete' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Invoke-DuneSoloProgressionAction -Action 'complete-npe' `
                -Confirm $confirm -ExpectedConfirm 'COMPLETE SOLO NPE'
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*' -or $_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/solo/progression/skills/enable-all' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Invoke-DuneSoloProgressionAction -Action 'enable-skills' `
                -Confirm $confirm -ExpectedConfirm 'ENABLE SOLO SKILLS'
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*' -or $_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method PUT -Path '/api/solo/progression/points' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $skillPoints = 0L
        $rawSkillPoints = Get-DuneSoloBodyField -Body $body -Name 'skillPoints' -Default -1
        $skillPointsText = [Convert]::ToString($rawSkillPoints, [Globalization.CultureInfo]::InvariantCulture)
        if (-not [long]::TryParse(
                $skillPointsText,
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$skillPoints
            )) {
            throw 'Skill points must be a whole number.'
        }

        $intel = 0L
        $rawIntel = Get-DuneSoloBodyField -Body $body -Name 'intel' -Default -1
        $intelText = [Convert]::ToString($rawIntel, [Globalization.CultureInfo]::InvariantCulture)
        if (-not [long]::TryParse(
                $intelText,
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$intel
            )) {
            throw 'Intel points must be a whole number.'
        }

        $confirm = [string](Get-DuneSoloBodyField -Body $body -Name 'confirm' -Default '')
        $expectedProfileToken = [string](Get-DuneSoloBodyField -Body $body -Name 'expectedProfileToken' -Default '')
        $result = Invoke-WithDuneLock -Name 'solo-profile-data' -Script {
            Assert-DuneSoloExpectedProfile -ExpectedProfileToken $expectedProfileToken
            Set-DuneSoloProgressionPoints -SkillPoints $skillPoints -Intel $intel -Confirm $confirm
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        $status = if ($_.Exception.Message -like '*still running*' -or $_.Exception.Message -like '*changed in another window*') { 409 } else { 400 }
        Write-DuneError -Response $res -Status $status -Message $_.Exception.Message
    }
}
