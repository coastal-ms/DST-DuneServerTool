"""Tie the private map host to the owning DST backend process, not its window."""
import ctypes
import os
from ctypes import wintypes


class HostProcess:
    def __init__(self, pid, creation_filetime):
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        self.kernel.GetProcessTimes.argtypes = (wintypes.HANDLE,) + (ctypes.POINTER(wintypes.FILETIME),) * 4
        self.kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        self.kernel.WaitForSingleObject.restype = wintypes.DWORD
        self.handle = self.kernel.OpenProcess(0x100000 | 0x1000, False, pid)
        if not self.handle:
            raise RuntimeError('Owning DST backend is unavailable')
        times = [wintypes.FILETIME() for _ in range(4)]
        if not self.kernel.GetProcessTimes(self.handle, *(ctypes.byref(t) for t in times)):
            self.close()
            raise RuntimeError('Cannot verify owning DST backend')
        actual = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
        if actual != creation_filetime:
            self.close()
            raise RuntimeError('Owning DST backend identity changed')

    def wait_for_exit(self, stop):
        while not stop.is_set():
            result = self.kernel.WaitForSingleObject(self.handle, 500)
            if result == 0:
                return True
            if result != 258:
                return True  # A failed ownership check also stops collection.
        return False

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def from_environment():
    pid = os.environ.get('DST_ATLAS_HOST_PID')
    created = os.environ.get('DST_ATLAS_HOST_CREATED')
    if pid is None and created is None:
        return None  # Standalone read-only research/review host.
    if not pid or not created or not pid.isdigit() or not created.isdigit() or int(pid) <= 0:
        raise ValueError('Invalid owning DST backend identity')
    return HostProcess(int(pid), int(created))
