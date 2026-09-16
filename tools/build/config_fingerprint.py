#!/usr/bin/env python3
"""Produce deterministic configuration keys and atomically write manifests."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


def fields(values: list[str]) -> dict[str, str]:
    answer = {}
    for value in values:
        key, separator, field = value.partition("=")
        if not separator:
            raise ValueError(f"field is not KEY=VALUE: {value}")
        answer[key] = " ".join(field.split())
    return answer


def revision(root: pathlib.Path) -> dict[str, str]:
    try:
        commit = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL).strip()
        dirty = subprocess.call(["git", "-C", str(root), "diff", "--quiet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0
        return {"source_commit": commit, "source_dirty": str(dirty).lower()}
    except (OSError, subprocess.CalledProcessError):
        return {"source_commit": "archive", "source_dirty": "unavailable"}


def command_identity(command: str) -> dict[str, str]:
    """Return a stable description without requiring a particular wrapper."""
    words = command.split()
    if not words:
        return {"command": "", "realpath": "unavailable", "version": "unavailable"}
    executable = shutil.which(words[0])
    if executable is None:
        return {"command": command, "realpath": "unavailable", "version": "unavailable"}
    try:
        version = subprocess.check_output([executable, "--version"], text=True, stderr=subprocess.STDOUT, timeout=5).splitlines()[0]
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, IndexError):
        version = "unavailable"
    return {"command": command, "realpath": str(pathlib.Path(executable).resolve()), "version": version}


def path_identities(value: str) -> list[dict[str, str]]:
    identities = []
    for item in value.split():
        path = pathlib.Path(item)
        resolved = path.resolve()
        record = {"path": str(resolved)}
        if resolved.is_file():
            record["sha256"] = hashlib.sha256(resolved.read_bytes()).hexdigest()
        elif resolved.exists():
            stat = resolved.stat()
            record["identity"] = f"directory:{stat.st_mtime_ns}:{stat.st_size}"
        else:
            record["identity"] = "unavailable"
        identities.append(record)
    return identities


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--field", action="append", default=[])
    parser.add_argument("--digest", action="store_true")
    parser.add_argument("--write", type=pathlib.Path)
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--environment", action="append", default=[], metavar="ENV=KEY")
    parser.add_argument("--command", action="append", default=[], metavar="ENV=KEY")
    parser.add_argument("--path-list", action="append", default=[], metavar="ENV=KEY")
    args = parser.parse_args()
    data = fields(args.field)
    command_data: dict[str, dict[str, str]] = {}
    for value in args.environment:
        environment, separator, key = value.partition("=")
        if not separator:
            raise ValueError("environment mapping must be ENV=KEY")
        data[key] = " ".join(os.environ.get(environment, "unavailable").split())
    for value in args.command:
        environment, separator, key = value.partition("=")
        if not separator:
            raise ValueError("command mapping must be ENV=KEY")
        command_data[key] = command_identity(os.environ.get(environment, ""))
        data[key] = json.dumps(command_data[key], sort_keys=True, separators=(",", ":"))
    for value in args.path_list:
        environment, separator, key = value.partition("=")
        if not separator:
            raise ValueError("path mapping must be ENV=KEY")
        data[key] = json.dumps(path_identities(os.environ.get(environment, "")), sort_keys=True, separators=(",", ":"))
    encoded = json.dumps(dict(sorted(data.items())), ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    digest = hashlib.sha256(encoded).hexdigest()
    if args.digest:
        print(digest)
    if args.write:
        payload = {"configuration": dict(sorted(data.items())), "commands": command_data, "digest": digest, **revision(args.root.resolve())}
        args.write.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=args.write.parent, prefix=args.write.name + ".", delete=False) as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            name = handle.name
        os.replace(name, args.write)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
