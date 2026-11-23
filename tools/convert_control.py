#!/usr/bin/env python3
"""Convert conventional v8.0 ASCII control records to a flat controls.nml."""

import argparse
from pathlib import Path
import re
import sys


# source/xnet_controls.F90 at v8.0 (b017bd657bb38105b9a61908aa51adb1361e5ba5).
SCALARS = {
    "Job Controls": ("szone", "nzone", "iweak0", "iscrn", "iprocess"),
    "Zone Batching Controls": ("nzbatchmx",),
    "Integration Controls": (
        "isolv", "kstmx", "kitmx", "ijac", "iconvc", "changemx", "yacc",
        "tolm", "tolc", "ymin", "tdel_maxmult",
    ),
    "Self-heating Controls": ("iheat", "changemxt", "tolt9"),
    "NSE Initial Conditions": ("t9nse",),
    "Neutrinos": ("ineutrino",),
}
DEFAULTS = {
    "Zone Batching Controls": ("1",),
    # The tracked v8 GNU build promotes default real to eight bytes.
    "Self-heating Controls": ("0", "1.0e-2", "1.0e-4"),
    "NSE Initial Conditions": ("8.0",),
    "Neutrinos": ("0",),
}
INTEGER_FIELDS = {
    "szone", "nzone", "iweak0", "iscrn", "iprocess", "nzbatchmx", "isolv",
    "kstmx", "kitmx", "ijac", "iconvc", "iheat", "ineutrino", "idiag", "itsout",
}
TITLES = ("Problem Description", *SCALARS, "Output Controls", "Input Controls")
INTEGER = r"[+-]?[0-9]+"
REAL = r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eEdD][+-]?[0-9]+)?"


class ConversionError(ValueError):
    """Missing, ambiguous, or unsupported historical input."""


