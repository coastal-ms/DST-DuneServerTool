"""Stock SteamOS discovery shared by the companion and restricted SSH reader."""
import hashlib
import json
import os
from pathlib import Path
import re
import time

APP_ID = "1172710"
SETTINGS_SCHEMA = {}  # injected from existing DST setting definitions


def settings_snapshot(saved, schema=None):
    schema = SETTINGS_SCHEMA if schema is None else schema
    result = []
    # Read only known files and sections. Graphics/user preferences are excluded.
    for filename, sections in schema.items():
        if filename not in {"Game.ini", "Engine.ini", "ServerCustomSettings.ini"}:
            raise ValueError("Unsupported settings filename")
        path = saved / "Config/Windows" / filename
        entry = {"file": filename, "path": str(path), "exists": path.is_file(), "values": [], "duplicates": []}
        if path.is_file():
            before = path.stat()
            if before.st_size > 1024 * 1024:
                raise ValueError("Settings file exceeds discovery limit")
            raw = path.read_bytes()
            after = path.stat()
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise ValueError("Settings file changed during discovery")
            entry["sha256"] = hashlib.sha256(raw).hexdigest()
            text = raw.decode("utf-8-sig")
            current, seen = "", set()
            for line in text.splitlines():
                stripped = line.strip()
                if stripped.startswith("[") and stripped.endswith("]"):
                    current = stripped[1:-1].strip()
                elif current in sections and stripped and not stripped.startswith((";", "#")) and "=" in stripped:
                    key, value = stripped.split("=", 1)
                    key = key.strip()
                    if key in sections[current]:
                        identity = (current, key)
                        if identity in seen:
                            entry["duplicates"].append({"section": current, "key": key})
                        seen.add(identity)
                        entry["values"].append({"section": current, "key": key, "value": value.strip()})
        result.append(entry)
    return result


def release_info(text):
    values = {}
    for line in text.splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            values[key] = value.strip('"')
    if values.get("ID") != "steamos" or values.get("VARIANT_ID") != "steamdeck":
        raise RuntimeError("This prototype supports stock SteamOS on Steam Deck only.")
    return {k: values.get(k, "") for k in ("ID", "VARIANT_ID", "VERSION_ID", "BUILD_ID", "STEAMOS_DEFAULT_UPDATE_BRANCH")}


def metadata(path):
    # Report paths and fingerprints, never the save or INI contents.
    before = path.stat()
    result = {"path": str(path), "bytes": before.st_size, "modified_ns": before.st_mtime_ns}
    if before.st_size <= 64 * 1024 * 1024:
        with path.open("rb") as stream:
            digest = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        after = path.stat()
        result["stable"] = (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns)
        if result["stable"]:
            result["sha256"] = digest.hexdigest()
    return result


def libraries(home):
    roots = set()
    for candidate in (home / ".local/share/Steam", home / ".steam/steam", home / ".steam/root"):
        if candidate.is_dir():
            roots.add(candidate.resolve())
    for root in list(roots):
        manifest = root / "steamapps/libraryfolders.vdf"
        if manifest.is_file():
            text = manifest.read_text(encoding="utf-8", errors="replace")
            for match in re.finditer(r'"path"\s+"([^"\r\n]+)"', text):
                candidate = Path(match.group(1))
                if candidate.is_absolute() and (candidate / "steamapps").is_dir():
                    roots.add(candidate.resolve())
    return sorted(roots)


def discover(home=None, os_path=None):
    home = home or Path.home()
    os_path = os_path or Path("/etc/os-release")
    report = {"protocol": 1, "mode": "read-only", "os": release_info(os_path.read_text()),
              "libraries": [], "installations": [], "prefixes": [], "saves": [], "ini_files": [], "settings_candidates": [], "errors": []}
    seen_saves, seen_ini = set(), set()
    for root in libraries(home):
        report["libraries"].append(str(root))
        manifest = root / ("steamapps/appmanifest_" + APP_ID + ".acf")
        if manifest.is_file():
            text = manifest.read_text(encoding="utf-8", errors="replace")
            match = re.search(r'"installdir"\s+"([^"\r\n]+)"', text)
            build = re.search(r'"buildid"\s+"([^"\r\n]+)"', text)
            if match:
                common = (root / "steamapps/common").resolve()
                install = (common / match.group(1)).resolve()
                if install.is_relative_to(common):
                    report["installations"].append({"path": str(install), "exists": install.is_dir(),
                                                    "build_id": build.group(1) if build else ""})
        prefix = root / "steamapps/compatdata" / APP_ID / "pfx"
        if not prefix.is_dir():
            continue
        report["prefixes"].append(str(prefix.resolve()))
        for saved in prefix.glob("drive_c/users/*/AppData/Local/DuneSandbox/Saved"):
            try:
                report["settings_candidates"].append({"saved_root": str(saved.resolve()), "files": settings_snapshot(saved)})
            except (OSError, ValueError, UnicodeError) as exc:
                report["errors"].append("Settings read: " + str(exc))
            for db in saved.glob("Cloud/PlayerClientStorage/FLS_retail/*/game.db"):
                resolved = db.resolve()
                if str(resolved) not in seen_saves:
                    seen_saves.add(str(resolved))
                    try:
                        report["saves"].append(metadata(resolved))
                    except OSError as exc:
                        report["errors"].append(str(exc))
            config = saved / "Config"
            if config.is_dir():
                for ini in config.rglob("*.ini"):
                    if ini.name not in {"Game.ini", "Engine.ini", "ServerCustomSettings.ini", "GameUserSettings.ini"}:
                        continue
                    resolved = ini.resolve()
                    if str(resolved) not in seen_ini:
                        seen_ini.add(str(resolved))
                        try:
                            report["ini_files"].append(metadata(resolved))
                        except OSError as exc:
                            report["errors"].append(str(exc))
    report["game_processes"] = []
    proc = Path("/proc")
    if proc.is_dir():
        for entry in proc.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                args = (entry / "cmdline").read_bytes().split(b"\0")
                executable = args[0].decode(errors="replace").replace("\\", "/").rsplit("/", 1)[-1]
                if executable.lower() in {"dunesandbox.exe", "dunesandbox-win64-shipping.exe", "dunesandbox_be.exe"}:
                    report["game_processes"].append({"pid": int(entry.name), "name": executable})
            except OSError:
                pass
    return report
