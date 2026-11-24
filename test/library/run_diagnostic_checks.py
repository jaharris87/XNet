#!/usr/bin/env python3
"""Check production weak warnings, LU diagnostics, and the standalone failure dump."""
from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path

from run_output_tests import ascii_copy, run


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--net-setup', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    setup = args.net_setup.resolve(strict=True)
    root = Path(__file__).resolve().parents[2]
    args.work_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='diagnostic-', dir=args.work_dir.resolve()))
    print(f'Diagnostic checks: {work}', flush=True)
    data = work / 'Data_alpha'
    ascii_copy(root / 'test/Data_alpha', data)
    run([str(setup)], data, work / 'net_setup.log', 'Public alpha diagnostic checks\n')
    (work / 'helm_table.dat').symlink_to(root / 'tools/starkiller-helmholtz/helm_table.dat')
    result = subprocess.run([str(executable), data.name], cwd=work, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    (work / 'checks.log').write_text(result.stdout + f'\nPROCESS_EXIT_STATUS {result.returncode}\n')
    if result.returncode != 1:
        raise RuntimeError(f'expected standalone failure exit 1, got {result.returncode}: {work}')
    for marker in ('WEAK_DIAGNOSTIC_CHECKS_PASSED', 'LU_DIAGNOSTIC_CHECKS_PASSED',
                   'FAILURE_DUMP_EXPECTED', '[XNet] Evolution failed to converge'):
        if marker not in result.stdout:
            raise RuntimeError(f'missing {marker}: {work}')
    if result.stdout.count('Warning: Strong reactions ignored for T9 < T9min.') != 2:
        raise RuntimeError(f'wrong weak warning count: {work}')
    rows = (work / 'ab_fail_001_002_003').read_text().splitlines()[1:]
    values = [(row[:5].strip(), float(row[5:])) for row in rows]
    if not values or any(value != (0.0 if name == 'Aux' else 0.125) for name, value in values):
        raise RuntimeError(f'wrong pre-step abundances in failure dump: {work}')
    if not (work / 'th_fail_001_002_003').is_file():
        raise RuntimeError(f'missing thermodynamic failure dump: {work}')
    print(result.stdout, end='')
    print('DIAGNOSTIC_CHECKS_PASSED')


if __name__ == '__main__':
    main()
