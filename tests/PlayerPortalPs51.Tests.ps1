Describe 'Windows PowerShell 5.1 Player dispatcher' {
    It 'enforces ownership and command denial in inline and pooled production dispatch' {
        $powershell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $scriptFile=Join-Path $PSScriptRoot 'production\PlayerPortal.PS51.ps1'
        $output=& $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptFile 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        $output | Should -Contain 'PS51 Player dispatcher and worker seam passed.'
    }
}
