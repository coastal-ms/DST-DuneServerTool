using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DunePlatformStore;

internal static class StorageSecurity
{
    private const uint FileReadAttributes = 0x0080;
    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;
    private const uint OpenAlways = 4;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileTypeDisk = 0x0001;

    internal static string GetDefaultDatabasePath()
    {
        var local = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData,
            Environment.SpecialFolderOption.None);
        if (string.IsNullOrWhiteSpace(local))
        {
            throw new InvalidOperationException("The Windows Local AppData known folder is unavailable.");
        }
        return Path.Combine(local, "DuneServer", "platform-cache", "platform-cache-v1.sqlite");
    }

    internal static void EnsureProtectedDirectory(string databasePath)
    {
        var fullPath = ValidateAllowedDatabasePath(databasePath);
        var directoryPath = Path.GetDirectoryName(fullPath)
            ?? throw new InvalidOperationException("The cache database has no parent directory.");
        using var lease = AcquireDirectories(fullPath, createMissing: true);
        var directory = new DirectoryInfo(directoryPath);
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        var user = identity.User
            ?? throw new UnauthorizedAccessException("The current Windows user SID is unavailable.");
        var system = new System.Security.Principal.SecurityIdentifier(
            System.Security.Principal.WellKnownSidType.LocalSystemSid,
            null);
        var inheritance = System.Security.AccessControl.InheritanceFlags.ContainerInherit |
            System.Security.AccessControl.InheritanceFlags.ObjectInherit;
        var security = new System.Security.AccessControl.DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(user);
        security.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(
            user,
            System.Security.AccessControl.FileSystemRights.FullControl,
            inheritance,
            System.Security.AccessControl.PropagationFlags.None,
            System.Security.AccessControl.AccessControlType.Allow));
        security.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(
            system,
            System.Security.AccessControl.FileSystemRights.FullControl,
            inheritance,
            System.Security.AccessControl.PropagationFlags.None,
            System.Security.AccessControl.AccessControlType.Allow));
        directory.SetAccessControl(security);
        lease.RevalidateAll();

        var actual = directory.GetAccessControl(System.Security.AccessControl.AccessControlSections.Access);
        var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            user.Value,
            system.Value
        };
        foreach (System.Security.AccessControl.FileSystemAccessRule rule in actual.GetAccessRules(
                     includeExplicit: true,
                     includeInherited: false,
                     targetType: typeof(System.Security.Principal.SecurityIdentifier)))
        {
            if (rule.AccessControlType == System.Security.AccessControl.AccessControlType.Allow &&
                !allowed.Contains(
                    ((System.Security.Principal.SecurityIdentifier)rule.IdentityReference).Value))
            {
                throw new UnauthorizedAccessException(
                    "The cache directory ACL contains an unexpected principal.");
            }
        }
    }

    internal static StorageLease AcquireDatabase(string databasePath, bool readOnly)
    {
        var fullPath = ValidateAllowedDatabasePath(databasePath);
        var lease = AcquireDirectories(fullPath, createMissing: false);
        try
        {
            lease.HoldDatabase(fullPath, createIfMissing: !readOnly);
            lease.HoldSidecars(fullPath);
            return lease;
        }
        catch
        {
            lease.Dispose();
            throw;
        }
    }

    internal static bool SelfTestHeldHandleRace(string root)
    {
        var databasePath = Path.Combine(root, "handle-race", "platform-cache-v1.sqlite");
        EnsureProtectedDirectory(databasePath);
        using var lease = AcquireDatabase(databasePath, readOnly: false);
        var directory = Path.GetDirectoryName(databasePath)!;
        var movedDirectory = directory + "-moved";
        var movedDatabase = databasePath + ".moved";
        var directoryBlocked = false;
        var databaseBlocked = false;
        try
        {
            Directory.Move(directory, movedDirectory);
        }
        catch (IOException)
        {
            directoryBlocked = true;
        }
        catch (UnauthorizedAccessException)
        {
            directoryBlocked = true;
        }
        try
        {
            File.Move(databasePath, movedDatabase);
        }
        catch (IOException)
        {
            databaseBlocked = true;
        }
        catch (UnauthorizedAccessException)
        {
            databaseBlocked = true;
        }
        return directoryBlocked && databaseBlocked;
    }

    private static StorageLease AcquireDirectories(string databasePath, bool createMissing)
    {
        var trustedRoot = GetTrustedRoot(databasePath);
        var lease = new StorageLease(trustedRoot);
        try
        {
            lease.HoldDirectory(trustedRoot);
            var directoryPath = Path.GetDirectoryName(databasePath)!;
            var relative = Path.GetRelativePath(trustedRoot, directoryPath);
            if (relative == "." || relative.StartsWith("..", StringComparison.Ordinal) ||
                Path.IsPathRooted(relative))
            {
                throw new UnauthorizedAccessException("The cache path escapes its trusted root.");
            }

            var current = trustedRoot;
            foreach (var component in relative.Split(
                         Path.DirectorySeparatorChar,
                         StringSplitOptions.RemoveEmptyEntries))
            {
                current = Path.Combine(current, component);
                if (!Directory.Exists(current))
                {
                    if (File.Exists(current))
                    {
                        throw new UnauthorizedAccessException(
                            $"A cache path directory component is a file: {current}");
                    }
                    if (!createMissing)
                    {
                        throw new DirectoryNotFoundException(
                            $"The cache directory does not exist: {current}");
                    }
                    Directory.CreateDirectory(current);
                }
                lease.HoldDirectory(current);
            }
            return lease;
        }
        catch
        {
            lease.Dispose();
            throw;
        }
    }

    private static string ValidateAllowedDatabasePath(string databasePath)
    {
        var fullPath = Path.GetFullPath(databasePath);
        if (IsSelfTest())
        {
            return fullPath;
        }
        var expected = Path.GetFullPath(GetDefaultDatabasePath());
        var migrationPrefix = expected + ".migration-";
        var isMigrationBackup = fullPath.StartsWith(migrationPrefix, StringComparison.OrdinalIgnoreCase) &&
            fullPath.EndsWith(".bak", StringComparison.OrdinalIgnoreCase) &&
            fullPath.Length <= expected.Length + 64;
        if (!string.Equals(fullPath, expected, StringComparison.OrdinalIgnoreCase) && !isMigrationBackup)
        {
            throw new UnauthorizedAccessException("The production cache path is fixed under Local AppData.");
        }
        return fullPath;
    }

    private static string GetTrustedRoot(string databasePath)
    {
        if (!IsSelfTest())
        {
            return Path.GetFullPath(Path.GetDirectoryName(
                Path.GetDirectoryName(
                    Path.GetDirectoryName(GetDefaultDatabasePath())!)!)!);
        }
        return Path.GetPathRoot(Path.GetFullPath(databasePath))
            ?? throw new UnauthorizedAccessException("The test cache path has no trusted volume root.");
    }

    private static bool IsSelfTest() =>
        string.Equals(
            Environment.GetEnvironmentVariable("DST_PLATFORM_SELF_TEST"),
            "1",
            StringComparison.Ordinal);

    internal sealed class StorageLease : IDisposable
    {
        private readonly List<(string Path, SafeFileHandle Handle)> handles = [];
        private readonly string trustedFinalPath;

        internal StorageLease(string trustedRoot)
        {
            using var handle = OpenPath(
                trustedRoot,
                isDirectory: true,
                create: false);
            trustedFinalPath = NormalizePath(GetFinalPath(handle));
        }

        internal void HoldDirectory(string path)
        {
            Hold(path, isDirectory: true, create: false);
        }

        internal void HoldDatabase(string path, bool createIfMissing)
        {
            Hold(path, isDirectory: false, create: createIfMissing);
        }

        internal void HoldSidecars(string databasePath)
        {
            foreach (var suffix in new[] { "-wal", "-shm" })
            {
                var path = databasePath + suffix;
                if (Directory.Exists(path))
                {
                    throw new UnauthorizedAccessException(
                        $"A cache sidecar path is not a regular file: {path}");
                }
                if (handles.All(
                        value => !string.Equals(value.Path, path, StringComparison.OrdinalIgnoreCase)))
                {
                    Hold(path, isDirectory: false, create: true);
                }
            }
        }

        internal void RevalidateAll()
        {
            foreach (var (path, handle) in handles)
            {
                ValidateHandle(path, handle, trustedFinalPath);
            }
        }

        private void Hold(string path, bool isDirectory, bool create)
        {
            var fullPath = Path.GetFullPath(path);
            var handle = OpenPath(
                fullPath,
                isDirectory,
                create);
            try
            {
                ValidateHandle(fullPath, handle, trustedFinalPath);
                handles.Add((fullPath, handle));
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            for (var index = handles.Count - 1; index >= 0; index--)
            {
                handles[index].Handle.Dispose();
            }
            handles.Clear();
        }
    }

    private static SafeFileHandle OpenPath(
        string path,
        bool isDirectory,
        bool create)
    {
        var desiredAccess = isDirectory ? FileReadAttributes : GenericRead | GenericWrite;
        var creation = create ? OpenAlways : OpenExisting;
        var flags = FileFlagOpenReparsePoint | (isDirectory ? FileFlagBackupSemantics : 0);
        var handle = CreateFileW(
            path,
            desiredAccess,
            FileShareRead | FileShareWrite,
            IntPtr.Zero,
            creation,
            flags,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, $"Could not safely open cache path '{path}'.");
        }
        return handle;
    }

    private static void ValidateHandle(string path, SafeFileHandle handle, string trustedFinalPath)
    {
        if (GetFileType(handle) != FileTypeDisk)
        {
            throw new UnauthorizedAccessException($"The cache path is not a disk file: {path}");
        }
        if (!GetFileInformationByHandleEx(
                handle,
                FileInfoByHandleClass.FileAttributeTagInfo,
                out var info,
                (uint)Marshal.SizeOf<FileAttributeTagInfo>()))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                $"Could not inspect cache path '{path}'.");
        }
        if ((info.FileAttributes & (uint)FileAttributes.ReparsePoint) != 0)
        {
            throw new UnauthorizedAccessException($"The cache path cannot be a reparse point: {path}");
        }
        var finalPath = NormalizePath(GetFinalPath(handle));
        if (!IsWithinRoot(finalPath, trustedFinalPath))
        {
            throw new UnauthorizedAccessException($"The cache path escapes its trusted root: {path}");
        }
    }

    private static bool IsWithinRoot(string path, string root)
    {
        var normalizedRoot = root.TrimEnd(Path.DirectorySeparatorChar);
        return string.Equals(path, normalizedRoot, StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith(normalizedRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static string GetFinalPath(SafeFileHandle handle)
    {
        var capacity = 512;
        while (capacity <= 32768)
        {
            var buffer = new char[capacity];
            var length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Length, 0);
            if (length == 0)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Could not resolve the final cache path.");
            }
            if (length < buffer.Length)
            {
                return new string(buffer, 0, (int)length);
            }
            capacity = checked((int)length + 1);
        }
        throw new PathTooLongException("The final cache path exceeds the Windows path limit.");
    }

    private static string NormalizePath(string path)
    {
        const string uncPrefix = @"\\?\UNC\";
        const string longPrefix = @"\\?\";
        if (path.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase))
        {
            path = @"\\" + path[uncPrefix.Length..];
        }
        else if (path.StartsWith(longPrefix, StringComparison.OrdinalIgnoreCase))
        {
            path = path[longPrefix.Length..];
        }
        return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
    }

    private enum FileInfoByHandleClass
    {
        FileAttributeTagInfo = 9
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileAttributeTagInfo
    {
        public uint FileAttributes;
        public uint ReparseTag;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle hFile,
        FileInfoByHandleClass fileInformationClass,
        out FileAttributeTagInfo lpFileInformation,
        uint dwBufferSize);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle hFile,
        [Out] char[] lpszFilePath,
        uint cchFilePath,
        uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetFileType(SafeFileHandle hFile);
}
