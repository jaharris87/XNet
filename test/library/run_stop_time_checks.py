#!/usr/bin/env python3
"""Stage the public alpha network for the production timestep component checks."""
from __future__ import annotations

import argparse
import tempfile
from pathlib import Path

from run_output_tests import ascii_copy, run


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--net-setup", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    setup = args.net_setup.resolve(strict=True)
    root = Path(__file__).resolve().parents[2]
    args.work_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="stop-time-", dir=args.work_dir.resolve()))
    print(f"Stop-time checks: {work}", flush=True)
    data = work / "Data_alpha"
    ascii_copy(root / "test/Data_alpha", data)
    run([str(setup)], data, work / "net_setup.log", "Public alpha stop-time checks\n")
    (work / "helm_table.dat").symlink_to(root / "tools/starkiller-helmholtz/helm_table.dat")
    output = run([str(executable), data.name], work, work / "checks.log")
    if "STOP_TIME_CHECKS_PASSED" not in output:
        raise RuntimeError(f"missing completion marker: {work / 'checks.log'}")
    print(output, end="", flush=True)


if __name__ == "__main__":
    main()
