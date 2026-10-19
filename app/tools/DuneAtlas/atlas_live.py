"""Persist collection intent independently of collector processes and bundles."""
import json
import os
import secrets
from pathlib import Path


def load(root):
    try:
        path = Path(root) / 'live-v1.json'
        if path.stat().st_size > 1024:
            return True
        value = json.loads(path.read_text(encoding='utf-8'))
        # Only an explicit saved stop disables automatic collection.
        return not (isinstance(value, dict) and value.get('enabled') is False)
    except (OSError, ValueError):
        return True


def save(root, enabled):
    if type(enabled) is not bool:
        raise ValueError('Invalid Live preference')
    path = Path(root) / 'live-v1.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f'live-v1.{os.getpid()}.{secrets.token_hex(8)}.tmp')
    try:
        temp.write_text(json.dumps({'enabled': enabled}), encoding='utf-8')
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)
