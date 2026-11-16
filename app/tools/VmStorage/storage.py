"""Explicit, journaled growth of a qualified GPT/linear-LVM/ext4 root volume.

Inspection is read-only. Preparation captures metadata; apply requires its
verified hash after the caller has copied that archive off the guest.
"""
import argparse
import contextlib
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tarfile
import time
import uuid

STATE = Path('/var/lib/dune-server/storage-expansion')
TOOLS = ('findmnt', 'lsblk', 'sfdisk', 'lvm', 'growpart', 'resize2fs', 'dumpe2fs')


def run(args, **kwargs):
    return subprocess.check_output(args, stderr=subprocess.PIPE, env={**os.environ, 'LC_ALL': 'C'}, **kwargs)


def rows(command, report):
    return json.loads(run(command))['report'][0][report]


def integer(value):
    return int(float(str(value).strip()))


def walk(nodes, parent=None):
    for node in nodes:
        yield node, parent
        yield from walk(node.get('children', []), node)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def identify(plan):
    return {key: plan[key] for key in ('disk', 'partition', 'partitionNumber', 'partitionStart', 'diskId', 'pvUuid', 'lvUuid', 'vg')}


def inspect():
    missing = [tool for tool in TOOLS if not shutil.which(tool)]
    if missing:
        return {'supported': False, 'canGrow': False, 'toolsReady': False, 'canInstallTools': Path('/etc/alpine-release').exists() and bool(shutil.which('apk')), 'reason': 'Missing guest tools: ' + ', '.join(missing) + '. No packages were installed.'}
    try:
        return inspect_layout()
    except ValueError as error:
        return {'supported': False, 'canGrow': False, 'toolsReady': True, 'reason': str(error)}


