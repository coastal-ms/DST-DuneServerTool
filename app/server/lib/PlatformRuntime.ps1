$platformRuntimeVariable = Get-Variable DunePlatformRuntime -Scope Script -ErrorAction SilentlyContinue
if (-not $platformRuntimeVariable) {
    $script:DunePlatformRuntime = $null
}

function Get-DunePlatformRuntime {
    param([string]$RuntimePlatform)

    if ($RuntimePlatform) {
        if ($RuntimePlatform -notin @('windows','linux','macos','unknown')) {
            throw "Unknown platform runtime '$RuntimePlatform'."
        }
        return $RuntimePlatform
    }
    if ($script:DunePlatformRuntime) { return [string]$script:DunePlatformRuntime }
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [Runtime.InteropServices.OSPlatform]::Windows
    )) {
        return 'windows'
    }
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [Runtime.InteropServices.OSPlatform]::Linux
    )) {
        return 'linux'
    }
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [Runtime.InteropServices.OSPlatform]::OSX
    )) {
        return 'macos'
    }
    return 'unknown'
}

function Test-DunePlatformLiveCacheSupported {
    param([string]$RuntimePlatform)
    return (Get-DunePlatformRuntime -RuntimePlatform $RuntimePlatform) -eq 'windows'
}
