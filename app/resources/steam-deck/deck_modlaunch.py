"""Local native launcher: isolated loader files, existing Dune Proton prefix."""
import signal


def wine_path(path):
    return 'Z:' + str(path).replace('/', '\\')


def choose_proton(report):
    environment = mod_environment(report)
    candidates = environment['selected_tools']
    if len(candidates) == 1:
        return Path(candidates[0])
    if len(environment['tools']) == 1:
        return Path(environment['tools'][0]['path'])
    raise ValueError('The active Dune Proton tool could not be determined. No game or Steam configuration was changed.')


def runtime_command(proton, report):
    manifest = proton.parent / 'toolmanifest.vdf'
    text = manifest.read_text() if manifest.is_file() else ''
    match = re.search(r'"require_tool_appid"\s+"(\d+)"', text)
    if not match:
        raise ValueError('This Proton tool does not identify its required Steam runtime')
    for library in report['libraries']:
        root = Path(library) / 'steamapps'
        app = root / ('appmanifest_' + match.group(1) + '.acf')
        if app.is_file():
            folder = re.search(r'"installdir"\s+"([^"\r\n]+)"', app.read_text())
            if folder:
                common = (root / 'common').resolve()
                runtime = (common / folder.group(1)).resolve()
                if not runtime.is_relative_to(common):
                    raise ValueError('Invalid Steam runtime directory')
                entry = runtime / '_v2-entry-point'
                if entry.is_file():
                    return [str(entry), '--verb=waitforexitandrun', '--']
    raise ValueError('The Steam Linux Runtime required by Dune is not installed')


def shadow_install(game, destination):
    original_bin = game / 'DuneSandbox/Binaries/Win64'
    exe_name = 'DuneSandbox-Win64-Shipping.exe'
    original_exe = original_bin / exe_name
    if not original_exe.is_file():
        raise ValueError('Dune retail executable not found')
    if (original_bin / 'dwmapi.dll').exists() or (original_bin / 'UE4SS.dll').exists():
        raise ValueError('The normal Dune folder already has a loader installed; it was preserved')
    shadow = destination / 'Game'
    ensure_owned_tree(shadow)
    if shadow.exists():
        raise ValueError('Launch folder already exists; use the recorded launch installation')
    if shutil.disk_usage(destination).free < original_exe.stat().st_size + 128 * 1024 * 1024:
        raise ValueError('Not enough space for the isolated mod launch executable')
    bin_path = shadow / 'DuneSandbox/Binaries/Win64'
    bin_path.mkdir(parents=True)
    # Keep loader DLLs out of the Steam installation. All content is read through
    # directory links; only the game executable is copied into this launch tree.
    for parent_relative, special in (('', 'DuneSandbox'), ('DuneSandbox', 'Binaries'), ('DuneSandbox/Binaries', 'Win64')):
        for source in (game / parent_relative).iterdir():
            if source.name == special:
                continue
            target = shadow / parent_relative / source.name
            target.symlink_to(source, target_is_directory=source.is_dir())
    for source in original_bin.iterdir():
        if source.name in {'dwmapi.dll', 'UE4SS.dll', 'ue4ss', 'override.txt', exe_name}:
            continue
        (bin_path / source.name).symlink_to(source, target_is_directory=source.is_dir())
    shutil.copy2(original_exe, bin_path / exe_name)
    return bin_path / exe_name


