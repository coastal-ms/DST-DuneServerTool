"""Loopback-only Solo companion. No VM, game memory, or game-save writes."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs
import argparse
import hmac
import hashlib
import json
import math
import os
import re
import secrets
import sqlite3
import zlib
import threading
import time
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

import atlas_assets
import vehicle_fuel

KINDS = {'spice', 'ore', 'crash', 'storm', 'vehicle', 'worm'}
TRAIL_SECONDS = 600


def spice_size(item):
    name = item.get('class', '').lower()
    return item.get('size') or ('large' if 'spicefield_large' in name else 'medium' if 'spicefield_medium' in name else 'small')


def reference_sites():
    reference = json.loads((ROOT / 'reference-sites.json').read_text(encoding='utf-8'))
    result = []
    for index, poi in enumerate(reference['pois']):
        if poi['type'] in ('large-spice-field', 'titanium', 'stravidium'):
            continue
        sector = poi['sector']
        x = (int(sector[1:]) - 1 + (poi['subx'] - .5) / 4) / 9
        y = ('IHGFEDCBA'.index(sector[0]) + (poi['suby'] + .5) / 4) / 9
        large = poi['type'] == 'large-spice-field'
        result.append({'id': f'reference:{index}', 'kind': 'spice' if large else 'wreck' if poi['type']=='wreck' else 'reference', 'referenceType': poi['type'],
                       'size': 'large' if large else None, 'class': 'SpiceField_Large' if large else poi['type'],
                       'source': 'solo-reference', 'sector': sector, 'name': poi.get('name'),
                       'location': {'x': -1270000 + x * 2438400, 'y': -1270000 + y * 2438400, 'z': 0}})
    return result


def ore_reference_areas():
    areas = json.loads((ROOT / 'ore-reference-areas.json').read_text(encoding='utf-8'))
    result = []
    for poi in areas['areas']:
        x = (int(poi['sector'][1:]) - 1 + (poi['subx'] - .5) / 4) / 9
        y = ('IHGFEDCBA'.index(poi['sector'][0]) + (poi['suby'] + .5) / 4) / 9
        result.append({'id': 'ore-area:' + poi['type'] + ':' + poi['sector'], 'kind': 'ore-area',
                       'oreType': poi['type'], 'sector': poi['sector'], 'source': 'seed-reference',
                       'location': {'x': -1270000 + x * 2438400, 'y': -1270000 + y * 2438400, 'z': 0}})
    return result


def with_reference_sites(items, scanned_areas=()):
    # Only permanent sites come from the existing Solo map. Every size of
    # spice field must originate in the current active-field capture.
    dynamic = [i for i in items if i.get('source') not in ('solo-reference', 'seed-reference') and i.get('kind') not in ('wreck', 'reference')]
    return dynamic + reference_sites() + [a for a in ore_reference_areas() if a['id'] not in scanned_areas]


def visible_state(state, status):
    cutoff = time.time() - TRAIL_SECONDS
    tracks = [{**t, 'points': [p for p in t['points'] if p['at'] > cutoff]} for t in state.get('tracks', [])]
    return {**state, 'status': status, 'items': with_reference_sites(state.get('items', []), state.get('scannedOreAreas', [])),
            'tracks': [t for t in tracks if len(t['points']) > 1]}


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=True), encoding='utf-8')
    temporary.replace(path)


def prepare_native_build():
    """Provide the required mod a build fingerprint before game launch.

    Only the mod reads the verified native encounter field. The companion
    never opens game memory or starts an observer outside the required mod.
    """
    fingerprint = ''
    try:
        settings = json.loads((ROOT.parents[2] / 'ModLoader/settings.json').read_text(encoding='utf-8-sig'))
        if settings.get('platform', 'steam') == 'steam':
            executable = Path(settings['gamePath']) / 'DuneSandbox/Binaries/Win64/DuneSandbox-Win64-Shipping.exe'
            digest = hashlib.sha256()
            with executable.open('rb') as stream:
                while block := stream.read(1_048_576):
                    digest.update(block)
            fingerprint = digest.hexdigest().upper()
    except (OSError, ValueError, KeyError):
        pass
    # This is mod-owned launch metadata, never a game or save file.
    (ROOT.parent / 'Scripts/dst-native-build.txt').write_text(fingerprint, encoding='ascii')


def position(value):
    return (isinstance(value, dict) and all(
        type(value.get(k)) in (int, float) and math.isfinite(value[k])
        and abs(value[k]) < 100_000_000 for k in ('x', 'y')))


class MapState:
    def __init__(self, data, launch):
        self.data, self.launch = data, launch
        self.lock = threading.Lock()
        self.fuel_stamp = None
        self.fuel_rows = []
        self.saved = self.read(data / 'snapshot.json') or {'items': [], 'tracks': []}
        catalog = self.read(data / 'ore-survey.json')
        if catalog:
            saved_ore = catalog.get('items', [])
            self.saved['items'] = [i for i in self.saved.get('items', []) if i.get('kind') != 'ore'] + saved_ore
            self.saved['scannedOreAreas'] = catalog.get('scannedOreAreas', [])
        self.saved['status'] = 'Capture paused' if self.saved.get('capturedAt') else 'Waiting for Deep Desert'

    @staticmethod
    def read(path):
        try:
            if path.stat().st_size > 16_000_000:
                return None
            result = json.loads(path.read_text(encoding='utf-8'))
            return result if isinstance(result, dict) else None
        except (OSError, ValueError):
            return None

    def snapshot(self):
        with self.lock:
            frame = self.read(self.data / 'runtime.json')
            previous = self.saved
            if (not frame or frame.get('launchId') != self.launch
                    or not str(frame.get('world', '')).lower().startswith('deepdesert')
                    or type(frame.get('capturedAt')) not in (int, float)
                    or not math.isfinite(frame['capturedAt'])
                    or frame['capturedAt'] > time.time() + 5
                    or time.time() - frame['capturedAt'] > 10):
                return visible_state(previous, 'Capture paused' if previous.get('capturedAt') else 'Waiting for Deep Desert')
            if previous.get('launchId') == self.launch and previous.get('capturedAt', 0) >= frame['capturedAt']:
                return visible_state(previous, 'Live')
            items = []
            source = frame.get('items', [])
            if not isinstance(source, list):
                source = []
            for item in source[:30000]:
                if not isinstance(item, dict) or item.get('kind') not in KINDS or not position(item.get('location')):
                    continue
                kind, loc = item['kind'], item['location']
                if kind == 'ore' and item.get('source') != 'instance':
                    continue
                if kind == 'vehicle' and (item.get('worldPlaced') is not True or all(loc.get(k, 0) == 0 for k in ('x', 'y', 'z'))):
                    continue
                fields = item.get('fields') or {}
                if kind == 'spice' and ('flour' in item.get('class', '').lower() or fields.get('m_bIsActiveOnServer') is not True):
                    continue
                items.append(item)
            save = vehicle_fuel.selected_save(self.data)
            if save:
                try:
                    stamp = (str(save), save.stat().st_mtime_ns, save.stat().st_size)
                    if stamp != self.fuel_stamp:
                        self.fuel_rows = vehicle_fuel.read_vehicles(save)
                        self.fuel_stamp = stamp
                    vehicle_fuel.enrich(items, self.fuel_rows)
                except (OSError, ValueError, sqlite3.Error, zlib.error):
                    self.fuel_rows = []
            # Streaming out is not evidence of depletion. Keep the last world
            # position for ore within one launch, never attach it to the pawn.
            known = {}
            same_launch = previous.get('launchId') == self.launch
            def ore_key(item):
                return (item.get('oreType'), *(round(item['location'].get(k, 0), 2) for k in ('x', 'y', 'z')))
            known = {ore_key(i): {**i, 'currentlyObserved': False} for i in previous.get('items', []) if i.get('kind') == 'ore'}
            if same_launch:
                sources = frame.get('oreSources', {})
                if isinstance(sources, dict):
                    known = {key: item for key, item in known.items()
                             if item.get('observedLaunch', self.launch) != self.launch or sources.get(item.get('oreSource')) not in ('complete', 'excluded')}
            for item in items:
                if item['kind'] == 'ore':
                    known[ore_key(item)] = {**item, 'currentlyObserved': True, 'lastSeen': frame['capturedAt'], 'observedLaunch': self.launch}
            scanned_areas = set(previous.get('scannedOreAreas', []))
            for area in ore_reference_areas():
                nearby = [i for i in known.values() if i.get('oreType') == area['oreType'] and
                          math.hypot(i['location']['x'] - area['location']['x'], i['location']['y'] - area['location']['y']) <= 100000]
                # A dense observed deposit replaces its approximate reference,
                # not a single loose pickup encountered in the same sector.
                if len(nearby) >= 20:
                    scanned_areas.add(area['id'])
            atomic_json(self.data / 'ore-survey.json', {'schema': 1, 'items': list(known.values()),
                                                       'scannedOreAreas': sorted(scanned_areas)})
            tracks = {t['id']: t for t in previous.get('tracks', [])} if same_launch else {}
            for item in items:
                if item['kind'] not in ('vehicle', 'storm'):
                    continue
                identity = item['kind'] + ':' + str(item.get('id'))
                track = tracks.setdefault(identity, {'id': identity, 'kind': item['kind'], 'points': []})
                point = {**item['location'], 'at': frame['capturedAt']}
                points = [p for p in track['points'] if frame['capturedAt'] - p['at'] <= TRAIL_SECONDS]
                if not points or math.hypot(point['x'] - points[-1]['x'], point['y'] - points[-1]['y']) >= 100:
                    points.append(point)
                track['points'] = [p for p in points if frame['capturedAt'] - p['at'] <= TRAIL_SECONDS][-600:]
            tracks = [t for t in tracks.values() if t['points'] and frame['capturedAt'] - t['points'][-1]['at'] <= TRAIL_SECONDS]
            # Treasure searches need the last observed storm pass after it ends.
            # Keep one completed pass per save, independent of short travel trails.
            passes = {p['key']: p for p in previous.get('stormPasses', [])}
            if not passes:
                for track in previous.get('tracks', []):
                    if track.get('kind') == 'storm' and track.get('points'):
                        key = str(previous.get('launchId')) + ':' + str(track['id']).removeprefix('storm:')
                        passes[key] = {'key': key, 'points': track['points'],
                                       'profile': {}, 'lastSeen': track['points'][-1]['at']}
            active_keys = set()
            for storm in (i for i in items if i['kind'] == 'storm'):
                key = self.launch + ':' + str(storm['id'])
                active_keys.add(key)
                history = passes.setdefault(key, {'key': key, 'points': [], 'profile': storm})
                history.pop('completedAt', None)
                if not history['profile'].get('zones') and storm.get('zones'):
                    history['profile'] = storm
                point = {**storm['location'], 'at': frame['capturedAt']}
                if not history['points'] or math.hypot(point['x'] - history['points'][-1]['x'], point['y'] - history['points'][-1]['y']) >= 100:
                    history['points'].append(point)
                history['points'] = history['points'][-2000:]
                history['lastSeen'] = frame['capturedAt']
            for key, history in passes.items():
                if key not in active_keys and 'completedAt' not in history:
                    history['completedAt'] = frame['capturedAt']
            completed = sorted((p for p in passes.values() if 'completedAt' in p), key=lambda p: p['lastSeen'])[-1:]
            storm_passes = completed + [p for key, p in passes.items() if key in active_keys]
            self.saved = {'status': 'Live', 'launchId': self.launch, 'capturedAt': frame['capturedAt'],
                          'items': [i for i in items if i['kind'] != 'ore'] + list(known.values()), 'tracks': tracks,
                          'stormPasses': storm_passes, 'scannedOreAreas': sorted(scanned_areas)}
            atomic_json(self.data / 'snapshot.json', self.saved)
            return visible_state(self.saved, 'Live')


def terrain_path(preferred, assets):
    # Solo's permanent Deep Desert uses layout 11. Keep an existing override.
    if preferred.is_file():
        return preferred
    return atlas_assets.icon_path('dd-layout-11.webp', assets, ROOT / 'icons')


def serve(args):
    args.data.mkdir(parents=True, exist_ok=True)
    prepare_native_build()
    state = MapState(args.data, args.launch)
    key = secrets.token_urlsafe(32)
    port = 0
    previous = MapState.read(args.data / 'ready.json')
    if previous:
        prior_url = urlparse(str(previous.get('url', '')))
        prior_key = parse_qs(prior_url.query).get('key', [''])[0]
        if (prior_url.scheme == 'http' and prior_url.hostname == '127.0.0.1'
                and prior_url.path == '/' and not prior_url.username and not prior_url.fragment
                and re.fullmatch(r'[A-Za-z0-9_-]{24,128}', prior_key)):
            try:
                port = prior_url.port or 0
                key = prior_key
            except ValueError:
                pass
    icon_body = json.dumps(atlas_assets.marker_icons(args.assets, ROOT / 'icons')).encode()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            url = urlparse(self.path)
            supplied = parse_qs(url.query).get('key', [''])[0]
            if self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}' or not hmac.compare_digest(supplied, key):
                self.send_error(403)
                return
            if url.path == '/':
                body, mime = (ROOT / 'index.html').read_bytes(), 'text/html; charset=utf-8'
            elif url.path == '/state':
                body, mime = json.dumps(state.snapshot()).encode(), 'application/json'
            elif url.path == '/health':
                body, mime = json.dumps({'launchId': args.launch, 'pid': os.getpid()}).encode(), 'application/json'
            elif url.path == '/icons':
                body, mime = icon_body, 'application/json'
            elif url.path == '/terrain.webp':
                terrain = terrain_path(args.terrain, args.assets)
                if terrain is None:
                    self.send_error(404)
                    return
                body, mime = terrain.read_bytes(), 'image/webp'
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    atomic_json(args.data / 'ready.json', {'pid': os.getpid(), 'launchId': args.launch,
                'url': f'http://127.0.0.1:{server.server_port}/?key={key}'})
    server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--launch', required=True)
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--terrain', type=Path, required=True)
    parser.add_argument('--save', type=Path)
    serve(parser.parse_args())
