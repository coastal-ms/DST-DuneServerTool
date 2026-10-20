"""Automatic map layout discovery uses actual ELF metadata, not release hashes."""
import importlib.util
from pathlib import Path
import struct
import unittest
import tempfile

ROOT = Path(__file__).resolve().parents[2] / 'app/tools/DuneAtlas'
spec = importlib.util.spec_from_file_location('atlas_elf', ROOT / 'atlas_elf.py')
elf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elf)


class ElfDiscoveryTests(unittest.TestCase):
    def test_completed_executable_reads_survive_a_later_interruption(self):
        with tempfile.TemporaryDirectory() as folder:
            calls = []
            def fetch(offset, length):
                calls.append(offset)
                if offset == 20:
                    raise TimeoutError('interrupted')
                return bytes([offset]) * length
            self.assertEqual(elf.cached_elf_read(folder, 4, 8, fetch), bytes([4])*8)
            with self.assertRaises(TimeoutError):
                elf.cached_elf_read(folder, 20, 8, fetch)
            self.assertEqual(elf.cached_elf_read(folder, 4, 8, fetch), bytes([4])*8)
            self.assertEqual(calls, [4, 20])

    def test_symbols_follow_the_executable_tables_when_addresses_move(self):
        names = ('_ZTV13ASandwormPawn', '_ZTV14ASandStormBase', '_ZTV20AResourceNodeSpawner')
        strings = bytearray(b'\0')
        table = bytearray()
        for i, name in enumerate(names):
            offset = len(strings)
            strings.extend(name.encode() + b'\0')
            table.extend(struct.pack('<IBBHQQ', offset, 17, 0, 1, 987654+i*4096, 8))
        sections = [(0, 11, 0, 0, 1024, len(table), 1, 0, 8, 24),
                    (0, 3, 0, 0, 2048, len(strings), 0, 0, 1, 0)]
        def read(offset, length):
            return bytes(table if offset == 1024 else strings)
        result = elf.symbols(read, sections)
        self.assertEqual(result[names[2]], 987654+8192)

    def test_name_pool_is_located_from_live_memory_without_known_offset(self):
        base, global_offset, block_address = 0x100000, 0x4000, 0x900000
        block = bytearray(4096)
        # Current block 0, used cursor 120; pointer table starts at offset 616.
        struct.pack_into('<IIQQ', block, 608, 0, 120, block_address, 0)
        def read(requests):
            return [bytes(block) if address == base+global_offset else b'\x00\x01None\x00\x03ByteProperty'+bytes(12)
                    for address, _ in requests]
        program = [(1, 6, 0, global_offset, 0, 0, len(block), 4096)]
        self.assertEqual(elf.name_pool(base, program, '900000-920000 rw-p ', read), global_offset+616)

    def test_missing_pool_is_an_observation_failure(self):
        with self.assertRaisesRegex(ValueError, 'resolve'):
            elf.name_pool(0x100000, [(1, 6, 0, 0, 0, 0, 4096, 4096)],
                          '900000-920000 rw-p ', lambda requests: [bytes(4096)])

    def test_missing_symbols_and_non_elf_are_reported(self):
        with self.assertRaisesRegex(ValueError, 'missing map symbols'):
            elf.symbols(lambda *_: b'', [])
        with self.assertRaisesRegex(ValueError, 'ELF executable'):
            elf.elf_layout(lambda *_: bytes(64))


if __name__ == '__main__':
    unittest.main()
