"""Deck mod deployment is confined to the companion's own data directory."""
import io
import shutil
import stat
import subprocess
import tempfile
import urllib.parse
import urllib.request
import ssl
import zipfile


def mod_home():
    return Path.home() / '.local/share/dst-deck-companion'


def ensure_owned_tree(path):
    for parent in [path, *path.parents]:
        if parent.is_symlink():
            raise ValueError('Companion data path is a symbolic link')


def mod_environment(report):
    tools = []
    for library in report['libraries']:
        for proton in (Path(library) / 'steamapps/common').glob('*/proton'):
            if proton.is_file():
                tools.append({'path': str(proton.resolve()), 'name': proton.parent.name})
    selected = []
    for prefix in report['prefixes']:
        info = Path(prefix).parent / 'config_info'
        if info.is_file() and info.stat().st_size < 65536:
            text = info.read_text(errors='replace')
            for tool in tools:
                if str(Path(tool['path']).parent) in text:
                    selected.append(tool['path'])
    state_file = mod_home() / 'mods-current.json'
    state = json.loads(state_file.read_text()) if state_file.is_file() else None
    launch_file = mod_home() / 'last-mod-launch.json'
    last_launch = json.loads(launch_file.read_text()) if launch_file.is_file() else None
    logs = {}
    if last_launch:
        session = Path(last_launch['root'])
        if session.parent == mod_home() and re.fullmatch(r'Launch-[a-f0-9]{16}', session.name):
            for relative in ('launch.log', 'Game/DuneSandbox/Binaries/Win64/ue4ss/UE4SS.log', 'steam-1172710.log'):
                log = session / relative
                if log.is_file() and not log.is_symlink():
                    with log.open('rb') as stream:
                        stream.seek(max(0, log.stat().st_size - 16384))
                        logs[relative] = stream.read(16384).decode(errors='replace')
    return {'tools': tools, 'selected_tools': sorted(set(selected)), 'installed': state,
            'launcher': str(Path.home() / 'Downloads/DST-Load-With-Mods.sh'),
            'last_launch': last_launch, 'logs': logs, 'launcher_version': 2}


def validate_mod_archive(raw):
    archive = zipfile.ZipFile(io.BytesIO(raw))
    seen, total = set(), 0
    manifest = None
    for item in archive.infolist():
        name = item.filename
        parts = name.split('/')
        total += item.file_size
        if (len(seen) > 20000 or total > 1024 * 1024 * 1024 or name.startswith('/') or
            '\\' in name or ':' in name or any(p in {'', '.', '..'} for p in parts) or
            name.casefold() in seen or stat.S_ISLNK(item.external_attr >> 16) or
            parts[0] not in {'runtime', 'Mods', 'manifest.json'} or item.is_dir()):
            raise ValueError('Unsafe or oversized mod bundle')
        seen.add(name.casefold())
        if name == 'manifest.json':
            if item.file_size > 262144:
                raise ValueError('Mod manifest too large')
            manifest = json.loads(archive.read(item))
    if not manifest or manifest.get('protocol') != 1:
        raise ValueError('Unsupported mod manifest')
    hashes = manifest.get('files', {})
    if set(hashes) != {n.filename for n in archive.infolist()} - {'manifest.json'}:
        raise ValueError('Bundle manifest does not cover every file')
    for name, expected in hashes.items():
        if digest(archive.read(name)) != expected:
            raise ValueError('Mod file checksum mismatch')
    order = manifest.get('enabled', [])
    if not isinstance(order, list) or not order or len(order) != len(set(order)):
        raise ValueError('No enabled mods or duplicate load-order entries')
    for folder in order:
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_. -]{0,100}', folder):
            raise ValueError('Invalid mod folder')
        if not any(name in hashes for name in ('Mods/' + folder + '/Scripts/main.lua', 'Mods/' + folder + '/dlls/main.dll')):
            raise ValueError('Enabled mod entry point is missing')
    for required in ('runtime/dwmapi.dll', 'runtime/ue4ss/UE4SS.dll', 'runtime/ue4ss/UE4SS-settings.ini'):
        if required not in hashes:
            raise ValueError('Mod framework is incomplete')
    return archive, manifest


