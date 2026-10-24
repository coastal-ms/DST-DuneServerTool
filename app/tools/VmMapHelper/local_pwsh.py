#!/usr/bin/env python3
"""Execute the existing bundled observers locally on Linux."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def options(args):
    return {args[i].lower(): args[i + 1] for i in range(len(args) - 1)
            if args[i].startswith('-') and not args[i + 1].startswith('-')}


def main(args):
    opt = options(args)
    script = Path(opt['-file']).name.lower()
    output = Path(opt['-outputfile'])
    started = time.monotonic()
    if script == 'remote.ps1':
        command = Path(opt['-commandfile']).read_text().replace('\r', '')
        source = Path(opt['-inputfile']).read_bytes() if '-inputfile' in opt else None
        # These are installed observer commands, never HTTP-supplied shell input.
        result = subprocess.run(['/bin/sh', '-c', command], input=source,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=int(opt.get('-timeout', '300')))
        if result.returncode:
            sys.stderr.buffer.write(result.stderr)
            return result.returncode
        output.write_bytes(result.stdout)
    elif script == 'query.ps1':
        namespace = os.environ['DST_MAP_NAMESPACE']
        kube = [os.environ['DST_MAP_KUBECTL']] if os.environ.get('DST_MAP_KUBECTL') else ['k3s', 'kubectl']
        pods = subprocess.check_output(kube + ['get', 'pods', '-n', namespace,
                                       '--field-selector=status.phase=Running', '-o', 'name'], text=True)
        pod = next(p for p in pods.splitlines() if '-db-dbdepl-sts-' in p)
        sql = Path(opt['-sqlfile']).read_text()
        command = kube + ['exec', '-i', '-n', namespace, pod, '--',
                   'psql', '-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1',
                   '-U', 'dune', '-d', 'dune', '-p', os.environ.get('DST_MAP_DB_PORT', '15432')]
        # A separate read-only transaction for every fixed, bundled query.
        result = subprocess.run(command, input='BEGIN READ ONLY;\nSET LOCAL statement_timeout=20000;\n'
                                + sql + '\nROLLBACK;\n', text=True,
                                capture_output=True, timeout=30)
        if result.returncode:
            sys.stderr.write('Local read-only map query failed\n')
            return result.returncode
        rows = [[line] for line in result.stdout.splitlines() if line.strip()]
        output.write_text(json.dumps({'ok': True, 'rows': rows, 'rowCount': len(rows),
                                     'durationMs': round((time.monotonic() - started) * 1000)}))
    else:
        raise ValueError('Unsupported local observer wrapper')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
