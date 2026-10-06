# /// script
# dependencies = ["tomlkit"]
# ///
"""Merge the TOML file SOURCE into DESTINATION, keeping DESTINATION's formatting.

Tables merge key by key; any other SOURCE value replaces DESTINATION's.
Keys only in DESTINATION are left alone.

Usage: uv run merge-toml.py SOURCE DESTINATION
"""

import sys
from pathlib import Path

import tomlkit


def merge(dst, src):
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            merge(dst[key], value)
        else:
            dst[key] = value


source = tomlkit.parse(Path(sys.argv[1]).read_text())
path = Path(sys.argv[2])
config = tomlkit.parse(path.read_text()) if path.exists() else tomlkit.document()
merge(config, source)
path.write_text(tomlkit.dumps(config))
