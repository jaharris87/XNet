#!/usr/bin/env python3
"""Atomically create or exactly compare XNet's small text build record."""
from __future__ import annotations

import argparse
import os
import pathlib
import sys
import tempfile


def main() -> int:
    if sys.version_info < (3, 9):
        raise SystemExit("config_record.py requires Python 3.9 or newer")
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--environment", action="append", default=[], metavar="ENV=KEY")
    args = parser.parse_args()

    rows = ["XNET_CONFIG_SCHEMA=1"]
    seen = {"XNET_CONFIG_SCHEMA"}
    for specification in args.environment:
        environment, separator, key = specification.partition("=")
        if not separator:
            key = environment
        if environment not in os.environ:
            parser.error(f"missing environment field {environment}")
        value = os.environ[environment]
        if not key or key in seen or any(character in key for character in "=\r\n\x00"):
            parser.error(f"invalid or duplicate config field {key!r}")
        if any(character in value for character in "\r\n\x00"):
            parser.error(f"unrepresentable config field {key}")
        seen.add(key)
        rows.append(f"{key}={value}")

    text = "\n".join(rows) + "\n"
    path = args.output
    if path.exists():
        old = path.read_text(encoding="utf-8")
        if old == text:
            return 0
        old_rows = dict(row.split("=", 1) for row in old.splitlines() if "=" in row)
        new_rows = dict(row.split("=", 1) for row in rows)
        changed = [
            key for key in sorted(set(old_rows) | set(new_rows)) if old_rows.get(key) != new_rows.get(key)
        ]
        raise SystemExit(
            "incompatible BUILD_DIR configuration; differing fields: "
            + ", ".join(changed)
            + "\nclean this BUILD_DIR or select another BUILD_DIR"
        )

    path.parent.mkdir(parents=True, exist_ok=True)
    if any(path.parent.iterdir()):
        raise SystemExit(f"BUILD_DIR is nonempty but not a marked XNet build: {path.parent}")

    descriptor, temporary_name = tempfile.mkstemp(prefix=".config.", dir=path.parent, text=True)
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