def convert(text):
    """Return (namelist, warnings), without accessing paths named by the input."""
    if not text.isascii():
        raise ConversionError("only ASCII control files are supported")
    if any(ord(char) < 32 and char not in "\n\r\t" for char in text):
        raise ConversionError("unsupported control character in input")
    lines = text.splitlines()
    blocks = {}
    used = set()
    for index, line in enumerate(lines[:1000]):
        if not line.startswith("##"):
            continue
        matches = [title for title in TITLES if title in line[2:82]]
        if len(matches) > 1:
            raise ConversionError(f"line {index + 1}: ambiguous block title")
        if matches:
            title = matches[0]
            if title in blocks:
                raise ConversionError(f"line {index + 1}: duplicate {title} block")
            blocks[title] = index + 1
            used.add(index)
    values = []

    def record(index, field):
        if index >= len(lines) or index + 1 in blocks.values():
            raise ConversionError(f"line {index + 1}: missing record for {field}")
        used.add(index)
        return lines[index]

    def block(title):
        if title not in blocks:
            raise ConversionError(f"missing required {title} block (case-sensitive)")
        return blocks[title]

    def scalar(index, field):
        line = record(index, field).lstrip(" \t")
        pattern = INTEGER if field in INTEGER_FIELDS else REAL
        match = re.match(rf"({pattern})(?=$|[ \t!,/])", line)
        if not match:
            raise ConversionError(f"line {index + 1}: unsupported numeric record for {field}")
        # A separate list-directed READ consumed just one value; the record's label was discarded.
        return match[1]

    def string(index, field):
        value = record(index, field)[:80].rstrip(" ")
        if "\t" in value:
            raise ConversionError(f"line {index + 1}: tabs in A80 strings are unsupported")
        return value

    def quoted(value):
        return "'" + value.replace("'", "''") + "'"

    index = block("Problem Description")
    for number in range(1, 4):
        values.append((f"description({number})", quoted(string(index + number - 1, "description"))))
    controls = {}
    for title, fields in SCALARS.items():
        if title not in blocks and title in DEFAULTS:
            if len(lines) >= 1000:
                raise ConversionError(
                    f"unsupported scan exhaustion: {title} absent from the first 1000 records; "
                    "v8 did not reach EOF to select defaults; migrate this input manually"
                )
            tokens = DEFAULTS[title]
        else:
            index = block(title)
            tokens = [scalar(index + offset, field) for offset, field in enumerate(fields)]
        controls.update(zip(fields, tokens))
        values.extend(zip(fields, tokens))
    nzone = int(controls["nzone"])
    if nzone < 1:
        raise ConversionError("nzone must be positive")

    index = block("Output Controls")
    for offset, field in enumerate(("idiag", "itsout")):
        values.append((field, scalar(index + offset, field)))
    for offset, field in ((3, "ev_file_base"), (5, "bin_file_base")):
        record(index + offset - 1, f"{field} label")
        values.append((field, quoted(string(index + offset, field))))
    count = record(index + 6, "nnucout")[50:54].replace(" ", "") or "0"
    if not re.fullmatch(INTEGER, count) or int(count) < 0:
        raise ConversionError(f"line {index + 7}: invalid nnucout in columns 51-54")
    values.append(("nnucout", count))
    # Format reversion starts a fresh record after every fourteen A5 fields.
    for offset in range(max(1, (int(count) + 13) // 14)):
        row = record(index + 7 + offset, "output_nuclei").ljust(70)
        if "\t" in row[:70]:
            raise ConversionError(f"line {index + 8 + offset}: tabs in A5 species are unsupported")
        for column in range(min(14, int(count) - 14 * offset)):
            name = row[column * 5:column * 5 + 5]
            if not name.strip():
                raise ConversionError(f"line {index + 8 + offset}: blank output species")
            values.append((f"output_nuclei({14 * offset + column + 1})", quoted(name)))

    index = block("Input Controls")
    record(index, "data_dir label")
    data_dir = string(index + 1, "data_dir")
    if not data_dir.strip():
        raise ConversionError("data_dir is blank")
    values.append(("data_dir", quoted(data_dir)))
    record(index + 2, "input filenames label")
    index += 3
    pairs = []
    while len(pairs) < nzone and index < len(lines):
        abundance = string(index, "inab_files")
        thermo = string(index + 1, "thermo_files")
        if not abundance.strip() or not thermo.strip():
            raise ConversionError(f"line {index + 1}: blank input file pair")
        pairs.append((abundance, thermo))
        index += 2
    if not pairs:
        raise ConversionError("missing input file pair")
    if any(".h5" in thermo or ".hdf" in thermo for _, thermo in pairs):
        raise ConversionError("HDF input conversion is unsupported; supply ASCII file pairs")
    if len(pairs) == 1 and nzone > 1:
        if nzone > 999999999:
            raise ConversionError("v8 filename suffixes support at most nine digits")
        abundance, thermo = pairs[0]
        width = len(str(nzone))
        pairs = [((abundance + str(number).zfill(width))[:80],
                  (thermo + str(number).zfill(width))[:80]) for number in range(1, nzone + 1)]
    elif len(pairs) != nzone:
        raise ConversionError(f"expected one base pair or {nzone} complete input pairs; got {len(pairs)}")
    for number, (abundance, thermo) in enumerate(pairs, 1):
        values.append((f"inab_files({number})", quoted(abundance)))
        values.append((f"thermo_files({number})", quoted(thermo)))
    unused = [number + 1 for number, line in enumerate(lines) if number not in used and line.strip()]
    warnings = []
    if unused:
        warnings.append(f"{len(unused)} unused nonblank record(s), starting at line {unused[0]}; "
                        "v8 consumes at most nzone input pairs")
    namelist = "&xnet_controls\n" + "".join(f"  {key} = {value}\n" for key, value in values) + "/\n"
    return namelist, warnings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("control", type=Path, help="assembled v8.0 ASCII control file")
    parser.add_argument("-o", "--output", type=Path, help="create a new namelist file; never overwrite")
    args = parser.parse_args()
    try:
        namelist, warnings = convert(args.control.read_text(encoding="ascii"))
        if args.output:
            with args.output.open("x", encoding="ascii", newline="\n") as output:
                output.write(namelist)
        else:
            sys.stdout.write(namelist)
        for warning in warnings:
            print(f"warning: {warning}", file=sys.stderr)
    except (OSError, UnicodeError, ConversionError) as error:
        parser.exit(2, f"error: {error}\n")


if __name__ == "__main__":
    main()
