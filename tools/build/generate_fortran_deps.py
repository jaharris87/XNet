#!/usr/bin/env python3
"""Generate checked Make prerequisites from retained preprocessed Fortran."""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import sys
import tempfile

MODULE = re.compile(r"^\s*module\s+(?!procedure\b|subroutine\b|function\b)([a-z][a-z0-9_]*)\b", re.I)
SUBMODULE = re.compile(
    r"^\s*submodule\s*\(\s*([a-z][a-z0-9_]*(?::[a-z][a-z0-9_]*)?)\s*\)\s*([a-z][a-z0-9_]*)\b",
    re.I,
)
USE = re.compile(r"^\s*use(?:\s*,\s*(?:intrinsic|non_intrinsic)\s*)?(?:::)?\s*([a-z][a-z0-9_]*)\b", re.I)
INCLUDE = re.compile(r"^\s*include\s*[\"']([^\"']+)[\"']", re.I)


def mapping(value: str) -> tuple[str, pathlib.Path]:
    obj, separator, source = value.partition("=")
    if not separator:
        raise argparse.ArgumentTypeError("mapping must be OBJECT=SOURCE")
    return obj, pathlib.Path(source)


def make_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace(" ", "\\ ").replace("#", "\\#").replace("$", "$$")


def scan(path: pathlib.Path, include_dirs: list[pathlib.Path], visited: set[pathlib.Path]):
    resolved = path.resolve()
    if resolved in visited:
        return set(), set(), set()
    visited.add(resolved)
    try:
        lines = resolved.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        raise ValueError(f"cannot read {resolved}: {error}") from error
    provides: set[str] = set()
    requires: set[str] = set()
    includes: set[pathlib.Path] = set()
    for original in lines:
        line = original.split("!", 1)[0]
        match = MODULE.match(line)
        if match:
            provides.add(match.group(1).lower())
        match = SUBMODULE.match(line)
        if match:
            requires.add(match.group(1).lower().split(":")[-1])
            provides.add(match.group(2).lower())
        match = USE.match(line)
        if match:
            requires.add(match.group(1).lower())
        match = INCLUDE.match(line)
        if match:
            name = match.group(1)
            candidates = [resolved.parent / name, *(directory / name for directory in include_dirs)]
            included = next((candidate.resolve() for candidate in candidates if candidate.is_file()), None)
            if included is None:
                raise ValueError(f"includes missing file {name}")
            includes.add(included)
            nested_provides, nested_requires, nested_includes = scan(included, include_dirs, visited)
            provides.update(nested_provides)
            requires.update(nested_requires)
            includes.update(nested_includes)
    return provides, requires, includes


def main() -> int:
    if sys.version_info < (3, 9):
        raise SystemExit("generate_fortran_deps.py requires Python 3.9 or newer")
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--mapping", action="append", required=True, type=mapping)
    parser.add_argument("--external-module", action="append", default=[])
    parser.add_argument("--external-module-dir", action="append", default=[], type=pathlib.Path)
    parser.add_argument("--include-dir", action="append", default=[], type=pathlib.Path)
    args = parser.parse_args()

    external = {name.lower() for name in args.external_module}
    for directory in args.external_module_dir:
        if not directory.is_dir():
            raise SystemExit(f"dependency generator: external module directory does not exist: {directory}")
        external.update(
            path.stem.lower()
            for path in directory.iterdir()
            if path.is_file() and path.suffix.lower() in {".mod", ".smod"}
        )

    include_dirs = [path.resolve() for path in args.include_dir]
    providers: dict[str, str] = {}
    requirements: dict[str, set[str]] = {}
    includes: dict[str, set[pathlib.Path]] = {}
    for obj, source in args.mapping:
        try:
            provided, required, closure = scan(source, include_dirs, set())
        except ValueError as error:
            raise SystemExit(f"dependency generator: {obj} {error}") from error
        for name in sorted(provided):
            if name in providers and providers[name] != obj:
                raise SystemExit(
                    f"dependency generator: duplicate provider for module/submodule {name}: {providers[name]}, {obj}"
                )
            providers[name] = obj
        requirements[obj] = required
        includes[obj] = closure

    output = ["# Generated from retained preprocessing; do not edit."]
    for obj in sorted(requirements):
        dependencies: set[str] = set()
        for name in sorted(requirements[obj]):
            provider = providers.get(name)
            if provider is None:
                if name not in external:
                    raise SystemExit(f"dependency generator: {obj} uses missing provider module/submodule {name}")
            elif provider != obj:
                dependencies.add(provider)
        rendered = [
            *(make_escape(item) for item in sorted(dependencies)),
            *(make_escape(str(item)) for item in sorted(includes[obj])),
        ]
        target = make_escape(obj)
        output.append(f"{target}: {' '.join(rendered)}" if rendered else f"{target}:")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=args.output.parent, prefix=args.output.name + ".", delete=False
    ) as stream:
        stream.write("\n".join(output) + "\n")
        temporary = pathlib.Path(stream.name)
    try:
        os.replace(temporary, args.output)
    finally:
        if temporary.exists():
            temporary.unlink()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