def inspect_layout():
    root = json.loads(run(['findmnt', '--json', '--target', '/', '--output', 'SOURCE,FSTYPE,TARGET']))['filesystems'][0]
    if root['fstype'] != 'ext4' or root['target'] != '/':
        raise ValueError('Only an ext4 root filesystem on a linear LVM volume is supported.')
    lvs = rows(['lvm', 'lvs', '--reportformat', 'json', '--units', 'b', '--nosuffix', '-o', 'lv_path,lv_size,vg_name,lv_uuid,segtype,lv_attr'], 'lv')
    matches = [lv for lv in lvs if os.path.realpath(lv['lv_path']) == os.path.realpath(root['source'])]
    if not matches or len({v['lv_uuid'] for v in matches}) != 1:
        raise ValueError('The mounted root must resolve to exactly one LVM volume.')
    lv = matches[0]
    if any(v['segtype'].strip() != 'linear' or not v['lv_attr'].startswith('-') for v in matches) or len({v['lv_uuid'] for v in lvs if v['vg_name'] == lv['vg_name']}) != 1:
        raise ValueError('This action supports a single regular linear root LV; shared, thin, snapshot and RAID layouts need manual review.')
    pvs = [p for p in rows(['lvm', 'pvs', '--reportformat', 'json', '--units', 'b', '--nosuffix', '-o', 'pv_name,pv_size,pv_free,vg_name,pv_uuid'], 'pv') if p['vg_name'] == lv['vg_name']]
    if len(pvs) != 1:
        raise ValueError('The root volume group must use exactly one partition-backed physical volume.')
    pv = pvs[0]
    vg = next(v for v in rows(['lvm', 'vgs', '--reportformat', 'json', '--units', 'b', '--nosuffix', '-o', 'vg_name,vg_extent_size,vg_free_count,vg_uuid'], 'vg') if v['vg_name'] == lv['vg_name'])
    devices = list(walk(json.loads(run(['lsblk', '--tree', '--json', '--bytes', '--output', 'PATH,TYPE,SIZE']))['blockdevices']))
    found = [(node, parent) for node, parent in devices if os.path.realpath(node['path']) == os.path.realpath(pv['pv_name'])]
    if len(found) != 1 or found[0][0]['type'] != 'part' or not found[0][1] or found[0][1]['type'] != 'disk':
        raise ValueError('The root physical volume must be a direct partition of one disk; encrypted or layered layouts need manual review.')
    part, disk = found[0]
    table = json.loads(run(['sfdisk', '--json', disk['path']]))['partitiontable']
    if table['label'] != 'gpt' or table.get('sectorsize', 512) != 512:
        raise ValueError('Only GPT disks with 512-byte logical sectors are supported.')
    partitions = table['partitions'];selected = [p for p in partitions if os.path.realpath(p['node']) == os.path.realpath(part['path'])]
    if len(selected) != 1 or selected[0]['start'] != max(p['start'] for p in partitions):
        raise ValueError('The root PV must be the last partition; partitions are never moved.')
    p = selected[0]
    number = re.search(r'(?:p)?([0-9]+)$', part['path'])
    if not number or not re.fullmatch(r'/dev/[A-Za-z0-9_-]+', disk['path']):
        raise ValueError('Disk identity could not be qualified.')
    # NVMe names end in digits too; use the explicit partition suffix.
    suffix = part['path'][len(disk['path']):]
    if not re.fullmatch(r'p?[1-9][0-9]*', suffix):
        raise ValueError('Partition identity does not match its parent disk.')
    filesystem = run(['dumpe2fs', '-h', lv['lv_path']]).decode()
    block_count = re.search(r'^Block count:\s+([0-9]+)$', filesystem, re.M)
    block_size = re.search(r'^Block size:\s+([0-9]+)$', filesystem, re.M)
    if not block_count or not block_size:
        raise ValueError('The ext4 filesystem geometry could not be read.')
    plan = {'supported': True, 'toolsReady': True, 'disk': disk['path'], 'partition': part['path'], 'partitionNumber': int(suffix.lstrip('p')),
            'diskBytes': integer(disk['size']), 'partitionStart': int(p['start']), 'partitionSectors': int(p['size']), 'diskId': table['id'],
            'pvUuid': pv['pv_uuid'].strip(), 'pvBytes': integer(pv['pv_size']), 'lvUuid': lv['lv_uuid'].strip(), 'lv': lv['lv_path'],
            'lvBytes': integer(lv['lv_size']), 'vg': lv['vg_name'].strip(), 'extentBytes': integer(vg['vg_extent_size']),
            'freeExtents': integer(vg['vg_free_count']), 'filesystemBytes': int(block_count[1]) * int(block_size[1])}
    plan['baselineFreeExtents'] = plan['freeExtents']
    latest = read_latest()
    if latest and latest.get('phase') != 'completed':
        old = latest['plan']
        if identify(old) != identify(plan):
            raise ValueError('An unfinished expansion belongs to a different disk layout. Review its recovery record first.')
        if plan['lvBytes'] < old['lvBytes'] or plan['freeExtents'] < old['baselineFreeExtents']:
            raise ValueError('LVM allocations changed after an unfinished expansion. Review the recovery record before proceeding.')
        plan['baselineFreeExtents'] = old['baselineFreeExtents']
        if latest['phase'] != 'prepared':plan['recoveryOf'] = latest['id']
        elif old.get('recoveryOf'):plan['recoveryOf'] = old['recoveryOf']
    unpartitioned = max(0, plan['diskBytes'] - (plan['partitionStart'] + plan['partitionSectors'] + 34) * 512)
    plan['partitionGrowthBytes'] = unpartitioned if unpartitioned >= 1024 * 1024 else 0
    plan['pvGrowthBytes'] = max(0, plan['partitionSectors'] * 512 - plan['pvBytes'] - plan['extentBytes'])
    plan['lvGrowthBytes'] = max(0, plan['freeExtents'] - plan['baselineFreeExtents']) * plan['extentBytes']
    plan['filesystemGrowthBytes'] = max(0, plan['lvBytes'] - plan['filesystemBytes'])
    plan['canGrow'] = any(plan[k] > 0 for k in ('partitionGrowthBytes', 'pvGrowthBytes', 'lvGrowthBytes', 'filesystemGrowthBytes'))
    plan['reason'] = 'New disk capacity can be added to the root filesystem.' if plan['canGrow'] else 'The supported root layout already uses its available capacity. Existing volume-group free extents are reserved and will not be consumed.'
    plan['revision'] = digest(plan)
    return plan


def read_latest():
    path = STATE / 'current.json'
    return json.loads(path.read_text()) if path.exists() else None


def save(record, phase, **values):
    record.update(phase=phase, updatedAt=time.time(), **values)
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    for path in (STATE / record['id'] / 'operation.json', STATE / 'current.json'):
        temp = path.with_suffix('.tmp');temp.write_text(json.dumps(record));temp.chmod(0o600);temp.replace(path)


