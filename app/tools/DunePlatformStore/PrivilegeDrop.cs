using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace DunePlatformStore;

internal static class PrivilegeDrop
{
    private const uint TokenAssignPrimary = 0x0001;
    private const uint TokenDuplicate = 0x0002;
    private const uint TokenQuery = 0x0008;
    private const uint MaximumAllowed = 0x02000000;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint StartfUseStdHandles = 0x00000100;
    private const uint CreateNoWindow = 0x08000000;
    private const uint LogonWithProfile = 0x00000001;
    private const uint Infinite = 0xffffffff;
    private const int StdInputHandle = -10;
    private const int StdOutputHandle = -11;
    private const int StdErrorHandle = -12;

    internal static int EnsureUnelevated(string[] args)
    {
        if (!OperatingSystem.IsWindows() || !IsElevated())
        {
            return -1;
        }

        var token = GetUnelevatedPrimaryToken();
        try
        {
            var executable = Environment.ProcessPath
                ?? throw new InvalidOperationException("The helper executable path is unavailable.");
            var commandLine = BuildCommandLine(executable, args);
            var startup = new StartupInfo
            {
                cb = (uint)Marshal.SizeOf<StartupInfo>(),
                dwFlags = StartfUseStdHandles,
                hStdInput = GetStdHandle(StdInputHandle),
                hStdOutput = GetStdHandle(StdOutputHandle),
                hStdError = GetStdHandle(StdErrorHandle)
            };
            if (!CreateProcessWithTokenW(
                    token,
                    LogonWithProfile,
                    executable,
                    commandLine,
                    CreateNoWindow,
                    IntPtr.Zero,
                    Environment.CurrentDirectory,
                    ref startup,
                    out var processInformation))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The elevated cache helper could not relaunch with the unelevated user token.");
            }
            try
            {
                WaitForSingleObject(processInformation.hProcess, Infinite);
                if (!GetExitCodeProcess(processInformation.hProcess, out var exitCode))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "The unelevated cache helper exit code is unavailable.");
                }
                return unchecked((int)exitCode);
            }
            finally
            {
                CloseHandle(processInformation.hThread);
                CloseHandle(processInformation.hProcess);
            }
        }
        finally
        {
            CloseHandle(token);
        }
    }

    internal static bool IsElevated()
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }
        if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out var token))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "The process token could not be opened.");
        }
        try
        {
            if (!GetTokenInformation(
                    token,
                    TokenInformationClass.TokenElevation,
                    out TokenElevation elevation,
                    (uint)Marshal.SizeOf<TokenElevation>(),
                    out _))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The process elevation state could not be read.");
            }
            return elevation.TokenIsElevated != 0;
        }
        finally
        {
            CloseHandle(token);
        }
    }

    private static IntPtr GetUnelevatedPrimaryToken()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out var currentToken))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "The process token could not be opened.");
        }
        try
        {
            if (GetTokenInformation(
                    currentToken,
                    TokenInformationClass.TokenLinkedToken,
                    out TokenLinkedToken linked,
                    (uint)Marshal.SizeOf<TokenLinkedToken>(),
                    out _))
            {
                try
                {
                    return DuplicatePrimaryToken(linked.LinkedToken);
                }
                finally
                {
                    CloseHandle(linked.LinkedToken);
                }
            }
        }
        finally
        {
            CloseHandle(currentToken);
        }

        var shellWindow = GetShellWindow();
        if (shellWindow == IntPtr.Zero)
        {
            throw new UnauthorizedAccessException(
                "No unelevated linked or interactive shell token is available; cache access is disabled.");
        }
        GetWindowThreadProcessId(shellWindow, out var shellProcessId);
        var shellProcess = OpenProcess(ProcessQueryLimitedInformation, false, shellProcessId);
        if (shellProcess == IntPtr.Zero)
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "The interactive shell process could not be opened.");
        }
        try
        {
            if (!OpenProcessToken(
                    shellProcess,
                    TokenAssignPrimary | TokenDuplicate | TokenQuery,
                    out var shellToken))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The interactive shell token could not be opened.");
            }
            try
            {
                return DuplicatePrimaryToken(shellToken);
            }
            finally
            {
                CloseHandle(shellToken);
            }
        }
        finally
        {
            CloseHandle(shellProcess);
        }
    }

    private static IntPtr DuplicatePrimaryToken(IntPtr token)
    {
        if (!DuplicateTokenEx(
                token,
                MaximumAllowed,
                IntPtr.Zero,
                SecurityImpersonationLevel.SecurityImpersonation,
                TokenType.TokenPrimary,
                out var primary))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "The unelevated primary token could not be duplicated.");
        }
        try
        {
            using var currentIdentity = System.Security.Principal.WindowsIdentity.GetCurrent();
            using var candidateIdentity = new System.Security.Principal.WindowsIdentity(primary);
            if (currentIdentity.User is null || candidateIdentity.User is null ||
                !currentIdentity.User.Equals(candidateIdentity.User))
            {
                throw new UnauthorizedAccessException(
                    "The unelevated cache token does not belong to the current Windows user.");
            }
            if (IsTokenElevated(primary))
            {
                throw new UnauthorizedAccessException(
                    "The replacement cache token is still elevated.");
            }
        }
        catch
        {
            CloseHandle(primary);
            throw;
        }
        return primary;
    }

    private static bool IsTokenElevated(IntPtr token)
    {
        if (!GetTokenInformation(
                token,
                TokenInformationClass.TokenElevation,
                out TokenElevation elevation,
                (uint)Marshal.SizeOf<TokenElevation>(),
                out _))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "The replacement token elevation state could not be read.");
        }
        return elevation.TokenIsElevated != 0;
    }

    private static string BuildCommandLine(string executable, IEnumerable<string> args)
    {
        var values = new[] { executable }.Concat(args);
        return string.Join(" ", values.Select(QuoteArgument));
    }

    private static string QuoteArgument(string value)
    {
        if (value.Length > 0 && value.All(character =>
                !char.IsWhiteSpace(character) && character != '"'))
        {
            return value;
        }
        var result = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append(character);
                backslashes = 0;
                continue;
            }
            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(character);
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private enum TokenInformationClass
    {
        TokenLinkedToken = 19,
        TokenElevation = 20
    }

    private enum SecurityImpersonationLevel
    {
        SecurityAnonymous,
        SecurityIdentification,
        SecurityImpersonation,
        SecurityDelegation
    }

    private enum TokenType
    {
        TokenPrimary = 1,
        TokenImpersonation
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TokenElevation
    {
        public int TokenIsElevated;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TokenLinkedToken
    {
        public IntPtr LinkedToken;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public uint cb;
        public string? lpReserved;
        public string? lpDesktop;
        public string? lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr tokenHandle,
        TokenInformationClass tokenInformationClass,
        out TokenElevation tokenInformation,
        uint tokenInformationLength,
        out uint returnLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr tokenHandle,
        TokenInformationClass tokenInformationClass,
        out TokenLinkedToken tokenInformation,
        uint tokenInformationLength,
        out uint returnLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(
        IntPtr existingToken,
        uint desiredAccess,
        IntPtr tokenAttributes,
        SecurityImpersonationLevel impersonationLevel,
        TokenType tokenType,
        out IntPtr newToken);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessWithTokenW(
        IntPtr token,
        uint logonFlags,
        string? applicationName,
        string commandLine,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref StartupInfo startupInfo,
        out ProcessInformation processInformation);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll")]
    private static extern IntPtr GetShellWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
}
