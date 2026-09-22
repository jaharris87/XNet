#!/usr/bin/env python3
"""Focused false-pass probes for a valid V9 benchmark record."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def reject(name: str, record: Path, root: Path) -> None:
    result = subprocess.run([sys.executable, str(root / "validate.py"), str(record)], capture_output=True, text=True)
    if result.returncode == 0:
        raise RuntimeError(f"false pass: {name}")


def main(record: Path) -> None:
    root = Path(__file__).parent
    subprocess.run([sys.executable, str(root / "validate.py"), str(record)], check=True)
    with tempfile.TemporaryDirectory(prefix="xnet-v9-benchmark-tests-") as temporary:
        temporary_path = Path(temporary)
        def copy(name: str) -> Path:
            destination = temporary_path / name
            shutil.copytree(record, destination)
            return destination
        malformed = copy("malformed"); (malformed / "record.json").write_text("not json") ; reject("malformed record", malformed, root)
        missing = copy("missing"); document = json.loads((missing / "record.json").read_text()); document["input_bundle"]["entries"] = []; (missing / "record.json").write_text(json.dumps(document)); reject("missing manifest", missing, root)
        short = copy("short"); document = json.loads((short / "record.json").read_text()); document["capture"]["repetitions_requested"] += 1; (short / "record.json").write_text(json.dumps(document)); reject("short repetitions", short, root)
        tamper = copy("tamper"); document = json.loads((tamper / "record.json").read_text()); document["input_bundle"]["entries"][0]["sha256"] = "0" * 64; (tamper / "record.json").write_text(json.dumps(document)); reject("input tamper", tamper, root)
        relabel = copy("relabel"); document = json.loads((relabel / "record.json").read_text()); document["case"]["case_id"] = "heat_sn160" if document["case"]["case_id"] == "batch_alpha" else "batch_alpha"; (relabel / "record.json").write_text(json.dumps(document)); reject("case relabel", relabel, root)
        full_relabel = copy("full-relabel"); document = json.loads((full_relabel / "record.json").read_text()); registry = json.loads((root / "cases.json").read_text()); replacement = next(case for case in registry["cases"] if case["case_id"] == ("heat_sn160" if document["case"]["case_id"] == "batch_alpha" else "batch_alpha")); document["case"] = {key: replacement[key] for key in ("case_id", "network", "workload", "input_identity")}; document["expected"] = replacement["expected"]; (full_relabel / "record.json").write_text(json.dumps(document)); reject("full case relabel", full_relabel, root)
        artifact = copy("artifact"); (artifact / "repetitions" / "1" / "net_diag01").unlink(); reject("missing artifact", artifact, root)
        output = copy("output"); stream = output / "repetitions" / "1" / "xnet.stdout.txt"; stream.write_text(stream.read_text() + "tamper\n"); reject("artifact tamper", output, root)
    fake = subprocess.run([sys.executable, str(root / "capture.py"), "--executable", "/bin/true"], capture_output=True, text=True)
    if fake.returncode == 0:
        raise RuntimeError("false pass: arbitrary executable option")
    print("benchmark false-pass probes: passed")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} VALID_RECORD")
    main(Path(sys.argv[1]).resolve())
