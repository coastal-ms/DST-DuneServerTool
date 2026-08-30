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

    It 'restores clamped bounds before and after native window restoration' {
        $restore = $script:MainForm.IndexOf('private void RestoreFromTray()')
        $normal = $script:MainForm.IndexOf(
            'WindowState = FormWindowState.Normal;',
            $restore
        )
        $bounds = $script:MainForm.IndexOf('Bounds = targetBounds;', $normal)
        $show = $script:MainForm.IndexOf('Show();', $bounds)
        $nativeRestore = $script:MainForm.IndexOf(
            'ShowWindow(Handle, SW_RESTORE)',
            $show
        )
        $restoredNormal = $script:MainForm.IndexOf(
            'WindowState = FormWindowState.Normal;',
            $nativeRestore
        )
        $restoredBounds = $script:MainForm.IndexOf(
            'Bounds = targetBounds;',
            $restoredNormal
        )

        $normal | Should -BeGreaterThan $restore
        $bounds | Should -BeGreaterThan $normal
        $show | Should -BeGreaterThan $bounds
        $nativeRestore | Should -BeGreaterThan $show
        $restoredNormal | Should -BeGreaterThan $nativeRestore
        $restoredBounds | Should -BeGreaterThan $restoredNormal
    }

    It 'foregrounds the restored form on the tray click' {
        $restore = $script:MainForm.IndexOf('private void RestoreFromTray()')
        $show = $script:MainForm.IndexOf('Show();', $restore)
        $foreground = $script:MainForm.IndexOf(
            'SetForegroundWindow(Handle)',
            $show
        )

        $foreground | Should -BeGreaterThan $show
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
