"""Managed INI editing primitives and restricted SSH command dispatch."""
import datetime
import fcntl
import secrets
import sys

WRITE_FILE = "Engine.ini"


def ini_candidate(raw, value, target_section, target_key):
    if not isinstance(value, str) or len(value) > 2048 or any(c in value for c in '\r\n\0'):
        raise ValueError("Unsupported setting value")
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")
    lines = text.splitlines(keepends=True)
    newline = "\r\n" if "\r\n" in text else "\n"
    section, section_index, matches = "", None, []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1].strip()
            if section.casefold() == target_section.casefold():
                if section_index is not None:
                    raise ValueError("Duplicate settings sections; nothing changed")
                section_index = index
        elif section.casefold() == target_section.casefold() and not stripped.startswith((";", "#")) and "=" in stripped:
            if stripped.split("=", 1)[0].strip().casefold() == target_key.casefold():
                matches.append(index)
    if len(matches) > 1:
        raise ValueError("Duplicate settings keys; nothing changed")
    if matches:
        index = matches[0]
        original = lines[index]
        prefix = original.split("=", 1)[0] + "="
        suffix = "\r\n" if original.endswith("\r\n") else "\n" if original.endswith("\n") else ""
        lines[index] = prefix + value + suffix
    elif section_index is not None:
        if not lines[section_index].endswith("\n"):
            lines[section_index] += newline
        lines.insert(section_index + 1, target_key + "=" + value + newline)
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += newline
        lines += ["[" + target_section + "]" + newline, target_key + "=" + value + newline]
    return (b"\xef\xbb\xbf" if bom else b"") + "".join(lines).encode("utf-8")


def checked_path(report):
    if report.get("game_processes"):
        raise ValueError("Close Dune before changing settings")
    candidates = report.get("settings_candidates", [])
    if len(candidates) != 1 or report.get("errors"):
        raise ValueError("A single error-free Deck settings location is required")
    saved = Path(candidates[0]["saved_root"])
    path = saved / "Config/Windows" / WRITE_FILE
    # Discovery chooses the installation; a request can never supply a target path.
    for item in [path, *path.parents]:
        if item.is_symlink():
            raise ValueError("A settings path is a symbolic link")
    if not path.parent.is_dir():
        raise ValueError("Deck configuration folder does not exist")
    return path


def original_bytes(path):
    if not path.exists():
        return None
    if not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise ValueError("Unsupported settings file")
    return path.read_bytes()


def digest(raw):
    return hashlib.sha256(raw).hexdigest() if raw is not None else None


def reader_dispatch():
    try:
        original = os.environ.get("SSH_ORIGINAL_COMMAND", "")
        if not os.environ.get('SSH_CONNECTION') and '--launch-mods' in sys.argv:
            launch_mods()
            return
        if original in {"dst-settings-v1", "dst-mods-v1"}:
            payload = sys.stdin.buffer.read(262145)
            if len(payload) > 262144:
                raise ValueError("Request too large")
            handler = {'dst-settings-v1': handle_batch, 'dst-mods-v1': handle_mods}[original]
            result = handler(json.loads(payload))
        else:
            result = discover()
            result["settings_write_capabilities"] = ["managed-ini-v1"]
            result['mod_capabilities'] = ['mods-sync-v1', 'isolated-launch-v1']
            result['mod_environment'] = mod_environment(result)
        print(json.dumps(result))
    except Exception as exc:
        if not os.environ.get('SSH_CONNECTION') and '--launch-mods' in sys.argv:
            subprocess.run(['kdialog', '--title', 'DST Load with Mods', '--error', str(exc)], check=False)
        print(json.dumps({"ok": False, "error": str(exc)}))
        raise SystemExit(1)
