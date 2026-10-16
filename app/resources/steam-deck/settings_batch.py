"""Explicit managed overrides only, previewed hashes, recoverable multi-file apply."""
WRITE_SCHEMA = {}  # injected positive allowlist; no arbitrary settings or paths


def batch_plan(report, request):
    if set(request) - {'action', 'files', 'confirmed', 'cloud_confirmed'}:
        raise ValueError('Unsupported request field')
    engine = checked_path(report)
    files = request.get('files')
    if not isinstance(files, list) or not 1 <= len(files) <= 3:
        raise ValueError('Expected one to three settings files')
    planned, seen_files = [], set()
    for entry in files:
        if set(entry) != {'file', 'expected_sha256', 'values'}:
            raise ValueError('Unsupported file request')
        name = entry['file']
        if name not in WRITE_SCHEMA or name in seen_files:
            raise ValueError('Unsupported or duplicate settings file')
        seen_files.add(name)
        path = engine.parent / name
        if path.is_symlink():
            raise ValueError('Settings file is a symbolic link')
        raw = original_bytes(path)
        if digest(raw) != entry['expected_sha256']:
            raise ValueError('Deck settings changed since preview; refresh and confirm again')
        values = entry['values']
        if not isinstance(values, list) or not 1 <= len(values) <= 100:
            raise ValueError('Invalid settings list')
        candidate, seen_keys = raw or b'', set()
        for item in values:
            if set(item) != {'section', 'key', 'value'}:
                raise ValueError('Unsupported setting request')
            section, key, value = item['section'], item['key'], item['value']
            identity = (section, key)
            if key not in WRITE_SCHEMA[name].get(section, []) or identity in seen_keys:
                raise ValueError('Unsupported or duplicate setting')
            seen_keys.add(identity)
            candidate = ini_candidate(candidate, value, section, key)
        planned.append((path, raw, candidate))
    return planned


def atomic_settings_file(path, raw):
    temp = path.with_name('.dst-settings-' + secrets.token_hex(12))
    try:
        with temp.open('xb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        temp.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o600)
        temp.replace(path)
    finally:
        if temp.exists():
            temp.unlink()


def handle_batch(request, discover_fn=None, backup_root=None, replace_fn=None):
    discover_fn = discover if discover_fn is None else discover_fn
    replace_fn = atomic_settings_file if replace_fn is None else replace_fn
    if request.get('action') not in {'preview-settings', 'apply-settings'}:
        raise ValueError('Unsupported operation')
    planned = batch_plan(discover_fn(), request)
    results = [{'file': p.name, 'before_sha256': digest(raw), 'after_sha256': digest(new),
                'changed': raw != new} for p, raw, new in planned]
    result = {'applied': False, 'files': results}
    if request['action'] == 'preview-settings':
        return result
    if request.get('confirmed') is not True or request.get('cloud_confirmed') is not True:
        raise ValueError('Overwrite and Cloud preparation must be confirmed')
    root = backup_root or (Path.home() / '.local/share/dst-deck-companion/backups')
    for item in [root / 'settings.lock', root, *root.parents]:
        if item.is_symlink():
            raise ValueError('Backup path is a symbolic link')
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (root / 'settings.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if batch_plan(discover_fn(), request) != planned:
            raise ValueError('Settings changed before backup')
        changes = [(p, raw, new) for p, raw, new in planned if raw != new]
        if not changes:
            return result
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        backup = root / (stamp + '-' + secrets.token_hex(4))
        backup.mkdir(mode=0o700)
        for path, raw, new in changes:
            if raw is not None:
                with (backup / path.name).open('xb') as stream:
                    stream.write(raw)
                    stream.flush()
                    os.fsync(stream.fileno())
                (backup / path.name).chmod(0o600)
        manifest = {'files': [{**row, 'target': str(plan[0]), 'existed': plan[1] is not None}
                              for row, plan in zip(results, planned)]}
        with (backup / 'manifest.json').open('x', encoding='utf-8') as stream:
            json.dump(manifest, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        (backup / 'manifest.json').chmod(0o600)
        written = []
        try:
            for path, raw, new in changes:
                # Check all originals not written yet and game status before each replacement.
                current = discover_fn()
                if checked_path(current).parent != path.parent or original_bytes(path) != raw:
                    raise ValueError('Game or settings changed during transfer')
                written.append((path, raw, new))
                replace_fn(path, new)
                if path.read_bytes() != new:
                    raise RuntimeError('Settings readback mismatch')
        except Exception as exc:
            recovery = []
            for path, raw, new in reversed(written):
                try:
                    current = original_bytes(path)
                    if current == raw:
                        continue
                    if current != new:
                        raise RuntimeError('File changed externally; original retained in backup')
                    if raw is None:
                        path.unlink()
                    else:
                        atomic_settings_file(path, raw)
                except Exception as restore_error:
                    recovery.append(str(restore_error))
            raise RuntimeError(str(exc) + '; backup: ' + str(backup) +
                               ('; recovery needed: ' + '; '.join(recovery) if recovery else '; original settings restored')) from exc
        result.update(applied=True, backup=str(backup))
        return result
