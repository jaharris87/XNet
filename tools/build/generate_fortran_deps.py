#!/usr/bin/env python3
"""Generate checked Make prerequisites from retained preprocessed Fortran.

The production Makefile supplies one ``object=preprocessed-source`` mapping per
configuration.  This tool deliberately has no compiler-specific parser: the
compiler has already selected includes and conditional branches.  It rejects
duplicate in-tree module providers and missing in-tree providers instead of
allowing Make to happen to find a stale ``.mod`` file.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

MODULE = re.compile(r"^\s*module\s+(?!procedure\b)([a-z][a-z0-9_]*)\b", re.I)
SUBMODULE = re.compile(r"^\s*submodule\s*\(\s*([a-z][a-z0-9_]*)(?::[a-z0-9_]+)?\s*\)", re.I)
USE = re.compile(r"^\s*use(?:\s*,\s*(?:intrinsic|non_intrinsic)\s*)?(?:::)?\s*([a-z][a-z0-9_]*)\b", re.I)


def mapping(value: str) -> tuple[str, pathlib.Path]:
    try:
        obj, source = value.split("=", 1)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("mapping must be OBJECT=SOURCE") from exc
    return obj, pathlib.Path(source)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--mapping", action="append", required=True, type=mapping)
    parser.add_argument("--external-module", action="append", default=[])
    args = parser.parse_args()
    external = {name.lower() for name in args.external_module}
    providers: dict[str, str] = {}
    requirements: dict[str, set[str]] = {}
    for obj, source in args.mapping:
        try:
            lines = source.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as exc:
            print(f"dependency generator: cannot read {source}: {exc}", file=sys.stderr)
            return 2
        uses: set[str] = set()
        for line in lines:
            line = line.split("!", 1)[0]
            match = MODULE.match(line)
            if match:
                name = match.group(1).lower()
                if name in providers and providers[name] != obj:
                    print(f"dependency generator: duplicate provider for module {name}: {providers[name]}, {obj}", file=sys.stderr)
                    return 2
                providers[name] = obj
            match = SUBMODULE.match(line)
            if match:
                uses.add(match.group(1).lower())
            match = USE.match(line)
            if match:
                uses.add(match.group(1).lower())
        requirements[obj] = uses
    out: list[str] = ["# Generated from retained preprocessing; do not edit."]
    for obj, uses in sorted(requirements.items()):
        deps = []
        for module in sorted(uses):
            provider = providers.get(module)
            if provider is None:
                if module not in external:
                    print(f"dependency generator: {obj} uses missing provider module {module}", file=sys.stderr)
                    return 2
            elif provider != obj:
                deps.append(provider)
        out.append(f"{obj}: {' '.join(deps)}" if deps else f"{obj}:")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text("\n".join(out) + "\n", encoding="utf-8")
    temporary.replace(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
