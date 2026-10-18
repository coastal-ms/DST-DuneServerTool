"""Cancellable observer processes; cancellation never targets the game or DST."""
import os
import signal
import subprocess
import threading
import time
from pathlib import Path
from contextlib import contextmanager

_local = threading.local()
_job_events={}

def cancel_job(name):
    event=_job_events.get(name)
    if event:event.set()

@contextmanager
def priority(name, root, job=None):
    previous=getattr(_local,"settings",None)
    event=_job_events.setdefault(job,threading.Event()) if job else threading.Event()
    event.clear()
    _local.settings=(name,str(root),event)
    try:yield
    finally:_local.settings=previous

def core_waiting(folder,prefix="core"):
    # Stale wait markers from an interrupted observer expire automatically.
    for path in folder.glob(prefix+'-wait-*'):
        try:
            if time.time()-path.stat().st_mtime<2:return True
        except FileNotFoundError:pass
    return False

@contextmanager
def io_slot(args, env):
    # Python stages pass the budget to their children. Only remote reads hold
    # the slot, so optional work yields between bounded batches. Positions have
    # their own lane and never wait behind discovery.
    mode=env.get("DST_ATLAS_IO_PRIORITY")
    root=env.get("DST_ATLAS_IO_ROOT")
    executable=Path(str(args[0])).stem.lower()
    if not root or mode not in ("core","optional") or executable not in ("pwsh","powershell","ssh"):
        yield;return
    folder=Path(root);folder.mkdir(parents=True,exist_ok=True)
    waiting=folder/(mode+"-wait-"+str(os.getpid())+"-"+str(threading.get_ident()))
    handle=(folder/"discovery-io.lock").open("a+b")
    if handle.tell()==0:handle.write(b"0");handle.flush()
    acquired=False
    try:
        while not acquired:
            if _cancelled.is_set():raise Cancelled("Map collection stopped")
            waiting.write_text(str(time.time()))
            try:streak=int((folder/'core-streak').read_text())
            except (OSError,ValueError):streak=0
            if (mode=='optional' and core_waiting(folder) and streak<2) or (mode=='core' and streak>=2 and core_waiting(folder,'optional')):
                time.sleep(.05);continue
            try:
                handle.seek(0)
                if os.name=="nt":
                    import msvcrt
                    msvcrt.locking(handle.fileno(),msvcrt.LK_NBLCK,1)
                else:
                    import fcntl
                    fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
                acquired=True
            except OSError:time.sleep(.05)
        waiting.unlink(missing_ok=True)
        (folder/"core-streak").write_text(str(streak+1 if mode=="core" else 0))
        yield
    finally:
        waiting.unlink(missing_ok=True)
        if acquired:
            handle.seek(0)
            if os.name=="nt":
                import msvcrt
                msvcrt.locking(handle.fileno(),msvcrt.LK_UNLCK,1)
            else:
                import fcntl
                fcntl.flock(handle,fcntl.LOCK_UN)
        handle.close()


class Cancelled(RuntimeError):
    pass


_cancelled = threading.Event()
_launch_lock = threading.Lock()


def cancel():
    with _launch_lock:
        _cancelled.set()


def reset():
    with _launch_lock:
        _cancelled.clear()


def _terminate(process):
    if process.poll() is not None:
        return
    if os.name == 'nt':
        # The live Popen handle prevents PID reuse. /T includes the observer's
        # PowerShell/SSH children; no unrelated service is selected by name.
        subprocess.run(['taskkill.exe', '/PID', str(process.pid), '/T', '/F'],
                       capture_output=True, timeout=5,
                       creationflags=subprocess.CREATE_NO_WINDOW)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if process.poll() is None:
        process.kill()


def run(args, *, timeout, capture_output=False, text=False, input=None, **kwargs):
    env=dict(kwargs.pop("env",os.environ))
    settings=getattr(_local,"settings",None)
    if settings:env.update(DST_ATLAS_IO_PRIORITY=settings[0],DST_ATLAS_IO_ROOT=settings[1])
    with io_slot(args,env):
        return _run(args,timeout=timeout,capture_output=capture_output,text=text,input=input,env=env,**kwargs)


def _run(args, *, timeout, capture_output=False, text=False, input=None, **kwargs):
    settings=getattr(_local,"settings",None)
    job_cancelled=settings[2] if settings else threading.Event()
    if capture_output:
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if input is not None:
        kwargs['stdin'] = subprocess.PIPE
    if os.name != 'nt':
        kwargs['start_new_session'] = True
    else:
        kwargs['creationflags'] = (kwargs.get('creationflags', 0)
                                   | subprocess.CREATE_NO_WINDOW
                                   | subprocess.BELOW_NORMAL_PRIORITY_CLASS)
    with _launch_lock:
        if _cancelled.is_set() or job_cancelled.is_set():
            raise Cancelled('Map collection stopped')
        process = subprocess.Popen(args, text=text, **kwargs)
    deadline = time.monotonic() + timeout
    try:
        first = True
        while True:
            if _cancelled.is_set() or job_cancelled.is_set():
                raise Cancelled('Map collection stopped')
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(args, timeout)
            try:
                out, err = process.communicate(input=input if first else None,
                                               timeout=min(.2, remaining))
                if _cancelled.is_set() or job_cancelled.is_set():
                    raise Cancelled('Map collection stopped')
                return subprocess.CompletedProcess(args, process.returncode, out, err)
            except subprocess.TimeoutExpired:
                first = False
    finally:
        try:
            _terminate(process)
        finally:
            try:process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                for stream in (process.stdin,process.stdout,process.stderr):
                    if stream:stream.close()
