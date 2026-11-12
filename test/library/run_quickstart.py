#!/usr/bin/env python3
"""Run the compiled guide example with its documented public ASCII inputs."""

from __future__ import annotations

import argparse
import shutil
import tempfile
from pathlib import Path

from run_library_tests import run


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    root = Path(__file__).resolve().parents[2]
    args.work_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="quickstart-", dir=args.work_dir.resolve()))
    print(f"Guide quickstart work: {work}", flush=True)
    network = work / "network"
    network.mkdir()
    for name in ("sunet", "netwinv", "netsu", "netweak"):
        shutil.copyfile(root / "test/Data_alpha" / name, network / name)
    (work / "helm_table.dat").symlink_to(root / "tools/starkiller-helmholtz/helm_table.dat")
    output = run([str(executable)], work, work / "quickstart.log")
    if "evolve seconds:" not in output or "returned Ye:" not in output:
        raise RuntimeError(f"quickstart did not report a completed burn; see {work / 'quickstart.log'}")
    for name in ("nets3", "nets4", "match_data"):
        if not (network / name).is_file():
            raise RuntimeError(f"quickstart did not preprocess {network / name}")
    print("PASS guide quickstart: initialize, preprocess, burn and finalize", flush=True)
