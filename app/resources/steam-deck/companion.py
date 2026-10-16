"""Generic stock-SteamOS companion prototype; unpaired until the user pairs it."""
import base64
import datetime
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

READER_B64 = "__READER_B64__"


def dialog(*args):
    if shutil.which("kdialog"):
        command = ["kdialog", "--title", "DST Deck Companion", *args]
    elif shutil.which("zenity"):
        kind, values = args[0], list(args[1:])
        command = ["zenity", "--title=DST Deck Companion"]
        if kind == "--menu":
            command += ["--list", "--text=" + values[0], "--column=Action", "--column=ID", "--hide-column=2", "--print-column=2", "--width=650", "--height=350"]
            for index in range(1, len(values), 2):
                command += [values[index + 1], values[index]]
        elif kind == "--inputbox":
            command += ["--entry", "--text=" + values[0], "--entry-text=" + (values[1] if len(values) > 1 else "")]
        elif kind == "--textbox":
            command += ["--text-info", "--filename=" + values[0], "--width=850", "--height=600"]
        else:
            command += [{"--yesno": "--question", "--msgbox": "--info", "--error": "--error"}[kind], "--text=" + values[0], "--no-markup"]
    else:
        raise RuntimeError("Neither stock dialog tool (kdialog/zenity) is available")
    result = subprocess.run(command, capture_output=True, text=True)
    return result.returncode, result.stdout.strip()


def reader_source():
    return base64.b64decode(READER_B64, validate=True)


def paired_opener(pairing):
    context = ssl.create_default_context(cadata=pairing['certificate_pem'])
    context.check_hostname = False  # Identity is the explicitly verified certificate.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            raise ValueError('Pairing redirects are unsupported')
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), urllib.request.HTTPSHandler(context=context))


def verify_pairing_certificate(pc, port):
    # Retrieve only the certificate before authenticating. No pairing code or
    # user data is sent until the user compares its fingerprint with DST.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with socket.create_connection((pc, port), timeout=8) as connection:
        with context.wrap_socket(connection, server_hostname=pc) as stream:
            certificate = stream.getpeercert(binary_form=True)
    fingerprint = hashlib.sha256(certificate).hexdigest().upper()
    rc, _ = dialog('--yesno', 'Compare this connection fingerprint with the one shown in DST on your PC:\n\n' + fingerprint + '\n\nDo they match exactly? Cancel if they differ.')
    if rc:
        raise ValueError('Certificate comparison cancelled; no pairing code was sent')
    return ssl.DER_cert_to_PEM_cert(certificate)


def update_paired_reader(home):
    folder = home / '.local/share/dst-deck-companion'
    reader = folder / 'reader.py'
    pairing = folder / 'pairing.json'
    if not reader.is_file() or not pairing.is_file():
        return False
    for path in [reader, pairing, folder, *folder.parents]:
        if path.is_symlink():
            raise ValueError('Companion update path is a symbolic link')
    prior = reader.read_bytes()
    if b'def reader_dispatch():' not in prior or b'def discover(' not in prior:
        raise ValueError('Existing helper was not recognized; it was preserved')
    fresh = reader_source()
    compile(fresh, 'reader.py', 'exec')
    if prior == fresh:
        return False
    backup = folder / ('reader-before-update-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.py')
    backup.write_bytes(prior)
    backup.chmod(0o600)
    temporary = folder / ('reader-update-' + os.urandom(8).hex() + '.tmp')
    with temporary.open('xb') as stream:
        stream.write(fresh)
    temporary.chmod(0o600)
    temporary.replace(reader)
    return True


def discover():
    namespace = {"__name__": "dst_readonly_reader"}
    exec(compile(reader_source(), "reader.py", "exec"), namespace)
    return namespace["discover"]()


