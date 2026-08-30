BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:MainForm = Get-Content (
        Join-Path (Get-DstRepoRoot) 'app\desktop\DuneShell\MainForm.cs'
    ) -Raw
}

Describe 'DuneShell tray window restoration' {
    It 'captures normal bounds before hiding the form' {
        $capture = $script:MainForm.IndexOf(
            '_restoreBounds = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;'
        )
        $hide = $script:MainForm.IndexOf('Hide();', $capture)

        $capture | Should -BeGreaterThan -1
        $hide | Should -BeGreaterThan $capture
    }

    It 'restores clamped bounds before showing the form' {
        $restore = $script:MainForm.IndexOf('private void RestoreFromTray()')
        $normal = $script:MainForm.IndexOf(
            'WindowState = FormWindowState.Normal;',
            $restore
        )
        $bounds = $script:MainForm.IndexOf('Bounds = targetBounds;', $normal)
        $show = $script:MainForm.IndexOf('Show();', $bounds)

        $normal | Should -BeGreaterThan $restore
        $bounds | Should -BeGreaterThan $normal
        $show | Should -BeGreaterThan $bounds
    }

    It 'does not persist hidden sentinel coordinates' {
        $save = $script:MainForm.IndexOf('private void SaveWindowState()')
        $visibleBounds = $script:MainForm.IndexOf(
            'Rectangle b = Visible',
            $save
        )
        $cachedBounds = $script:MainForm.IndexOf(': _restoreBounds;', $visibleBounds)

        $visibleBounds | Should -BeGreaterThan $save
        $cachedBounds | Should -BeGreaterThan $visibleBounds
    }
}
