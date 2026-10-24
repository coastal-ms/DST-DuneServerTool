"""Run the managed read-only collector without the Windows desktop backend."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(os.environ['DST_MAP_ROOT'])
children = []
os.nice(10)
try:
    (root / 'ready.json').unlink(missing_ok=True)
    children.append(subprocess.Popen([sys.executable, str(root / 'server.py')], cwd=root))
    deadline = time.monotonic() + 20
    while not (root / 'ready.json').exists():
        if children[0].poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Map collector failed to start')
        time.sleep(.1)
    def shutdown(*_):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, shutdown)
    while all(p.poll() is None for p in children):
        time.sleep(.5)
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