def sync_mods():
    folder = Path.home() / '.local/share/dst-deck-companion'
    pairing = json.loads((folder / 'pairing.json').read_text())
    base = 'https://' + pairing['pc'] + ':' + str(pairing['port'])
    request = urllib.request.Request(base + '/mods-info', headers={'Authorization': 'Bearer ' + pairing['sync_code']})
    try:
        with paired_opener(pairing).open(request, timeout=30) as response:
            info = json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            message = json.loads(exc.read(8192)).get('error', 'Check the mod selection in PC DST and close Dune before syncing.')
        except (ValueError, UnicodeError):
            message = 'Check the mod selection in PC DST and close Dune before syncing.'
        raise ValueError(message) from exc
    names = '\n'.join(mod['name'] for mod in info['mods'])
    rc, _ = dialog('--yesno', 'Sync enabled mods from DST to this Deck?\n\n' + names +
                   '\n\nThe PC selection and order will be used. The previous Deck mod package is retained. Close Dune before continuing.')
    if rc:
        return
    namespace = {'__name__': 'dst_mod_sync'}
    exec(compile(reader_source(), 'reader.py', 'exec'), namespace)
    result = namespace['handle_mods']({'action': 'sync-mods', 'url': base + '/mods', 'sha256': info['sha256']})
    dialog('--msgbox', 'Synced ' + str(len(result['enabled'])) + ' enabled mods.\n\nLoad with Mods App is in Downloads as DST-Load-With-Mods.sh. Add it to Steam as a non-Steam game. Leave Steam compatibility forcing off for this native launcher.\n\nYour normal Dune shortcut is unchanged.')


def status_text(report):
    lines = ["DST Deck Companion - settings transfer prototype", "",
             "SteamOS: " + report["os"].get("VERSION_ID", "unknown"),
             "Dune installations: " + str(len(report["installations"])),
             "Solo saves: " + str(len(report["saves"])),
             "INI files: " + str(len(report["ini_files"])),
             "Dune: " + ("running" if report["game_processes"] else "closed"), ""]
    for install in report["installations"]:
        lines += ["Dune: " + install["path"], "Build: " + install["build_id"], ""]
    for save in report["saves"]:
        lines += ["Save: " + save["path"], "Size: " + str(save["bytes"]) + " bytes", ""]
    lines += ["The paired PC can transfer approved managed settings and enabled mods.",
              "Make grants and save changes in PC DST. Steam Cloud carries those changes to the Deck."]
    return "\n".join(lines)


