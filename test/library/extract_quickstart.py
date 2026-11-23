#!/usr/bin/env python3
"""Extract only the guide's Fortran Program quickstart example."""

from __future__ import annotations

import re
import sys
from pathlib import Path


PROGRAM = re.compile(r"^\s*program\s+quickstart\s*$", re.IGNORECASE | re.MULTILINE)
END_PROGRAM = re.compile(r"^\s*end\s+program\s+quickstart\s*$", re.IGNORECASE | re.MULTILINE)


def extract_quickstart(text: str) -> str:
    examples = []
    language = None
    lines: list[str] = []
    for line in text.splitlines(keepends=True):
        if line.startswith("```"):
            fence = line.strip()
            if language is None:
                language = fence[3:]
                lines = []
            else:
                source = "".join(lines)
                if language == "fortran" and PROGRAM.search(source):
                    if fence != "```":
                        raise ValueError("quickstart Fortran fence is not closed")
                    examples.append(source)
                language = None
            continue
        if language is not None:
            lines.append(line)
    if language == "fortran" and PROGRAM.search("".join(lines)):
        raise ValueError("quickstart Fortran fence is not closed")
    if len(examples) != 1:
        raise ValueError(f"expected one Fortran Program quickstart fence, found {len(examples)}")
    source = examples[0]
    if len(PROGRAM.findall(source)) != 1 or len(END_PROGRAM.findall(source)) != 1:
        raise ValueError("expected one complete Program quickstart in its fence")
    return source


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract_quickstart.py GUIDE OUTPUT")
    try:
        source = extract_quickstart(Path(sys.argv[1]).read_text())
    except ValueError as error:
        raise SystemExit(str(error)) from error
    Path(sys.argv[2]).write_text(source)
