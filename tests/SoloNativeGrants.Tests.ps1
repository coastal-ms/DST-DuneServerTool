BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'SoloNativeGrants.ps1'
    function global:Assert-DuneSoloSupportedPlatform {}
    function global:Assert-DuneSoloAdapterCapability {}
    function global:Assert-DuneSoloGameClosed {}
    function global:Get-DuneSoloProfile {}
    function global:Get-DuneSoloProfileToken {}
    function global:Get-DuneSoloRuntime {}
    function global:Invoke-DuneSoloHelper { param($Command, $Arguments) }
    function global:Get-DuneSoloGameplayCatalogPath {}
    $script:GrantTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('dst-native-tests-'+[guid]::NewGuid().ToString('N'))
}
AfterAll { if ($script:GrantTestRoot.StartsWith([IO.Path]::GetTempPath())) { Remove-Item -LiteralPath $script:GrantTestRoot -Recurse -Force } }
Describe 'Character-bound native Solo grants' {
    BeforeEach {
        $script:DuneSoloLoaderRoot = Join-Path $script:GrantTestRoot ([guid]::NewGuid().ToString('N'))
        $script:token = 'a'*64
        $script:id = 'b'*32
        $script:item = @{templateId='Beta_Plaque_Patent';quantity=1;quality=0}
        Mock Get-DuneSoloProfile { @{dbPath='C:\fixture\game.db'} }
        Mock Get-DuneSoloProfileToken { $script:token }
        Mock Get-DuneSoloRuntime { @{gameRunning=$false} }
        Mock Invoke-DuneSoloHelper { @{ok=$true;accountId='9007199254740993';controllerId='11';characterName='Solo';backpackKey='inventory:1'} }
        Mock Get-DuneSoloGameplayCatalogPath { Join-Path (Get-DstRepoRoot) 'app/data/gameplay-item-data.json' }
    }
    It 'queues without an offline mutation and preserves exact character identity' {
        $r = Invoke-DuneSoloNativeItemGrant 'inventory:1' @($script:item) 'GIVE SOLO ITEMS' $script:id
        $r.status | Should -Be 'queued'
        $root = Get-DuneSoloNativeGrantRoot $script:token
        (Read-DuneSoloGrantFile (Join-Path $root "$($script:id).request")) | Should -Match '^1\|b{32}\|9007199254740993\|11\|536f6c6f'
        (Read-DuneSoloGrantFile (Join-Path $root 'queue.txt')) | Should -Be $script:id
        Should -Invoke Invoke-DuneSoloHelper -Times 1 -Exactly -ParameterFilter { $Command -eq 'native-grant-identity' }
        Should -Invoke Invoke-DuneSoloHelper -Times 0 -Exactly -ParameterFilter { $Command -eq 'grant-items' }
    }
    It 'returns an existing request but rejects reuse with different items' {
        Invoke-DuneSoloNativeItemGrant 'inventory:1' @($script:item) 'GIVE SOLO ITEMS' $script:id | Out-Null
        (Invoke-DuneSoloNativeItemGrant 'inventory:1' @($script:item) 'GIVE SOLO ITEMS' $script:id).status | Should -Be queued
        $script:item.quantity=2
        { Invoke-DuneSoloNativeItemGrant 'inventory:1' @($script:item) 'GIVE SOLO ITEMS' $script:id } | Should -Throw '*different grant*'
    }
    It 'uses only the launch binding during a live session' {
        Invoke-DuneSoloNativeItemGrant 'inventory:1' @($script:item) 'GIVE SOLO ITEMS' $script:id | Out-Null
        Mock Get-DuneSoloRuntime { @{gameRunning=$true} }
        Write-DuneSoloGrantFile (Join-Path $script:DuneSoloLoaderRoot 'session.json') (@{nativeGrantRoot=(Get-DuneSoloNativeGrantRoot $script:token)} | ConvertTo-Json)
        (Invoke-DuneSoloNativeItemGrant 'inventory:1' @($script:item) 'GIVE SOLO ITEMS' ('c'*32)).status | Should -Be queued
        Should -Invoke Invoke-DuneSoloHelper -Times 1 -Exactly
    }
    It 'rejects live grants without a launch binding' {
        Mock Get-DuneSoloRuntime { @{gameRunning=$true} }
        { Invoke-DuneSoloNativeItemGrant 'inventory:1' @($script:item) 'GIVE SOLO ITEMS' $script:id } | Should -Throw '*Launch Solo through DST*'
        Should -Invoke Invoke-DuneSoloHelper -Times 0
    }
    It 'does not replay interrupted or completed requests' {
        Invoke-DuneSoloNativeItemGrant 'inventory:1' @($script:item) 'GIVE SOLO ITEMS' $script:id | Out-Null
        $root = Get-DuneSoloNativeGrantRoot $script:token
        Write-DuneSoloGrantFile (Join-Path $root "$($script:id).result") 'processing|0|Delivering'
        (Get-DuneSoloNativeGrantResult $root $script:id).status | Should -Be uncertain
        Update-DuneSoloNativeGrantDispatch $root
        (Read-DuneSoloGrantFile (Join-Path $root 'queue.txt')) | Should -Be $script:id
        Write-DuneSoloGrantFile (Join-Path $root "$($script:id).result") 'delivered|1|Verified'
        (Invoke-DuneSoloNativeItemGrant 'inventory:1' @($script:item) 'GIVE SOLO ITEMS' $script:id).status | Should -Be delivered
        Update-DuneSoloNativeGrantDispatch $root
        (Read-DuneSoloGrantFile (Join-Path $root 'queue.txt')) | Should -Be ''
    }
    It 'rejects unsafe ids, unknown items, storage, fractional amounts and augments before publishing' {
        { Get-DuneSoloNativeGrantRoot '../escape' } | Should -Throw
        { Invoke-DuneSoloNativeItemGrant 'inventory:1' @($script:item) 'GIVE SOLO ITEMS' '../escape' } | Should -Throw
        { Invoke-DuneSoloNativeItemGrant 'inventory:2' @($script:item) 'GIVE SOLO ITEMS' $script:id } | Should -Throw '*backpack*'
        foreach ($item in @(@{templateId='no_such_item';quantity=1;quality=0}, @{templateId='Beta_Plaque_Patent';quantity=1.5;quality=0}, @{templateId='Beta_Plaque_Patent';quantity=1;quality=0;augments=@('test')})) {
            { Invoke-DuneSoloNativeItemGrant 'inventory:1' @($item) 'GIVE SOLO ITEMS' $script:id } | Should -Throw
        }
        @(Get-ChildItem -LiteralPath (Get-DuneSoloNativeGrantRoot $script:token) -Filter '*.request').Count | Should -Be 0
    }
}