def download_mod_bundle(request):
    if set(request) != {'action', 'url', 'sha256'}:
        raise ValueError('Unsupported mod request')
    url = urllib.parse.urlsplit(request['url'])
    # Only download from the PC that already authenticated this SSH session.
    peer = os.environ.get('SSH_CONNECTION', '').split(' ')[0]
    if not peer:
        pairing = json.loads((mod_home() / 'pairing.json').read_text())
        peer = pairing['pc']
    if (url.scheme != 'https' or url.hostname != peer or url.port != 18749 or
        url.path != '/mods' or url.query or url.fragment or url.username or url.password):
        raise ValueError('Mod source must be the paired DST PC')
    if not re.fullmatch(r'[a-f0-9]{64}', str(request['sha256'])):
        raise ValueError('Invalid bundle fingerprint')
    # Disable environment proxies and redirects: the authenticated source cannot change.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            raise ValueError('Mod bundle redirects are unsupported')
    pairing = json.loads((mod_home() / 'pairing.json').read_text())
    if pairing['pc'] != peer:
        raise ValueError('Saved certificate does not belong to this PC')
    context = ssl.create_default_context(cadata=pairing['certificate_pem'])
    context.check_hostname = False
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), urllib.request.HTTPSHandler(context=context))
    download = urllib.request.Request(request['url'], headers={'Authorization': 'Bearer ' + pairing['sync_code']})
    with opener.open(download, timeout=30) as response:
        raw = response.read(128 * 1024 * 1024 + 1)
    if len(raw) > 128 * 1024 * 1024 or digest(raw) != request['sha256']:
        raise ValueError('Downloaded mod bundle did not match its fingerprint')
    return raw


def install_mod_bundle(raw, report, root=None):
    if report['game_processes']:
        raise ValueError('Close Dune before syncing mods')
    if len(report['installations']) != 1 or not report['installations'][0]['exists']:
        raise ValueError('Exactly one installed retail Dune is required')
    archive, manifest = validate_mod_archive(raw)
    root = mod_home() if root is None else root
    ensure_owned_tree(root)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    generation = root / ('Mods-' + digest(raw)[:24] + '-' + secrets.token_hex(4))
    state_path = root / 'mods-current.json'
    previous = json.loads(state_path.read_text()) if state_path.is_file() else None
    downloads = Path.home() / 'Downloads'
    ensure_owned_tree(downloads)
    launcher = downloads / 'DST-Load-With-Mods.sh'
    ensure_owned_tree(launcher)
    script = '#!/bin/sh\nexec /usr/bin/python3 "$HOME/.local/share/dst-deck-companion/reader.py" --launch-mods\n'
    if launcher.exists() and launcher.read_text() != script:
        raise ValueError('A different launcher already exists in Downloads; it was preserved')
    with tempfile.TemporaryDirectory(prefix='mods-stage-', dir=root) as temporary:
        stage = Path(temporary) / 'package'
        stage.mkdir(mode=0o700)
        for entry in archive.infolist():
            target = stage / entry.filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(entry))
        stage.rename(generation)
    state = {'protocol': 1, 'root': str(generation), 'bundle_sha256': digest(raw),
             'enabled': manifest['enabled'], 'runtimeVersion': manifest.get('runtimeVersion'),
             'previous': previous, 'launchOptions': manifest.get('launchOptions', [])}
    # Preserve the prior complete generation, including its user configuration.
    temp = root / ('mods-current-' + secrets.token_hex(8) + '.tmp')
    temp.write_text(json.dumps(state, indent=2))
    temp.replace(state_path)
    downloads.mkdir(exist_ok=True)
    launcher.write_text(script)
    launcher.chmod(0o755)
    return {'ok': True, 'enabled': state['enabled'], 'runtimeVersion': state['runtimeVersion'],
            'root': str(generation), 'launcher': str(launcher), 'normalGameChanged': False}


def handle_mods(request):
    if request.get('action') != 'sync-mods':
        raise ValueError('Unsupported mod operation')
    report = discover()
    if report['game_processes']:
        raise ValueError('Close Dune before syncing mods')
    runtime_command(choose_proton(report), report)
    raw = download_mod_bundle(request)
    return install_mod_bundle(raw, discover())
