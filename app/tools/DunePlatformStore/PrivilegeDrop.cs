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
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint ProcessCreateProcess = 0x0080;
    private const uint ProcessDuplicateHandle = 0x0040;
    private const uint StartfUseStdHandles = 0x00000100;
    private const uint CreateNoWindow = 0x08000000;
    private const uint CreateSuspended = 0x00000004;
    private const uint ExtendedStartupInfoPresent = 0x00080000;
    private const uint LogonWithProfile = 0x00000001;
    private const uint DuplicateCloseSource = 0x00000001;
    private const uint DuplicateSameAccess = 0x00000002;
    private const uint HandleFlagInherit = 0x00000001;
    private const uint Infinite = 0xffffffff;
    private const int ProcThreadAttributeParentProcess = 0x00020000;
    private const int ErrorInsufficientBuffer = 122;
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const int StdInputHandle = -10;
    private const int StdOutputHandle = -11;
    private const int StdErrorHandle = -12;
    private const string ForceShellParentEnvironment = "DST_PLATFORM_FORCE_SHELL_PARENT";
    private const string ShellParentOption = "--shell-parent";

    internal static int? EnsureUnelevated(string[] args)
    {
        if (!OperatingSystem.IsWindows() ||
            (!IsElevated() && Environment.GetEnvironmentVariable(ForceShellParentEnvironment) != "1"))
        {
            return null;
        }
        return RelaunchWithShellParent(args);
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

    internal static bool TryConsumeShellParentLaunch(ref string[] args)
    {
        var index = Array.IndexOf(args, ShellParentOption);
        if (index < 0) return false;
        if (index + 1 >= args.Length)
        {
            throw new ArgumentException("The shell-parent user identity is missing.");
        }
        var expectedSid = args[index + 1];
        var retained = new List<string>(args.Length - 2);
        for (var argumentIndex = 0; argumentIndex < args.Length; argumentIndex++)
        {
            if (argumentIndex == index)
            {
                argumentIndex++;
                continue;
            }
            retained.Add(args[argumentIndex]);
        }
        args = retained.ToArray();
        var currentSid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(currentSid) ||
            !string.Equals(expectedSid, currentSid, StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException(
                "The shell-parented cache helper does not belong to the requesting Windows user.");
        }
        return true;
    }

    internal static bool HasInteractiveShell() => OperatingSystem.IsWindows() && GetShellWindow() != IntPtr.Zero;

    internal static bool SelfTestShellParentLaunch()
    {
        if (!HasInteractiveShell()) return false;
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The helper executable path is unavailable.");
        using var currentIdentity = System.Security.Principal.WindowsIdentity.GetCurrent();
        var expectedSid = currentIdentity.User?.Value
            ?? throw new UnauthorizedAccessException("The current Windows user SID is unavailable.");
        var nonce = Guid.NewGuid().ToString("N");
        var start = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        start.ArgumentList.Add("--command");
        start.ArgumentList.Add("self-test-parent-probe");
        start.Environment[ForceShellParentEnvironment] = "1";
        start.Environment["DST_PLATFORM_SELF_TEST"] = "1";
        using var process = Process.Start(start)
            ?? throw new InvalidOperationException("The shell-parent self-test launcher did not start.");
        process.StandardInput.Write(
            System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, string> { ["nonce"] = nonce }));
        process.StandardInput.Close();
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(30_000))
        {
            process.Kill(true);
            throw new TimeoutException("The shell-parent launch self-test timed out.");
        }
        var raw = (process.ExitCode == 0 ? stdout.Result : stderr.Result).Trim();
        using var json = System.Text.Json.JsonDocument.Parse(raw);
        var root = json.RootElement;
        return process.ExitCode == 0 &&
            root.GetProperty("ok").GetBoolean() &&
            !root.GetProperty("elevated").GetBoolean() &&
            string.Equals(root.GetProperty("userSid").GetString(), expectedSid, StringComparison.Ordinal) &&
            string.Equals(root.GetProperty("nonce").GetString(), nonce, StringComparison.Ordinal);
    }

    internal static bool SelfTestShellParentKillOnExit()
    {
        if (!HasInteractiveShell()) return false;
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The helper executable path is unavailable.");
        var probeFile = Path.Combine(
            Path.GetTempPath(),
            $"dune-platform-parent-probe-{Guid.NewGuid():N}.txt");
        try
        {
            var start = new ProcessStartInfo
            {
                FileName = executable,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            start.ArgumentList.Add("--command");
            start.ArgumentList.Add("self-test-parent-sleep-probe");
            start.ArgumentList.Add("--probe-file");
            start.ArgumentList.Add(probeFile);
            start.Environment[ForceShellParentEnvironment] = "1";
            start.Environment["DST_PLATFORM_SELF_TEST"] = "1";
            using var wrapper = Process.Start(start)
                ?? throw new InvalidOperationException("The shell-parent kill probe wrapper did not start.");
            wrapper.StandardInput.Close();
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (!File.Exists(probeFile) && DateTime.UtcNow < deadline)
            {
                Thread.Sleep(25);
            }
            if (!File.Exists(probeFile) ||
                !int.TryParse(File.ReadAllText(probeFile), out var childProcessId))
            {
                wrapper.Kill(false);
                return false;
            }
            using var child = Process.GetProcessById(childProcessId);
            wrapper.Kill(false);
            wrapper.WaitForExit(5_000);
            return child.WaitForExit(5_000);
        }
        catch (ArgumentException)
        {
            return true;
        }
        finally
        {
            try
            {
                if (File.Exists(probeFile)) File.Delete(probeFile);
            }
            catch
            {
            }
        }
    }

    private static int RelaunchWithShellParent(string[] args)
    {
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The helper executable path is unavailable.");
        var shellWindow = GetShellWindow();
        if (shellWindow == IntPtr.Zero)
        {
            throw new UnauthorizedAccessException(
                "No interactive shell process is available; cache access is disabled.");
        }
        GetWindowThreadProcessId(shellWindow, out var shellProcessId);
        var shellProcess = OpenProcess(ProcessCreateProcess | ProcessDuplicateHandle, false, shellProcessId);
        if (shellProcess == IntPtr.Zero)
        {
            var error = Marshal.GetLastWin32Error();
            throw new Win32Exception(
                error,
                $"The interactive shell process could not be opened as a process parent (Windows error {error}).");
        }

        var standardInput = IntPtr.Zero;
        var standardOutput = IntPtr.Zero;
        var standardError = IntPtr.Zero;
        var attributeList = IntPtr.Zero;
        var parentValue = IntPtr.Zero;
        var job = IntPtr.Zero;
        try
        {
            job = CreateKillOnCloseJob();
            standardInput = DuplicateInheritableStandardHandleToProcess(StdInputHandle, shellProcess);
            standardOutput = DuplicateInheritableStandardHandleToProcess(StdOutputHandle, shellProcess);
            standardError = DuplicateInheritableStandardHandleToProcess(StdErrorHandle, shellProcess);
            var attributeListSize = IntPtr.Zero;
            _ = InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
            if (attributeListSize == IntPtr.Zero || Marshal.GetLastWin32Error() != ErrorInsufficientBuffer)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The shell-parent process attribute size could not be determined.");
            }
            attributeList = Marshal.AllocHGlobal(attributeListSize);
            if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeListSize))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The shell-parent process attribute list could not be initialized.");
            }
            parentValue = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(parentValue, shellProcess);
            if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    new IntPtr(ProcThreadAttributeParentProcess),
                    parentValue,
                    new IntPtr(IntPtr.Size),
                    IntPtr.Zero,
                    IntPtr.Zero))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The Explorer parent process attribute could not be applied.");
            }

            var sid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value
                ?? throw new UnauthorizedAccessException("The current Windows user SID is unavailable.");
            var childArgs = args.Concat([ShellParentOption, sid]).ToArray();
            var commandLine = new StringBuilder(BuildCommandLine(executable, childArgs));
            var startup = new StartupInfoEx
            {
                StartupInfo = new StartupInfo
                {
                    cb = (uint)Marshal.SizeOf<StartupInfoEx>(),
                    dwFlags = StartfUseStdHandles,
                    hStdInput = standardInput,
                    hStdOutput = standardOutput,
                    hStdError = standardError
                },
                AttributeList = attributeList
            };
            if (!CreateProcessW(
                    executable,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CreateNoWindow | CreateSuspended | ExtendedStartupInfoPresent,
                    IntPtr.Zero,
                    Environment.CurrentDirectory,
                    ref startup,
                    out var processInformation))
            {
                var error = Marshal.GetLastWin32Error();
                throw new Win32Exception(
                    error,
                    $"The cache helper could not launch with Explorer as its process parent (Windows error {error}).");
            }
            CloseRemoteHandle(shellProcess, standardInput);
            CloseRemoteHandle(shellProcess, standardOutput);
            CloseRemoteHandle(shellProcess, standardError);
            standardInput = IntPtr.Zero;
            standardOutput = IntPtr.Zero;
            standardError = IntPtr.Zero;
            try
            {
                if (!AssignProcessToJobObject(job, processInformation.hProcess))
                {
                    var error = Marshal.GetLastWin32Error();
                    TerminateProcess(processInformation.hProcess, 1);
                    throw new Win32Exception(
                        error,
                        $"The shell-parented cache helper could not join its lifetime job (Windows error {error}).");
                }
                if (ResumeThread(processInformation.hThread) == uint.MaxValue)
                {
                    var error = Marshal.GetLastWin32Error();
                    TerminateProcess(processInformation.hProcess, 1);
                    throw new Win32Exception(
                        error,
                        $"The shell-parented cache helper could not resume (Windows error {error}).");
                }
                WaitForSingleObject(processInformation.hProcess, Infinite);
                if (!GetExitCodeProcess(processInformation.hProcess, out var exitCode))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "The shell-parented cache helper exit code is unavailable.");
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
            if (attributeList != IntPtr.Zero) DeleteProcThreadAttributeList(attributeList);
            if (parentValue != IntPtr.Zero) Marshal.FreeHGlobal(parentValue);
            if (attributeList != IntPtr.Zero) Marshal.FreeHGlobal(attributeList);
            if (standardInput != IntPtr.Zero) CloseRemoteHandle(shellProcess, standardInput);
            if (standardOutput != IntPtr.Zero) CloseRemoteHandle(shellProcess, standardOutput);
            if (standardError != IntPtr.Zero) CloseRemoteHandle(shellProcess, standardError);
            if (job != IntPtr.Zero) CloseHandle(job);
            CloseHandle(shellProcess);
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
                    try
                    {
                        return DuplicatePrimaryToken(linked.LinkedToken);
                    }
                    catch (Win32Exception)
                    {
                        // Some UAC linked-token handles expose query access but
                        // cannot be duplicated. Fall back to the same user's
                        // unelevated interactive shell token below.
                    }
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
                    TokenDuplicate | TokenQuery,
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

    private static IntPtr DuplicateInheritableStandardHandleToProcess(
        int standardHandle,
        IntPtr targetProcess)
    {
        var source = GetStdHandle(standardHandle);
        if (source == IntPtr.Zero || source == new IntPtr(-1))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "A cache helper standard handle is unavailable.");
        }
        if (!DuplicateHandle(
                GetCurrentProcess(),
                source,
                targetProcess,
                out var duplicate,
                0,
                true,
                DuplicateSameAccess))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "A cache helper standard handle could not be duplicated into Explorer.");
        }
        return duplicate;
    }

    private static void CloseRemoteHandle(IntPtr process, IntPtr remoteHandle)
    {
        if (!DuplicateHandle(
                process,
                remoteHandle,
                GetCurrentProcess(),
                out var localDuplicate,
                0,
                false,
                DuplicateCloseSource | DuplicateSameAccess))
        {
            return;
        }
        CloseHandle(localDuplicate);
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
    private struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public IntPtr AttributeList;
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

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr attributeList,
        int attributeCount,
        int flags,
        ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr attributeList,
        uint flags,
        IntPtr attribute,
        IntPtr value,
        IntPtr size,
        IntPtr previousValue,
        IntPtr returnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(
        string? applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref StartupInfoEx startupInfo,
        out ProcessInformation processInformation);

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
