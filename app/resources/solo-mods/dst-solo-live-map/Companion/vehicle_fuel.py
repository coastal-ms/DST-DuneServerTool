"""Read selected Solo saved fuel in memory. Never write or open the game DB in SQLite."""
from pathlib import Path
import hashlib
import json
import math
import os
import sqlite3
import zlib

ROOT = Path(__file__).resolve().parent


def selected_save(data_root):
    try:
        profile = json.loads((Path(os.environ['APPDATA']) / 'DuneServer/solo-mode.json').read_text(encoding='utf-8-sig'))
        path = Path(profile['dbPath']).resolve()
        identity = hashlib.sha256(str(path).lower().encode()).hexdigest()
        return path if identity == Path(data_root).name else None
    except (OSError, ValueError, KeyError):
        return None


def read_vehicles(path):
    before = path.stat()
    if before.st_size > 64_000_000:
        raise ValueError('Save too large')
    raw = path.read_bytes()
    if path.stat().st_mtime_ns != before.st_mtime_ns:
        raise ValueError('Save changed during read')
    if raw.startswith(b'SQLite format 3\0'):
        payload = raw
    elif raw[:4] == b'\x01\0\0\0':
        decoder = zlib.decompressobj()
        payload = decoder.decompress(raw[8:], 256_000_001)
        if len(payload) > 256_000_000 or not decoder.eof:
            raise ValueError('Unsupported save payload')
    else:
        raise ValueError('Unsupported save wrapper')
    connection = sqlite3.connect(':memory:')
    try:
        connection.deserialize(payload)
        connection.execute('PRAGMA query_only=ON')
        capacities = json.loads((ROOT / 'vehicle-fuel-capacities.json').read_text())
        rows = connection.execute("""SELECT a.id,a.class,a.location_x,a.location_y,a.location_z,
            json_extract(f.components,'$.FVehicleComponent[1].CurrentFuel')
            FROM actors a JOIN vehicles v ON v.id=a.id
            JOIN actor_fgl_entities af ON af.actor_id=a.id
            JOIN fgl_entities f ON f.entity_id=af.entity_id
            WHERE a.map='DeepDesert' AND a.dimension_index=0 AND a.state=0
            AND a.id NOT IN (SELECT vehicle_id FROM backup_vehicles)
            AND a.id NOT IN (SELECT vehicle_id FROM recovered_vehicles)
            AND json_type(f.components,'$.FVehicleComponent[1].CurrentFuel') IN ('integer','real')""").fetchall()
        result = []
        for identity, cls, x, y, z, fuel in rows:
            modules = connection.execute('SELECT template_id FROM vehicle_modules WHERE vehicle_id=?', (identity,)).fetchall()
            values = {capacities[m[0]] for m in modules if m[0] in capacities}
            if len(values) != 1:
                continue
            capacity = values.pop()
            if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in (x, y, z, fuel, capacity)) or not 0 <= fuel <= capacity * 1.001:
                continue
            result.append({'savedId': str(identity), 'class': cls, 'location': {'x': x, 'y': y, 'z': z},
                           'fuel': fuel, 'fuelCapacity': capacity, 'fuelSavedAt': before.st_mtime})
        return result
    finally:
        connection.close()


def enrich(items, saved):
    # Require a unique nearby match in both directions. Ambiguity shows no percentage.
    vehicles = [i for i in items if i.get('kind') == 'vehicle']
    def matches(live, stored):
        cls = live.get('class', '').removeprefix('BlueprintGeneratedClass ')
        return cls == stored['class'] and math.dist([live['location'].get(k, 0) for k in ('x', 'y', 'z')],
                                                   [stored['location'][k] for k in ('x', 'y', 'z')]) <= 25000
    for item in vehicles:
        candidates = [s for s in saved if matches(item, s)]
        if len(candidates) == 1 and sum(matches(v, candidates[0]) for v in vehicles) == 1:
            item.update({k: candidates[0][k] for k in ('savedId', 'fuel', 'fuelCapacity', 'fuelSavedAt')})