def install_reader(home, public_key, source, pc):
    # Only a public key is received. No account password or remote script is accepted.
    fields = public_key.strip().split()
    if len(public_key) > 1024 or not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]*)?', public_key.strip()):
        raise ValueError("Unsupported pairing key")
    decoded = base64.b64decode(fields[1], validate=True)
    if len(decoded) != 51 or not decoded.startswith(b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20'):
        raise ValueError('Invalid pairing public key')
    socket.inet_aton(pc)
    folder = home / ".local/share/dst-deck-companion"
    ssh = home / ".ssh"
    authorized = ssh / "authorized_keys"
    for p in (home / ".local", home / ".local/share", folder, ssh, authorized):
        if p.is_symlink():
            raise ValueError("A setup path is a symbolic link; pairing stopped.")
    reader = folder / "reader.py"
    if reader.is_symlink():
        raise ValueError("Reader path is a symbolic link")
    # shlex handles homes containing spaces; escape the authorized_keys command field.
    import shlex
    command = "/usr/bin/python3 " + shlex.quote(str(reader)) + " --diagnose"
    command = command.replace("\\", "\\\\").replace('"', '\\"')
    entry = ('from="' + pc + '",restrict,command="' + command + '" ' + public_key.strip()).encode()
    existing = authorized.read_bytes() if authorized.exists() else b""
    matching = [line for line in existing.splitlines() if fields[1].encode() in line.split()]
    replace_entry = bool(matching and matching != [entry])
    if replace_entry:
        marker = b' ssh-ed25519 ' + fields[1].encode()
        own_prefix = rb'from="[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+",restrict,command="' + re.escape(command.encode()) + rb'"'
        if len(matching) != 1 or marker not in matching[0] or not re.fullmatch(own_prefix, matching[0].split(marker, 1)[0]):
            raise ValueError("This key already has a different authorization; existing access was preserved.")
    folder.mkdir(parents=True, exist_ok=True)
    folder.chmod(0o700)
    temp = folder / ("reader-" + os.urandom(8).hex() + ".tmp")
    with temp.open("xb") as stream:
        stream.write(source)
    temp.chmod(0o600)
    temp.replace(reader)
    ssh.mkdir(mode=0o700, exist_ok=True)
    ssh.chmod(0o700)
    if not matching or replace_entry:
        if existing:
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            backup = ssh / ("authorized_keys.before-dst-" + stamp)
            with backup.open("xb") as stream:
                stream.write(existing)
            backup.chmod(0o600)
        if replace_entry:
            if authorized.read_bytes() != existing:
                raise ValueError('SSH access changed while pairing; retry without changing existing keys')
            updated = b''.join(entry + (b'\r\n' if line.endswith(b'\r\n') else b'\n') if line.rstrip(b'\r\n') == matching[0] else line for line in existing.splitlines(keepends=True))
            temporary = ssh / ('.authorized_keys.dst-' + os.urandom(8).hex())
            try:
                with temporary.open('xb') as stream:
                    stream.write(updated)
                temporary.chmod(0o600)
                if authorized.read_bytes() != existing:
                    raise ValueError('SSH access changed while pairing; retry')
                temporary.replace(authorized)
            finally:
                if temporary.exists():
                    temporary.unlink()
        else:
            with authorized.open("ab") as stream:
                if existing and not existing.endswith(b"\n"):
                    stream.write(b"\n")
                stream.write(entry + b"\n")
        authorized.chmod(0o600)
    return folder


def get_pairing_info(opener, base):
    while True:
        rc, code = dialog('--inputbox', 'Enter the temporary pairing code shown on that PC.', '')
        if rc:
            return None
        code = code.strip().upper()
        request = urllib.request.Request(base + '/ssh-info', headers={'Authorization': 'Bearer ' + code})
        try:
            with opener.open(request, timeout=8) as response:
                raw = response.read(16385)
        except urllib.error.HTTPError as exc:
            if exc.code != 403:
                raise
            exc.close()
            retry, _ = dialog('--yesno', "The pairing code expired or was not accepted.\n\nOn your PC, choose Refresh pairing code in DST (or Enable pairing if no code is shown). Then choose Yes here to enter the new code.\n\nNo game files have been changed. Try another code?")
            if retry:
                return None
            continue
        if len(raw) > 16384:
            raise ValueError('Pairing response too large')
        return code, json.loads(raw)


def pair():
    rc, address = dialog("--inputbox", "Enter the pairing address shown on your DST PC (IP:port).", "")
    if rc:
        return
    parsed = urllib.parse.urlsplit("http://" + address.strip())
    if not parsed.hostname or parsed.username or parsed.password or parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ValueError("Enter only the PC address and port")
    pc = socket.gethostbyname(parsed.hostname)
    import ipaddress
    if not ipaddress.ip_address(pc).is_private or ipaddress.ip_address(pc).is_loopback:
        raise ValueError("Use your DST PC local-network address")
    port = parsed.port or 18749
    base = "https://" + pc + ":" + str(port)
    certificate = verify_pairing_certificate(pc, port)
    opener = paired_opener({'certificate_pem': certificate})
    rc, _ = dialog("--yesno", "Before connecting:\n\nClose Dune on other devices and finish Steam Cloud sync.\nOpen Dune on this Deck, load the intended Solo save, exit fully and wait for Steam Cloud Up to date.\n\nHave you completed those steps?")
    if rc:
        return
    report = discover()
    if report["game_processes"]:
        raise ValueError("Dune is still running. Close it and finish Cloud sync first.")
    if len(report["saves"]) != 1 or not report["saves"][0].get("stable"):
        raise ValueError("This first prototype needs exactly one stable retail Solo save. Nothing changed.")
    accepted = get_pairing_info(opener, base)
    if accepted is None:
        return
    code, info = accepted
    public_key = info["public_key"]
    rc, _ = dialog("--yesno", "Pair this Deck with DST at " + address + "?\n\nThe companion will set up its own private connection for this PC. No password, account or system SSH settings are changed. You can close the companion after pairing; its connection runs under your Deck user.\n\nThe PC can transfer approved INI settings and enabled mods. Originals are retained. Save files are not edited. Pairing itself changes no game files.")
    if rc:
        return
    folder, connection = install_private_connection(Path.home(), public_key, reader_source(), pc)
    payload = {**connection, "report": report, "cloud_status_user_confirmed": True, "save_writes_enabled": False}
    request = urllib.request.Request(base + "/ssh-paired", data=json.dumps(payload).encode(),
                                     headers={"Authorization": "Bearer " + code.strip().upper(), "Content-Type": "application/json"})
    try:
        with opener.open(request, timeout=8) as response:
            result = json.load(response)
        if result.get("ok") is not True:
            raise ValueError("PC did not confirm pairing")
    except Exception as exc:
        if isinstance(exc, urllib.error.HTTPError) and exc.code == 403:
            exc.close()
            raise RuntimeError('The pairing code expired before the PC confirmed setup. On your PC, choose Refresh pairing code in DST, then choose Pair with a DST PC here again. The private connection files are retained; no game files were changed.') from exc
        raise RuntimeError("The private connection was installed, but PC confirmation failed. Retry pairing. " + str(exc)) from exc
    pairing_path = folder / 'pairing.json'
    if pairing_path.is_symlink():
        raise ValueError('Pairing file cannot be a symbolic link')
    pairing_path.write_text(json.dumps({'pc': pc, 'port': port, 'sync_code': result['client_token'], 'certificate_pem': certificate, 'mode': 'private-ssh'}, indent=2))
    pairing_path.chmod(0o600)
    dialog("--msgbox", "Paired with the DST PC.\n\nChoose Sync mods to copy the PC's enabled mods, or use the PC sync view. You can close this companion afterward.\n\nMake grants and save changes in PC DST, then finish Steam Cloud sync before playing on the Deck.")


def main():
    if not (shutil.which("kdialog") or shutil.which("zenity")):
        if shutil.which("notify-send"):
            subprocess.run(["notify-send", "DST Deck Companion", "Neither kdialog nor zenity is available. No packages were installed."])
        raise RuntimeError("The stock dialog components are unavailable. No packages were installed.")
    discover()  # Validates stock SteamOS before presenting setup.
    if update_paired_reader(Path.home()):
        dialog('--msgbox', 'The companion has been updated. Choose Pair with a DST PC to set up its private connection. No account passwords or system services are changed.')
    while True:
        rc, choice = dialog("--menu", "DST Deck Companion", "status", "View Dune and Solo status", "pair", "Pair with a DST PC", "sync-mods", "Sync mods from DST", "disconnect", "Stop the DST connection", "exit", "Exit")
        if rc or choice == "exit":
            return
        try:
            if choice == "pair":
                pair()
            elif choice == 'sync-mods':
                sync_mods()
            elif choice == 'disconnect':
                if dialog('--yesno', 'Stop the private DST connection? Your game, settings and mods will remain in place. Pair again when you want to reconnect.')[0] == 0:
                    stop_private_connection(Path.home())
                    dialog('--msgbox', 'The private DST connection is stopped. Game files were not changed.')
            elif choice == "status":
                report = discover()
                with tempfile.TemporaryDirectory(prefix="dst-deck-status-") as temp:
                    path = Path(temp) / "status.txt"
                    path.write_text(status_text(report))
                    dialog("--textbox", str(path), "850", "600")
        except Exception as exc:
            dialog("--error", str(exc))


if __name__ == "__main__":
    main()
