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
    private const uint DisableMaxPrivilege = 0x00000001;
    private const uint LuaToken = 0x00000004;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint StartfUseStdHandles = 0x00000100;
    private const uint CreateNoWindow = 0x08000000;
    private const uint CreateSuspended = 0x00000004;
    private const uint LogonWithProfile = 0x00000001;
    private const uint DuplicateSameAccess = 0x00000002;
    private const uint HandleFlagInherit = 0x00000001;
    private const uint Infinite = 0xffffffff;
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const int StdInputHandle = -10;
    private const int StdOutputHandle = -11;
    private const int StdErrorHandle = -12;

    internal static int? EnsureUnelevated(string[] args)
    {
        if (!OperatingSystem.IsWindows() || !IsElevated())
        {
            return null;
        }
        return RelaunchWithUnelevatedToken(args);
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

    internal static bool SelfTestInheritableStandardHandles()
    {
        foreach (var standardHandle in new[] { StdInputHandle, StdOutputHandle, StdErrorHandle })
        {
            var duplicate = DuplicateInheritableStandardHandle(standardHandle);
            try
            {
                if (!GetHandleInformation(duplicate, out var flags) ||
                    (flags & HandleFlagInherit) == 0)
                {
                    return false;
                }
            }
            finally
            {
                CloseHandle(duplicate);
            }
        }
        return true;
    }

    private static int RelaunchWithUnelevatedToken(string[] args)
    {
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The helper executable path is unavailable.");
        var token = GetUnelevatedPrimaryToken();
        var standardInput = IntPtr.Zero;
        var standardOutput = IntPtr.Zero;
        var standardError = IntPtr.Zero;
        var job = IntPtr.Zero;
        try
        {
            job = CreateKillOnCloseJob();
            standardInput = DuplicateInheritableStandardHandle(StdInputHandle);
            standardOutput = DuplicateInheritableStandardHandle(StdOutputHandle);
            standardError = DuplicateInheritableStandardHandle(StdErrorHandle);
            var commandLine = BuildCommandLine(executable, args);
            var startup = new StartupInfo
            {
                cb = (uint)Marshal.SizeOf<StartupInfo>(),
                dwFlags = StartfUseStdHandles,
                hStdInput = standardInput,
                hStdOutput = standardOutput,
                hStdError = standardError
            };
            var created = CreateProcessWithTokenW(
                    token,
                    LogonWithProfile,
                    executable,
                    commandLine,
                    CreateNoWindow | CreateSuspended,
                    IntPtr.Zero,
                    Environment.CurrentDirectory,
                    ref startup,
                    out var processInformation);
            var tokenLaunchError = created ? 0 : Marshal.GetLastWin32Error();
            if (!created)
            {
                var mutableCommandLine = new StringBuilder(commandLine);
                created = CreateProcessAsUserW(
                    token,
                    executable,
                    mutableCommandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CreateNoWindow | CreateSuspended,
                    IntPtr.Zero,
                    Environment.CurrentDirectory,
                    ref startup,
                    out processInformation);
            }
            if (!created)
            {
                var error = Marshal.GetLastWin32Error();
                throw new Win32Exception(
                    error,
                    $"The elevated cache helper could not relaunch with the unelevated user token " +
                    $"(CreateProcessWithTokenW error {tokenLaunchError}; CreateProcessAsUserW error {error}).");
            }
            try
            {
                if (!AssignProcessToJobObject(job, processInformation.hProcess))
                {
                    var error = Marshal.GetLastWin32Error();
                    TerminateProcess(processInformation.hProcess, 1);
                    throw new Win32Exception(
                        error,
                        $"The unelevated cache helper could not join its lifetime job (Windows error {error}).");
                }
                if (ResumeThread(processInformation.hThread) == uint.MaxValue)
                {
                    var error = Marshal.GetLastWin32Error();
                    TerminateProcess(processInformation.hProcess, 1);
                    throw new Win32Exception(
                        error,
                        $"The unelevated cache helper could not resume (Windows error {error}).");
                }
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
            if (standardInput != IntPtr.Zero) CloseHandle(standardInput);
            if (standardOutput != IntPtr.Zero) CloseHandle(standardOutput);
            if (standardError != IntPtr.Zero) CloseHandle(standardError);
            if (job != IntPtr.Zero) CloseHandle(job);
            CloseHandle(token);
        }
    }

    private static IntPtr CreateKillOnCloseJob()
    {
        var job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "The cache helper lifetime job could not be created.");
        }
        var information = new JobObjectExtendedLimitInformation
        {
            BasicLimitInformation = new JobObjectBasicLimitInformation
            {
                LimitFlags = JobObjectLimitKillOnJobClose
            }
        };
        if (!SetInformationJobObject(
                job,
                JobObjectInformationClass.ExtendedLimitInformation,
                ref information,
                (uint)Marshal.SizeOf<JobObjectExtendedLimitInformation>()))
        {
            var error = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(error, "The cache helper lifetime job could not be configured.");
        }
        return job;
    }

    private static IntPtr GetUnelevatedPrimaryToken()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TokenDuplicate | TokenQuery, out var currentToken))
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
                    try
                    {
                        return DuplicatePrimaryToken(linked.LinkedToken);
                    }
                    catch (Exception ex) when (ex is Win32Exception or UnauthorizedAccessException)
                    {
                        // Some UAC linked-token handles expose query access but
                        // cannot be duplicated. Fall back to the same user's
                        // unelevated interactive shell or a restricted LUA token.
                    }
                }
                finally
                {
                    CloseHandle(linked.LinkedToken);
                }
            }
            var shellWindow = GetShellWindow();
            if (shellWindow != IntPtr.Zero)
            {
                GetWindowThreadProcessId(shellWindow, out var shellProcessId);
                var shellProcess = OpenProcess(ProcessQueryLimitedInformation, false, shellProcessId);
                if (shellProcess != IntPtr.Zero)
                {
                    try
                    {
                        if (OpenProcessToken(
                                shellProcess,
                                TokenDuplicate | TokenQuery,
                                out var shellToken))
                        {
                            try
                            {
                                try
                                {
                                    return DuplicatePrimaryToken(shellToken);
                                }
                                catch (UnauthorizedAccessException)
                                {
                                    // The shell can itself be elevated when UAC is
                                    // disabled. Restrict the caller token instead.
                                }
                            }
                            finally
                            {
                                CloseHandle(shellToken);
                            }
                        }
                    }
                    finally
                    {
                        CloseHandle(shellProcess);
                    }
                }
            }
            return CreateRestrictedPrimaryToken(currentToken);
        }
        finally
        {
            CloseHandle(currentToken);
        }
    }

    private static IntPtr CreateRestrictedPrimaryToken(IntPtr token)
    {
        if (!CreateRestrictedToken(
                token,
                DisableMaxPrivilege | LuaToken,
                0,
                IntPtr.Zero,
                0,
                IntPtr.Zero,
                0,
                IntPtr.Zero,
                out var restricted))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "An unelevated restricted cache token could not be created.");
        }
        try
        {
            ValidatePrimaryToken(restricted);
        }
        catch
        {
            CloseHandle(restricted);
            throw;
        }
        return restricted;
    }

    private static IntPtr DuplicatePrimaryToken(IntPtr token)
    {
        if (!DuplicateTokenEx(
                token,
                TokenAssignPrimary | TokenDuplicate | TokenQuery,
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
            ValidatePrimaryToken(primary);
        }
        catch
        {
            CloseHandle(primary);
            throw;
        }
        return primary;
    }

    private static void ValidatePrimaryToken(IntPtr token)
    {
        using var currentIdentity = System.Security.Principal.WindowsIdentity.GetCurrent();
        using var candidateIdentity = new System.Security.Principal.WindowsIdentity(token);
        if (currentIdentity.User is null || candidateIdentity.User is null ||
            !currentIdentity.User.Equals(candidateIdentity.User))
        {
            throw new UnauthorizedAccessException(
                "The unelevated cache token does not belong to the current Windows user.");
        }
        if (IsTokenElevated(token))
        {
            throw new UnauthorizedAccessException(
                "The replacement cache token is still elevated.");
        }
    }

    private static IntPtr DuplicateInheritableStandardHandle(int standardHandle)
    {
        var source = GetStdHandle(standardHandle);
        if (source == IntPtr.Zero || source == new IntPtr(-1))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "A cache helper standard handle is unavailable.");
        }
        var process = GetCurrentProcess();
        if (!DuplicateHandle(
                process,
                source,
                process,
                out var duplicate,
                0,
                true,
                DuplicateSameAccess))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "A cache helper standard handle could not be made inheritable.");
        }
        return duplicate;
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

    private enum JobObjectInformationClass
    {
        ExtendedLimitInformation = 9
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
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

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool CreateRestrictedToken(
        IntPtr existingToken,
        uint flags,
        uint disableSidCount,
        IntPtr sidsToDisable,
        uint deletePrivilegeCount,
        IntPtr privilegesToDelete,
        uint restrictedSidCount,
        IntPtr sidsToRestrict,
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

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessAsUserW(
        IntPtr token,
        string? applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
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
    private static extern bool DuplicateHandle(
        IntPtr sourceProcessHandle,
        IntPtr sourceHandle,
        IntPtr targetProcessHandle,
        out IntPtr targetHandle,
        uint desiredAccess,
        bool inheritHandle,
        uint options);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetHandleInformation(IntPtr handle, out uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObjectW(IntPtr jobAttributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        JobObjectInformationClass informationClass,
        ref JobObjectExtendedLimitInformation information,
        uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

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
