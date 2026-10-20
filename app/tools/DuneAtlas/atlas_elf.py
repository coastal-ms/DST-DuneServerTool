"""Read the running ELF's symbols and locate its live FName pool; no build list."""
import base64
import re
import struct
from pathlib import Path
import os


def cached_elf_read(folder, offset, length, fetch):
    """Resume immutable executable reads after an interrupted cold discovery."""
    if folder is None:
        return fetch(offset, length)
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f'{offset}-{length}.bin'
    if path.is_file():
        data = path.read_bytes()
        if len(data) == length:
            return data
    data = fetch(offset, length)
    if len(data) != length:
        raise ValueError('Incomplete ELF read')
    temp = path.with_name(path.name + '.' + str(os.getpid()) + '.tmp')
    temp.write_bytes(data)
    temp.replace(path)
    return data


def elf_layout(read):
    head = read(0, 64)
    if head[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', head, 18)[0] != 62:
        raise ValueError('Server is not an x86-64 ELF executable')
    phoff, shoff = struct.unpack_from('<QQ', head, 32)
    phsize, phnum, shsize, shnum = struct.unpack_from('<HHHH', head, 54)
    if phsize != 56 or shsize != 64 or not 0 < phnum <= 128 or not 0 < shnum <= 4096:
        raise ValueError('Invalid ELF tables')
    program = [struct.unpack_from('<IIQQQQQQ', read(phoff, phsize*phnum), i*phsize) for i in range(phnum)]
    sections = [struct.unpack_from('<IIQQQQIIQQ', read(shoff, shsize*shnum), i*shsize) for i in range(shnum)]
    return program, sections


def symbols(read, sections):
    result = {}
    for section in sections:
        if section[1] != 11:  # SHT_DYNSYM, linked to its own string table.
            continue
        if section[9] != 24 or section[5] > 16777216 or section[6] >= len(sections):
            raise ValueError('Invalid ELF symbol table')
        strings_section = sections[section[6]]
        if strings_section[5] > 33554432:
            raise ValueError('ELF string table is too large')
        table = read(section[4], section[5])
        strings = read(strings_section[4], strings_section[5])
        for pos in range(0, len(table)-23, 24):
            name, _, _, _, value, _ = struct.unpack_from('<IBBHQQ', table, pos)
            if not value or name >= len(strings) or strings[name:name+4] != b'_ZTV':
                continue
            end = strings.find(b'\0', name)
            if end < 0 or end-name > 4096:
                continue
            result[strings[name:end].decode('ascii')] = value
    for required in ('_ZTV13ASandwormPawn', '_ZTV14ASandStormBase', '_ZTV20AResourceNodeSpawner'):
        if required not in result:
            raise ValueError('Server ELF is missing map symbols: ' + required)
    return result


def name_pool(base, program, maps, read_memory):
    ranges = []
    for line in maps.splitlines():
        match = re.match(r'([0-9a-f]+)-([0-9a-f]+) rw.p ', line)
        if match:
            ranges.append(tuple(int(v, 16) for v in match.groups()))
    def pointer(value):
        return value % 8 == 0 and any(a <= value and value+32 <= b for a, b in ranges)
    candidates = []
    for kind, flags, _, address, _, _, size, _ in program:
        if kind != 1 or not flags & 2:
            continue
        if size > 67108864:
            raise ValueError('Server global data is too large to inspect')
        block = read_memory([(base+address, size)])[0]
        for pos in range(0, len(block)-32, 8):
            current, cursor = struct.unpack_from('<II', block, pos+8)
            if not 0 <= current < 8192 or not 16 <= cursor <= 131072:
                continue
            end = pos+16+(current+2)*8
            if end > len(block):
                continue
            first = struct.unpack_from('<Q', block, pos+16)[0]
            last, after = struct.unpack_from('<QQ', block, pos+16+current*8)
            if after == 0 and pointer(first) and pointer(last):
                candidates.append((base+address+pos+16, first))
    if not candidates or len(candidates) > 1024:
        raise ValueError('Could not resolve the server name pool')
    heads = read_memory([(first, 32) for _, first in candidates])
    matches = [address for (address, _), head in zip(candidates, heads)
               if len(head) >= 6 and struct.unpack_from('<H', head)[0] >> 6 == 4
               and not head[0] & 1 and head[2:6] == b'None' and b'ByteProperty' in head]
    if len(matches) != 1:
        raise ValueError('Server name pool could not be identified uniquely')
    return matches[0]-base


def inspect(digest, pid, started, base, maps, remote, cache_dir=None):
    pid, started, base = int(pid), int(started), int(base)
    if pid <= 0 or started <= 0 or not re.fullmatch('[0-9a-f]{64}', digest):
        raise ValueError('Missing running server identity')
    guard = f'test "$(cut -d " " -f22 /proc/{pid}/stat)" = "{started}" || exit 73\n'
    def fetch_file(offset, length):
        if offset < 0 or not 0 < length <= 33554432 or offset+length > 2147483648:
            raise ValueError('Invalid ELF read range')
        skip, within = divmod(offset, 65536)
        count = (within+length+65535)//65536
        raw = remote(guard+f'set -o pipefail; sudo dd if=/proc/{pid}/exe bs=65536 skip={skip} count={count} 2>/dev/null | base64', 'elf-read.b64')
        data = base64.b64decode(raw)[within:within+length]
        if len(data) != length:
            raise ValueError('Incomplete ELF read')
        return data
    folder = Path(cache_dir) / ('elf-' + digest) if cache_dir is not None else None
    def read_file(offset, length):
        return cached_elf_read(folder, offset, length, fetch_file)
    def read_memory(requests):
        result = [bytearray() for _ in requests]
        pending = [(index, address+i, min(131072, length-i))
                   for index, (address, length) in enumerate(requests)
                   for i in range(0, length, 131072)]
        while pending:
            batch = []
            size = 0
            while pending and len(batch) < 512 and size+pending[0][2] <= 1048576:
                item = pending.pop(0)
                batch.append(item)
                size += item[2]
            encoded = base64.b64encode(b''.join(struct.pack('<QQ', address, length) for _, address, length in batch)).decode()
            raw = remote(guard+f'set -o pipefail; printf %s {encoded} | base64 -d | sudo nice -n 19 /var/lib/dst-atlas/readers/bulk /proc/{pid}/mem | base64', 'elf-memory.b64')
            data = base64.b64decode(raw)
            cursor = 0
            for index, address, length in batch:
                if cursor+16 > len(data) or struct.unpack_from('<QQ', data, cursor) != (address, length):
                    raise ValueError('Unexpected name-pool read')
                cursor += 16
                result[index].extend(data[cursor:cursor+length])
                cursor += length
            if cursor != len(data):
                raise ValueError('Incomplete name-pool read')
        if any(len(data) != request[1] for data, request in zip(result, requests)):
            raise ValueError('Incomplete name-pool read')
        return [bytes(data) for data in result]
    program, sections = elf_layout(read_file)
    return {'sha256': digest, 'symbols': symbols(read_file, sections),
            'namePoolTableOffset': name_pool(base, program, maps, read_memory),
            'discoveredFrom': 'running-elf-and-name-pool'}
