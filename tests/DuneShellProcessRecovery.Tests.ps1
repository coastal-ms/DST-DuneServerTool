BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:MainForm = Get-Content (
        Join-Path (Get-DstRepoRoot) 'app\desktop\DuneShell\MainForm.cs'
    ) -Raw

    function Get-MethodBody([string] $Signature, [string] $NextSignature) {
        $start = $script:MainForm.IndexOf($Signature)
        $end = $script:MainForm.IndexOf($NextSignature, $start)

        $start | Should -BeGreaterThan -1
        $end | Should -BeGreaterThan $start
        return $script:MainForm.Substring($start, $end - $start)
    }
}

Describe 'DuneShell WebView2 process recovery' {
    It 'subscribes recovery independently of best-effort diagnostic setup' {
        $initialize = Get-MethodBody 'private async Task InitializeAsync()' 'private async Task InitDiagnosticLoggingAsync('
        $diagnostics = Get-MethodBody 'private async Task InitDiagnosticLoggingAsync(' 'private void OnConsoleApiCalled('

        $initialize | Should -Match 'core\.ProcessFailed \+= OnProcessFailed;'
        $diagnostics | Should -Not -Match 'ProcessFailed \+='
    }

    It 'distinguishes renderer failures from browser-process exit' {
        $handler = Get-MethodBody 'private void OnProcessFailed(' 'private void ScheduleWebViewRecovery('

        $handler | Should -Match 'CoreWebView2ProcessFailedKind\.RenderProcessExited'
        $handler | Should -Match 'CoreWebView2ProcessFailedKind\.RenderProcessUnresponsive'
        $handler | Should -Match 'ScheduleWebViewRecovery\(RecoverRenderProcess\)'
        $handler | Should -Match 'CoreWebView2ProcessFailedKind\.BrowserProcessExited'
        $handler | Should -Match 'ScheduleWebViewRecovery\(\(\) =>'
    }

    It 'reloads a failed renderer and falls back to shell restart' {
        $recovery = Get-MethodBody 'private void RecoverRenderProcess()' 'private static void AppendDiagnosticLine('
        $navigation = Get-MethodBody 'private async void OnNavigationCompleted(' 'private void OnDownloadStarting('

        $recovery | Should -Match '_firstLoadDone = false;'
        $recovery | Should -Match '_navRetries = 0;'
        $recovery | Should -Match 'core\.Reload\(\);'
        $recovery | Should -Match 'catch \(Exception ex\)'
        $recovery | Should -Match 'RestartShell\(\);'
        $navigation | Should -Match 'render reload navigation failed; restarting shell'
        $navigation | Should -Match '_recoveringWebView = false;'
    }

    It 'routes browser-process exit through the guarded shell restart path' {
        $handler = Get-MethodBody 'private void OnProcessFailed(' 'private void ScheduleWebViewRecovery('
        $browserCase = $handler.Substring(
            $handler.IndexOf('case CoreWebView2ProcessFailedKind.BrowserProcessExited:')
        )

        $browserCase | Should -Match 'ScheduleWebViewRecovery'
        $browserCase | Should -Match 'RestartShell\(\);'
    }

    It 'prevents duplicate recovery and replacement shell scheduling' {
        $scheduler = Get-MethodBody 'private void ScheduleWebViewRecovery(' 'private void RecoverRenderProcess()'

        $script:MainForm | Should -Match 'private bool _recoveringWebView;'
        $scheduler | Should -Match 'if \(_recoveringWebView \|\| IsDisposed \|\| Disposing\)'
        $scheduler | Should -Match '_recoveringWebView = true;'
        $scheduler | Should -Match 'BeginInvoke\(recovery\);'
    }

    It 'marks shell-only restart before closing the current window' {
        $restart = Get-MethodBody 'private void RestartShell()' 'private void ShowSaveDialog('
        $shellOnly = $restart.IndexOf('_restartShellOnly = true;')
        $close = $restart.IndexOf('Close();', $shellOnly)

        $shellOnly | Should -BeGreaterThan -1
        $close | Should -BeGreaterThan $shellOnly
        $restart | Should -Match '--restart-after-pid'
    }
}
