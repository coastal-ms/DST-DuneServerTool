BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Atlas.ps1'
}

Describe 'Map preference identity uses authenticated users' {
    It 'keeps accounts separate and ignores a forged map user header' {
        $request=@{Headers=@{'X-DST-Atlas-User'='local-host'};Cookies=@{}}
        $first=Get-DuneAtlasPreferenceIdentity -Request $request -Principal @{account=@{id='first-account'}} -Local $false
        $second=Get-DuneAtlasPreferenceIdentity -Request $request -Principal @{account=@{id='second-account'}} -Local $false
        $first | Should -Not -Be $second
        $first | Should -Match '^user-[a-f0-9]{64}$'
        $first | Should -Be (Get-DuneAtlasPreferenceIdentity -Request $request -Principal @{account=@{id='first-account'}} -Local $false)
    }
    It 'keeps local DST independent of a remote account cookie' {
        Get-DuneAtlasPreferenceIdentity -Request @{} -Principal @{account=@{id='first-account'}} -Local $true | Should -Be 'local-host'
    }
    It 'uses a persistent cookie for accountless browsers without depending on a tab id' {
        $request=@{Headers=@{'X-DST-Atlas-Viewer'='first-viewer-0001'};Cookies=@{'dst-atlas-browser'=@{Value=('a'*32)}}}
        $first=Get-DuneAtlasPreferenceIdentity -Request $request -Principal $null -Local $false
        $request.Headers['X-DST-Atlas-Viewer']='another-viewer-0002'
        Get-DuneAtlasPreferenceIdentity -Request $request -Principal $null -Local $false | Should -Be $first
        $request.Cookies['dst-atlas-browser'].Value=('b'*32)
        Get-DuneAtlasPreferenceIdentity -Request $request -Principal $null -Local $false | Should -Not -Be $first
    }
}
