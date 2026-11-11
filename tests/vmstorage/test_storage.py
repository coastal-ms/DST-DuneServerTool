import importlib.util
import io
import json
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('storage',Path(__file__).resolve().parents[2]/'app/tools/VmStorage/storage.py');storage=importlib.util.module_from_spec(spec);spec.loader.exec_module(storage)
G=1024**3;E=4*1024**2


class Guest:
    def __init__(self):
        self.disk=151*G;self.start=206848;self.sectors=(100*G)//512-self.start-34
        self.pv=((self.sectors*512-1024**2)//E)*E;self.free=16;self.lv=self.pv-self.free*E;self.fs=self.lv
        self.calls=[];self.failure='';self.external_free=0;self.fstype='ext4';self.pv_count=1;self.lv_segments=1
    def run(self,args,**kwargs):
        self.calls.append(args)
        if args[0]=='findmnt':return json.dumps({'filesystems':[{'source':'/dev/vg0/root','fstype':self.fstype,'target':'/'}]}).encode()
        if args[0]=='lsblk':
            assert '--tree' in args, 'Parent relationships require an explicit lsblk tree'
            return json.dumps({'blockdevices':[{'path':'/dev/sda','type':'disk','size':self.disk,'children':[{'path':'/dev/sda2','type':'part','size':self.sectors*512}]}]}).encode()
        if args[0]=='sfdisk':
            if '--dump' in args:return b'label: gpt\n/dev/sda2 : start=206848\n'
            return json.dumps({'partitiontable':{'label':'gpt','id':'disk-uuid','sectorsize':512,'partitions':[{'node':'/dev/sda2','start':self.start,'size':self.sectors}]}}).encode()
        if args[0]=='dumpe2fs':return f'Block count: {self.fs//4096}\nBlock size: 4096\n'.encode()
        if args[:2]==['lvm','lvs']:return json.dumps({'report':[{'lv':[{'lv_path':'/dev/vg0/root','lv_size':str(self.lv),'vg_name':'vg0','lv_uuid':'lv-uuid','segtype':'linear','lv_attr':'-wi-ao----'}]*self.lv_segments}]}).encode()
        if args[:2]==['lvm','pvs']:return json.dumps({'report':[{'pv':[{'pv_name':'/dev/sda2','pv_size':str(self.pv),'pv_free':str(self.free*E),'vg_name':'vg0','pv_uuid':'pv-uuid'}]*self.pv_count}]}).encode()
        if args[:2]==['lvm','vgs']:return json.dumps({'report':[{'vg':[{'vg_name':'vg0','vg_extent_size':str(E),'vg_free_count':str(self.free),'vg_uuid':'vg-uuid'}]}]}).encode()
        if args[:2]==['lvm','vgcfgbackup']:
            Path(args[3]).write_bytes(b'original LVM configuration');return b''
        if args[0]=='growpart':self.sectors=self.disk//512-self.start-34;return b''
        if args[:2]==['lvm','pvresize']:
            target=((self.sectors*512-1024**2)//E)*E;self.free+=(target-self.pv)//E;self.pv=target;self.free+=self.external_free;return b''
        if args[:2]==['lvm','lvextend']:
            if self.failure=='lvextend':raise ValueError('injected LV failure')
            extents=int(args[3].lstrip('+'));self.lv+=extents*E;self.free-=extents;return b''
        if args[0]=='resize2fs':
            if self.failure=='resize2fs':raise ValueError('injected filesystem failure')
            self.fs=self.lv;return b''
        raise AssertionError(args)
    def mutations(self):return [c for c in self.calls if c[0] in ('growpart','resize2fs') or c[:2] in (['lvm','pvresize'],['lvm','lvextend'])]


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.guest=Guest();self.original_open=open
        self.patches=[patch.object(storage,'STATE',self.root/'state'),patch.object(storage,'run',side_effect=self.guest.run),patch.object(storage.shutil,'which',return_value='/qualified/tool')]
        for p in self.patches:p.start();self.addCleanup(p.stop)
        image=bytearray(100*512);image[512:520]=b'EFI PART';struct.pack_into('<Q',image,512+32,99)
        def disk_open(path,*args,**kwargs):return io.BytesIO(image) if path=='/dev/sda' else self.original_open(path,*args,**kwargs)
        p=patch('builtins.open',side_effect=disk_open);p.start();self.addCleanup(p.stop)
    def prepare(self):return storage.prepare(storage.inspect()['revision'])
    def test_inspection_is_read_only_and_hash_ignores_free_filesystem_use(self):
        plan=storage.inspect();self.assertTrue(plan['canGrow']);self.assertEqual(plan['baselineFreeExtents'],16);self.assertFalse(self.guest.mutations())
        self.assertEqual(plan['revision'],storage.inspect()['revision']);self.assertFalse(storage.STATE.exists())
    def test_multiple_linear_segments_of_the_same_root_lv_are_supported(self):
        self.guest.lv_segments=2
        self.assertTrue(storage.inspect()['supported'])
        record=self.prepare();storage.apply(record['id'],record['metadataSha256'])
        self.assertEqual(self.guest.free,16)
    def test_full_expansion_preserves_start_and_preexisting_vg_free_space(self):
        before=self.guest.start;record=self.prepare()
        with tarfile.open(record['metadataPath']) as tar:self.assertEqual(set(tar.getnames()),{'partition-table.sfdisk','lvm.conf','primary-gpt.bin','original-backup-gpt.bin','plan.json'})
        result=storage.apply(record['id'],record['metadataSha256'])
        self.assertEqual(result['phase'],'completed');self.assertEqual(self.guest.start,before);self.assertEqual(self.guest.free,16)
        self.assertGreater(self.guest.fs,150*G);self.assertFalse(storage.inspect()['canGrow'])
        self.assertFalse(any('+100%FREE' in c for c in self.guest.calls))
    def test_stale_preview_or_bad_metadata_cannot_reach_a_mutation(self):
        plan=storage.inspect();self.guest.disk+=G
        with self.assertRaisesRegex(ValueError,'preview changed'):storage.prepare(plan['revision'])
        record=self.prepare()
        with self.assertRaisesRegex(ValueError,'metadata was not verified'):storage.apply(record['id'],'0'*64)
        self.assertFalse(self.guest.mutations())
    def test_lv_failure_is_journaled_and_explicit_recovery_preserves_reserved_extents(self):
        record=self.prepare();self.guest.failure='lvextend'
        with self.assertRaisesRegex(ValueError,'injected'):storage.apply(record['id'],record['metadataSha256'])
        self.assertEqual(storage.read_latest()['phase'],'failed');self.assertTrue(Path(record['metadataPath']).exists())
        self.guest.failure='';preview=storage.inspect();self.assertEqual(preview['recoveryOf'],record['id'])
        next_record=storage.prepare(preview['revision']);storage.apply(next_record['id'],next_record['metadataSha256']);self.assertEqual(self.guest.free,16)
    def test_filesystem_failure_can_finish_remaining_stage_without_allocating_reserved_space(self):
        record=self.prepare();self.guest.failure='resize2fs'
        with self.assertRaises(ValueError):storage.apply(record['id'],record['metadataSha256'])
        lv_size=self.guest.lv;self.guest.failure='';record=self.prepare();storage.apply(record['id'],record['metadataSha256'])
        self.assertEqual(self.guest.lv,lv_size);self.assertEqual(self.guest.free,16);self.assertEqual(self.guest.fs,lv_size)
    def test_unexpected_free_extents_are_not_consumed(self):
        record=self.prepare();self.guest.external_free=10
        with self.assertRaisesRegex(ValueError,'Unexpected free extents'):storage.apply(record['id'],record['metadataSha256'])
        self.assertFalse(any(c[:2]==['lvm','lvextend'] for c in self.guest.calls))
    def test_unsupported_layouts_and_missing_tools_have_no_device_writes(self):
        self.guest.fstype='xfs'
        self.assertIn('ext4',storage.inspect()['reason']);self.assertTrue(storage.inspect()['toolsReady'])
        self.guest.fstype='ext4';self.guest.pv_count=2
        self.assertIn('exactly one',storage.inspect()['reason'])
        with patch.object(storage.shutil,'which',return_value=None):self.assertFalse(storage.inspect()['supported'])
        self.assertFalse(self.guest.mutations())


if __name__=='__main__':unittest.main()
