#!/usr/bin/env python3
"""Focused false-pass probes for a valid V9 benchmark record."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any

from benchmark import inventory, manifest_digest, write_json


def reject(
    name: str,
    record: Path,
    root: Path,
    expected_message: str,
) -> None:
    """Require a deliberately weakened record to fail for its intended reason."""
    result = subprocess.run(
        [sys.executable, str(root / "validate.py"), str(record)],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        raise RuntimeError(f"false pass: {name}")
    if expected_message not in result.stderr:
        raise RuntimeError(
            f"unexpected rejection for {name}: {result.stderr.strip()}"
        )


def read_document(record: Path) -> dict[str, Any]:
    value = json.loads((record / "record.json").read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError("test record is not a JSON object")
    return value


def write_document(record: Path, document: dict[str, Any]) -> None:
    write_json(record / "record.json", document)
    write_json(record / "inventory.json", inventory(record))


def copy_record(parent: Path, source: Path, name: str) -> Path:
    destination = parent / name
    shutil.copytree(source, destination)
    return destination


def replacement_case_id(case_id: str) -> str:
    return "heat_sn160" if case_id == "batch_alpha" else "batch_alpha"


def main(record: Path) -> None:
    root = Path(__file__).parent
    subprocess.run([sys.executable, str(root / "validate.py"), str(record)], check=True)

    with tempfile.TemporaryDirectory(prefix="xnet-v9-benchmark-tests-") as temporary:
        temporary_path = Path(temporary)

        malformed = copy_record(temporary_path, record, "malformed")
        (malformed / "record.json").write_text("not json", encoding="utf-8")
        reject("malformed record", malformed, root, "missing or malformed record.json")

        missing = copy_record(temporary_path, record, "missing-manifest")
        document = read_document(missing)
        document["input_bundle"]["entries"] = []
        write_document(missing, document)
        reject("missing manifest", missing, root, "missing input-bundle manifest")

        omitted = copy_record(temporary_path, record, "omitted-manifest-entry")
        document = read_document(omitted)
        document["input_bundle"]["entries"].pop()
        document["input_bundle"]["manifest_sha256"] = manifest_digest(
            document["input_bundle"]["entries"]
        )
        write_document(omitted, document)
        reject("omitted manifest entry", omitted, root, "input manifest binding mismatch")

        relabel = copy_record(temporary_path, record, "relabel")
        document = read_document(relabel)
        document["case"]["case_id"] = replacement_case_id(
            document["case"]["case_id"]
        )
        write_document(relabel, document)
        reject("case relabel", relabel, root, "case relabel or network binding mismatch")

        full_relabel = copy_record(temporary_path, record, "full-relabel")
        document = read_document(full_relabel)
        registry = json.loads((root / "cases.json").read_text(encoding="utf-8"))
        replacement = next(
            case
            for case in registry["cases"]
            if case["case_id"] == replacement_case_id(document["case"]["case_id"])
        )
        document["case"] = {
            key: replacement[key]
            for key in ("case_id", "network", "workload", "input_identity")
        }
        document["expected"] = replacement["expected"]
        write_document(full_relabel, document)
        reject("full case relabel", full_relabel, root, "input manifest binding mismatch")

        short = copy_record(temporary_path, record, "short-repetitions")
        document = read_document(short)
        document["repetitions"].pop()
        write_document(short, document)
        reject("short repetitions", short, root, "missing or short repetition list")

        profile = copy_record(temporary_path, record, "profile")
        document = read_document(profile)
        document["execution"]["dimensions"]["solver"] = "MA48"
        write_document(profile, document)
        reject("execution profile", profile, root, "execution profile does not match")

        timer = copy_record(temporary_path, record, "timer-section")
        document = read_document(timer)
        document["repetitions"][0]["timer_sections_seconds"][0].pop("EOS")
        write_document(timer, document)
        reject("incomplete timer section", timer, root, "full timer set")

        artifact = copy_record(temporary_path, record, "missing-artifact")
        (artifact / "repetitions" / "1" / "net_diag01").unlink()
        reject("missing artifact", artifact, root, "missing retained repetition artifacts")

        output = copy_record(temporary_path, record, "artifact-tamper")
        stream = output / "repetitions" / "1" / "xnet.stdout.txt"
        stream.write_text(stream.read_text(encoding="utf-8") + "tamper\n", encoding="utf-8")
        reject("artifact tamper", output, root, "artifact inventory is incomplete or tampered")

    fake = subprocess.run(
        [sys.executable, str(root / "capture.py"), "--executable", "/bin/true"],
        capture_output=True,
        text=True,
    )
    if fake.returncode == 0:
        raise RuntimeError("false pass: arbitrary executable option")
    print("benchmark false-pass probes: passed")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} VALID_RECORD")
    main(Path(sys.argv[1]).resolve())