def prepare_mod_launch(report, state, root):
    if report['game_processes']:
        raise ValueError('Dune is already running; close it before using the modded shortcut')
    if len(report['installations']) != 1 or len(report['prefixes']) != 1:
        raise ValueError('Exactly one Dune installation and Proton prefix are required')
    package = Path(state['root'])
    if package.parent != root or not re.fullmatch(r'Mods-[a-f0-9]{24}-[a-f0-9]{8}', package.name):
        raise ValueError('Invalid installed mod package')
    ensure_owned_tree(package)
    manifest = json.loads((package / 'manifest.json').read_text())
    for relative, expected in manifest['files'].items():
        source = package / relative
        if not source.is_file():
            raise ValueError('Installed mod file is missing: ' + relative)
        # Mod settings may legitimately change locally. Runtime integrity is fixed.
        if relative.startswith('runtime/') and digest(source.read_bytes()) != expected:
            raise ValueError('Mod runtime changed; sync a fresh copy before launching')
    proton = choose_proton(report)
    runtime = runtime_command(proton, report)
    game = Path(report['installations'][0]['path'])
    session = root / ('Launch-' + secrets.token_hex(8))
    session.mkdir(mode=0o700)
    exe = shadow_install(game, session)
    bin_path = exe.parent
    shutil.copy2(package / 'runtime/dwmapi.dll', bin_path / 'dwmapi.dll')
    shutil.copytree(package / 'runtime/ue4ss', bin_path / 'ue4ss')
    shutil.copy2(package / 'runtime/ue4ss/UE4SS.dll', bin_path / 'UE4SS.dll')
    # Use one persistent per-package mod tree, with identical PC enablement/order.
    mods_root = package / 'Mods'
    mods_txt = session / 'mods.txt'
    mods_txt.write_text('\n'.join(folder + ' : 1' for folder in state['enabled']) + '\n', encoding='utf-8')
    ini = bin_path / 'ue4ss/UE4SS-settings.ini'
    text = ini.read_text(encoding='utf-8-sig')
    text = re.sub(r'(?m)^ModsFolderPath\s*=.*$', 'ModsFolderPath = ' + wine_path(mods_root).replace('\\', '\\\\'), text)
    text = re.sub(r'(?m)^ControllingModsTxt\s*=.*$', 'ControllingModsTxt = ' + wine_path(mods_txt).replace('\\', '\\\\'), text)
    ini.write_text(text, encoding='utf-8')
    (mods_root / 'mods.txt').write_bytes(mods_txt.read_bytes())
    state_dir = package / 'State'
    state_dir.mkdir(exist_ok=True)
    (state_dir / 'active-mods.txt').write_bytes(mods_txt.read_bytes())
    tank = mods_root / 'dst-regis-tanks/Scripts'
    if tank.is_dir():
        (tank / 'dst-launch-platform.txt').write_text('steam', encoding='utf-8')
        (tank / 'dst-command-root.txt').write_text(wine_path(session), encoding='utf-8')
    environment = dict(os.environ)
    client = next((p.resolve() for p in (Path.home() / '.local/share/Steam', Path.home() / '.steam/steam') if p.is_dir()), None)
    if client is None:
        raise ValueError('Steam client installation was not found')
    environment.update({'STEAM_COMPAT_DATA_PATH': str(Path(report['prefixes'][0]).parent),
        'STEAM_COMPAT_CLIENT_INSTALL_PATH': str(client),
        'SteamAppId': APP_ID, 'STEAM_COMPAT_APP_ID': APP_ID,
        'WINEDLLOVERRIDES': 'dwmapi=n,b', 'PROTON_LOG': '0', 'WINEDEBUG': '-all',
        'PROTON_LOG_DIR': str(session)})
    # Gaming Mode tracks the non-Steam shortcut's identity. Retain it for the
    # game window/overlay/input while SteamAppId identifies Dune to SteamAPI.
    if not environment.get('SteamGameId'):
        environment['SteamGameId'] = APP_ID
    args = state.get('launchOptions', [])
    if not isinstance(args, list) or any(not isinstance(arg, str) or '\0' in arg for arg in args):
        raise ValueError('Invalid saved Solo launch arguments')
    command = runtime + [str(proton), 'waitforexitandrun', str(exe)] + args
    return command, environment, session, bin_path


def launch_mods():
    root = mod_home()
    ensure_owned_tree(root)
    state = json.loads((root / 'mods-current.json').read_text())
    with (root / 'mod-launch.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        command, environment, session, cwd = prepare_mod_launch(discover(), state, root)
        journal = {'root': str(session), 'state': 'starting', 'launcher_version': 2,
                   'steam_game_id': environment.get('SteamGameId'), 'steam_app_id': environment.get('SteamAppId')}
        (root / 'last-mod-launch.json').write_text(json.dumps(journal))
        with (session / 'launch.log').open('wb') as log:
            process = subprocess.Popen(command, env=environment, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
            def terminate(signum, frame):
                process.terminate()
            signal.signal(signal.SIGTERM, terminate)
            code = process.wait()
        (root / 'last-mod-launch.json').write_text(json.dumps({**journal, 'state': 'exited', 'exit_code': code}))
        if code:
            raise RuntimeError('The modded launch exited with code ' + str(code) + '. Logs are in ' + str(session))
