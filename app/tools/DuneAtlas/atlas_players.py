"""Viewer-driven player observations. No process scans, timers or game writes."""
from pathlib import Path
import base64, datetime, importlib.util, json, math, os, re, struct
import atlas_builds
import atlas_process

PLAYER = '_ZTV20ADunePlayerCharacter'
MAX_ACTORS = 100000
MAX_PLAYERS = 128
MAX_DEPTH = 16
u64 = lambda b, o=0: struct.unpack_from('<Q', b, o)[0]


def roster(snapshot, region, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    try:
        age = (now - datetime.datetime.fromisoformat(snapshot['observedAt'])).total_seconds()
        if not 0 <= age < 30: return None
        if not isinstance(snapshot.get('players'),list): return None
        rows = [p for p in snapshot['players'] if p['map'] == region and int(p['dimension']) == 0]
        if len(rows) > MAX_PLAYERS: return None
        result = []
        for row in rows:
            entity = str(int(row['entityId']))
            if entity == '0' or any(p['entityId'] == entity for p in result): return None
            result.append({'entityId': entity, 'name': str(row.get('name') or 'Player')[:100]})
        return sorted(result, key=lambda p: p['entityId'])
    except (KeyError, TypeError, ValueError): return None


def requested_regions(selections):
    return {p['region'] for p in selections if p and 'players' in p.get('layers', [])}


def viewer_preferences(preferences, allowed):
    if preferences is None or allowed: return preferences
    if not isinstance(preferences,dict) or not isinstance(preferences.get('layers'),list):return preferences
    return {**preferences, 'layers': [v for v in preferences.get('layers', []) if v != 'players']}


def public_state(value, allowed):
    # Counts already shared in server health remain numbers. Position/name
    # arrays are removed even from nested native/checkpoint snapshots.
    if allowed:return value
    if isinstance(value, dict):
        result = {k: public_state(v, allowed) for k, v in value.items()
                  if allowed or k != 'players' or not isinstance(v, (list, dict))}
        return result
    if isinstance(value, list): return [public_state(v, allowed) for v in value]
    return value


def valid_actor(head, vtable, entity):
    return (len(head) >= 576 and u64(head) == vtable and
            not struct.unpack_from('<I', head, 8)[0] & 0x18030 and
            str(struct.unpack_from('<q', head, 200)[0]) == str(entity) and
            0x10000 < u64(head, 568) < 0x800000000000)


def component(raw):
    p, r, s = [struct.unpack_from('<3d', raw, off) for off in (456, 480, 504)]
    if not all(math.isfinite(v) and abs(v) < 1e8 for values in (p, r, s) for v in values):
        raise ValueError('Invalid player transform')
    return {'parent': u64(raw, 336), 'p': p, 'r': r, 's': s, 'absolute': raw[552]}



def load_cache(folder, context):
    try:
        path = Path(folder) / 'player-actors.json'
        if path.stat().st_size > 1048576: return {}
        value = json.loads(path.read_text())
        if (value['pid'],str(value['startTime']),value['sha256']) != (context['pid'],str(context['startTime']),context['sha256']): return {}
        if not isinstance(value['players'],list) or len(value['players']) > MAX_PLAYERS: return {}
        if any(not 1<=len(p['chain'])<=MAX_DEPTH for p in value['players']): return {}
        return value
    except (OSError, ValueError, KeyError, TypeError): return {}


def requests(cache, wanted):
    ids = {p['entityId'] for p in wanted}; result = {}
    for p in cache.get('players', []):
        if p['entityId'] not in ids: continue
        result[(p['actor'],576)] = None
        result[(p['root'],560)] = None
    return list(result)


def decode(memory, cache, wanted):
    items = []; invalid = False; observed = set()
    wanted = {p['entityId']: p for p in wanted}
    for p in cache.get('players', []):
        if p['entityId'] not in wanted: continue
        try:
            head = memory.cache[(p['actor'],576)]
            if not valid_actor(head, p['vtable'], p['entityId']) or u64(head,568) != p['root']: raise ValueError('Player pawn changed')
            root = component(memory.cache[(p['root'],560)])
            observed.add(p['entityId'])
            # Attached roots are vehicle/seat-relative, so do not draw a player
            # dot over the vehicle. Leaving the seat restores world coordinates
            # in this same root: the next normal batch can display them directly.
            if root['parent']: continue
            items.append({**wanted[p['entityId']], 'location': root['p']})
        except (KeyError, ValueError, TypeError, struct.error): invalid = True
    return items, invalid or len(observed) != len(wanted)


def lookup_command(pid, start, vtable):
    # Enumerate the engine's bounded actor list, not writable process regions.
    # Keep vector expansion on the guest: only a few input bytes and matching
    # addresses cross SSH. All addresses fit exactly within awk's 53-bit integer
    # precision; database IDs and names never enter the shell command.
    first = '{for(i=1;i<=NF;i++){v=$i+0;if(phase==0){phase=1;continue}if(phase==1){left=v/8;phase=2;continue}if(v>65536&&v<140737488355328){x=v;for(j=0;j<8;j++){printf "%c",x%256;x=int(x/256)}printf "%c%c%c%c%c%c%c%c",8,0,0,0,0,0,0,0}left--;if(left==0)phase=0}}'
    last = '{for(i=1;i<=NF;i++){if(phase==0){a=$i;phase=1}else if(phase==1){phase=2}else{if(($i+0)=='+str(int(vtable))+')printf "%.0f\\n",a;phase=0}}}'
    reader = f'sudo nice -n 19 /var/lib/dst-atlas/readers/bulk /proc/{int(pid)}/mem'
    return (f'export LC_ALL=C\ntest "$(cut -d " " -f22 /proc/{int(pid)}/stat)" = "{int(start)}" || exit 73\n'
            f"set -o pipefail; base64 -d | {reader} | od -An -tu8 -v | awk '{first}' | {reader} | od -An -tu8 -v | awk '{last}'\n")


def discover(memory, native, wanted, root):
    root = Path(root); context = memory.context
    if not wanted:return {'pid':context['pid'],'startTime':context['startTime'],'sha256':context['sha256'],'players':[]}
    profile = atlas_builds.profile(root,context['sha256'])
    vtable = context['exeBase'] + profile['symbols'][PLAYER] + 16
    previous = load_cache(root,context)
    candidates = [p['actor'] for p in previous.get('players', [])]
    try: heads = memory.read_many([(p,576) for p in candidates])
    except (OSError,ValueError,RuntimeError): candidates,heads = [],[]
    found = {p['entityId']: {'actor':a,'root':u64(h,568),'vtable':vtable,'entityId':p['entityId']}
             for a,h in zip(candidates,heads) for p in wanted if valid_actor(h,vtable,p['entityId'])}
    if set(found) != {p['entityId'] for p in wanted}:
        system = next(p for p in native['systems'] if p['name'] == 'SandwormSubsystem')
        world = u64(memory.read_many([(system['address'],64)])[0],32)
        world_head = memory.read_many([(world,64)])[0]
        if u64(world_head) != context['exeBase']+profile['symbols']['_ZTV6UWorld']+16: raise ValueError('Player world identity changed')
        level = u64(memory.read_many([(world+48,8)])[0])
        ptr,num,cap = struct.unpack('<Qii',memory.read_many([(level+152,16)])[0])
        if not 0 <= num <= cap <= MAX_ACTORS: raise ValueError('Player actor list exceeds bound')
        if num:
            req = [(ptr+off,min(131072,num*8-off)) for off in range(0,num*8,131072)]
            prefix = root / ('player-lookup-'+str(os.getpid()))
            command,source,output = [prefix.with_suffix(s) for s in ('.cmd','.b64','.txt')]
            try:
                command.write_text(lookup_command(context['pid'],context['startTime'],vtable))
                source.write_text(base64.b64encode(b''.join(struct.pack('<2Q',a,n) for a,n in req)).decode())
                result = atlas_process.run(['pwsh','-NoProfile','-File',str(root/'remote.ps1'),'-CommandFile',str(command),'-InputFile',str(source),'-OutputFile',str(output)],capture_output=True,text=True,timeout=20)
                if result.returncode: raise ValueError('Player discovery unavailable')
                candidates = [int(v) for v in output.read_text().split()]
                if len(candidates) > MAX_PLAYERS: raise ValueError('Player discovery exceeds bound')
            finally:
                for p in (command,source,output): p.unlink(missing_ok=True)
            heads = memory.read_many([(p,576) for p in candidates])
            found = {}
            for actor,head in zip(candidates,heads):
                for p in wanted:
                    if valid_actor(head,vtable,p['entityId']):
                        if p['entityId'] in found: raise ValueError('Ambiguous player entity')
                        found[p['entityId']] = {'actor':actor,'root':u64(head,568),'vtable':vtable,'entityId':p['entityId']}
    for p in found.values():
        value = component(memory.read_many([(p['root'],560)])[0])
        p['chain'] = [{'address':p['root'],'parent':value['parent']}]
    return {'pid':context['pid'],'startTime':context['startTime'],'sha256':context['sha256'],'players':list(found.values())}


if __name__ == '__main__':
    root = Path(os.environ.get('DST_ATLAS_WORLD_ROOT',str(Path(__file__).parent)))
    native = json.loads((root/'native-snapshot-current.json').read_text())
    wanted = json.loads((root/'player-roster.json').read_text())
    spec = importlib.util.spec_from_file_location('player_memory',root/'inspect-reflection.py')
    memory = importlib.util.module_from_spec(spec);spec.loader.exec_module(memory)
    if (native['pid'],str(native['startTime'])) != (memory.context['pid'],str(memory.context['startTime'])): raise ValueError('Player process changed')
    value = discover(memory,native,wanted,root)
    path = root/'player-actors.json';temp=path.with_suffix('.'+str(os.getpid())+'.tmp');temp.write_text(json.dumps(value));temp.replace(path)