@contextlib.contextmanager
def locked():
    # Lock-file opens do not touch block devices. Kernel lock releases on exit.
    with open('/tmp/dst-storage-expansion.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def prepare(revision):
    plan = inspect()
    if not plan.get('supported') or not plan.get('canGrow') or plan['revision'] != revision:
        raise ValueError('The storage preview changed or no supported growth remains. Inspect again before applying.')
    identifier = uuid.uuid4().hex;folder = STATE / identifier;folder.mkdir(mode=0o700, parents=True)
    record = {'id': identifier, 'plan': plan, 'startedAt': time.time()}
    files = {'partition-table.sfdisk': run(['sfdisk', '--dump', plan['disk']]),
             'lvm.conf': run(['lvm', 'vgcfgbackup', '--file', str(folder / 'lvm.conf'), plan['vg']])}
    files['lvm.conf'] = (folder / 'lvm.conf').read_bytes()
    with open(plan['disk'], 'rb') as disk:
        files['primary-gpt.bin'] = disk.read(34 * 512)
        primary = files['primary-gpt.bin'][512:1024]
        if primary[:8] != b'EFI PART':raise ValueError('Primary GPT identity changed.')
        backup_lba = struct.unpack_from('<Q', primary, 32)[0]
        if backup_lba < 33 or backup_lba * 512 >= plan['diskBytes']:raise ValueError('Backup GPT location is unsupported.')
        disk.seek((backup_lba - 32) * 512);files['original-backup-gpt.bin'] = disk.read(33 * 512)
        if any(len(files[name]) != size for name, size in [('primary-gpt.bin', 34*512), ('original-backup-gpt.bin',33*512)]):raise ValueError('GPT backup was truncated.')
    files['plan.json'] = json.dumps(plan, indent=2).encode()
    archive = folder / 'metadata.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        for name, data in files.items():
            entry=tarfile.TarInfo(name);entry.size=len(data);entry.mode=0o600;tar.addfile(entry,io.BytesIO(data))
    archive.chmod(0o600);save(record, 'prepared', metadataPath=str(archive), metadataSha256=hashlib.sha256(archive.read_bytes()).hexdigest())
    return record


def apply(identifier, expected_hash):
    if not re.fullmatch(r'[a-f0-9]{32}', identifier or '') or not re.fullmatch(r'[a-f0-9]{64}', expected_hash or ''):
        raise ValueError('Choose the verified prepared operation.')
    record=json.loads((STATE/identifier/'operation.json').read_text());plan=record['plan']
    if record['phase']!='prepared' or record['metadataSha256']!=expected_hash or hashlib.sha256(Path(record['metadataPath']).read_bytes()).hexdigest()!=expected_hash:
        raise ValueError('Recovery metadata was not verified. No disk changes were made.')
    fresh=inspect()
    # The newly prepared journal must not alter its own preview fingerprint.
    if fresh.get('revision')!=plan['revision']:raise ValueError('Storage changed after preparation. No disk changes were made.')
    try:
        if plan['partitionGrowthBytes']:
            save(record,'partition',message='Expanding the last partition without moving its start.')
            run(['growpart',plan['disk'],str(plan['partitionNumber'])])
        # Re-read the kernel/table, not command output, before every LVM step.
        actual=json.loads(run(['sfdisk','--json',plan['disk']]))['partitiontable']
        partition=next(p for p in actual['partitions'] if p['node']==plan['partition'])
        if partition['start']!=plan['partitionStart'] or partition['size']<plan['partitionSectors'] or actual['id']!=plan['diskId']:
            raise ValueError('Partition identity or start changed; further expansion stopped.')
        save(record,'physical-volume',message='Making the enlarged partition available to LVM.')
        run(['lvm','pvresize',plan['partition']])
        vg=next(v for v in rows(['lvm','vgs','--reportformat','json','-o','vg_name,vg_free_count'],'vg') if v['vg_name'].strip()==plan['vg'])
        new_extents=integer(vg['vg_free_count'])-plan['baselineFreeExtents']
        if new_extents<0:raise ValueError('Reserved volume-group free space changed. No LV allocation attempted.')
        pv=next(p for p in rows(['lvm','pvs','--reportformat','json','--units','b','--nosuffix','-o','pv_name,pv_size'],'pv') if p['pv_name']==plan['partition'])
        maximum=(integer(pv['pv_size'])-plan['pvBytes']+plan['lvGrowthBytes'])//plan['extentBytes']
        if new_extents>maximum:raise ValueError('Unexpected free extents appeared during expansion. Unrelated allocations were not consumed.')
        if new_extents:
            save(record,'logical-volume',message='Adding only newly available extents to the root logical volume.')
            run(['lvm','lvextend','-l','+'+str(new_extents),plan['lv']])
        save(record,'filesystem',message='Expanding the mounted ext4 filesystem.')
        run(['resize2fs',plan['lv']])
        save(record,'completed',message='Storage expansion completed; checking capacity.')
        after=inspect()
        if identify(after)!=identify(plan) or after['canGrow'] or after['freeExtents']<plan['baselineFreeExtents']:
            raise ValueError('Post-expansion capacity verification did not pass. Recovery data was retained.')
        save(record,'completed',after=after,message='The root filesystem now uses the supported expanded capacity. No reboot was requested.')
    except Exception as error:
        save(record,'failed',error=str(error),message='Expansion stopped. Completed stages are retained; inspect storage before recovery.');raise
    return record


def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['inspect','prepare','apply','status']);parser.add_argument('--revision');parser.add_argument('--operation');parser.add_argument('--metadata-sha256');args=parser.parse_args()
    try:
        if args.action=='inspect':result=inspect()
        elif args.action=='status':result=read_latest() or {'phase':'idle'}
        else:
            with locked():result=prepare(args.revision) if args.action=='prepare' else apply(args.operation,args.metadata_sha256)
        print(json.dumps({'ok':True,'data':result}))
    except Exception as error:
        print(json.dumps({'ok':False,'error':str(error)}));raise SystemExit(1)


if __name__=='__main__':main()
