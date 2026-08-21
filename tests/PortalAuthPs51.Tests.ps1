Describe 'Windows PowerShell 5.1 portal production seam' {
    It 'executes registered login/logout handlers successfully' {
        $repo = Split-Path $PSScriptRoot -Parent
        $powershell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $script = Join-Path $PSScriptRoot 'production\PortalAuthRoutes.PS51.ps1'
        $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $script 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        $output | Should -Contain 'PS51 portal route seam passed.'
        $repo | Should -Not -BeNullOrEmpty
    }
}
