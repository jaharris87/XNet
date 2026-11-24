#!/usr/bin/env python3
"""Check API preprocessing progress separately from warnings, errors and data files."""
import argparse
import subprocess
import tempfile
from pathlib import Path

from run_output_tests import GENERATED, ascii_copy, require

PROGRESS = ("Listing Nuclei", "Reading and reformating reactions data", "Registering reactions to species",
            "number of reactions of different types", "necessary dimensions",
            "Matching forward and reverse reactions", "Determining network sparsity pattern")
WARNINGS = ("Dropping reaction", "not found for entry", "treating as strong rate", "but iec=",
            "These descriptions need to be added to net_setup:")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--consumer", type=Path, required=True)
    parser.add_argument("--net-setup", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    consumer, setup = (str(p.resolve(strict=True)) for p in (args.consumer, args.net_setup))
    root = Path(__file__).resolve().parents[2]
    args.work_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="progress-", dir=args.work_dir.resolve()))
    print(f"Preprocessing progress checks: {work}", flush=True)

    def prepare(name, mutation):
        case = work / name
        case.mkdir()
        data = case / "Data_alpha"
        ascii_copy(root / "test/Data_alpha", data)
        (case / "helm_table.dat").symlink_to(root / "tools/starkiller-helmholtz/helm_table.dat")
        rows = (data / "netsu").read_text().splitlines(keepends=True)
        species = set((data / "sunet").read_text().split())
        reactions = [i for i, row in enumerate(rows) if row[:2].strip() == "0" and row[5:10].strip() in species]
        require(len(reactions) >= 2, "public alpha input needs two reaction records")
        if mutation == "warnings":
            i, j = reactions[:2]
            rows[i] = rows[i][:43] + "zzzzw" + rows[i][48:]
            rows[j] = rows[j][:5] + "badxx" + rows[j][10:]
        elif mutation == "truncated":
            rows = rows[:reactions[0] + 1]
        (data / "netsu").write_text("".join(rows))
        return case, data, {p.name for p in data.iterdir()}

    def run(command, cwd, log, stdin=None):
        result = subprocess.run(command, cwd=cwd, input=stdin, text=True, capture_output=True,
                                timeout=30, check=False)
        output = result.stdout + result.stderr
        log.write_text(output + f"\nPROCESS_EXIT_STATUS {result.returncode}\n")
        return result, output

    for mutation in ("normal", "warnings"):
        products = []
        for mode in ("standalone", "verbose_preprocess", "quiet_preprocess"):
            case, data, inputs = prepare(mutation + "-" + mode, mutation)
            standalone = mode == "standalone"
            result, output = run([setup] if standalone else [consumer, "Data_alpha", mode],
                                 data if standalone else case, case / "process.log",
                                 "Data_alpha\n" if standalone else None)
            require(result.returncode == 0, f"preprocessing failed: {case}")
            require(all((token in output) == (mode != "quiet_preprocess") for token in PROGRESS),
                    f"wrong progress verbosity: {case}")
            species_count = str(len((data / "sunet").read_text().split()))
            require(any(line.strip() == species_count for line in output.splitlines()) == (mode != "quiet_preprocess"),
                    f"wrong standalone species-count progress: {case}")
            if not standalone:
                require("PREPROCESS_MODE_CHECKS_PASSED" in output, f"API initialization did not finish: {case}")
            if mutation == "warnings":
                require(all(token in output for token in WARNINGS), f"warning hidden: {case}")
            require({p.name for p in data.iterdir()} - inputs == set(GENERATED), f"wrong generated files: {case}")
            products.append({name: (data / name).read_bytes() for name in GENERATED})
        require(products[0] == products[1] == products[2], f"verbosity changed generated data: {mutation}")
        print(f"PASS {mutation}: standalone/verbose/quiet output policy; all {len(GENERATED)} products identical", flush=True)

    case, data, inputs = prepare("quiet-error", "truncated")
    result, output = run([consumer, "Data_alpha", "quiet_preprocess"], case, case / "process.log")
    require(result.returncode != 0, "truncated reaction unexpectedly succeeded")
    require("XNet error: Truncated reaction" in output, "quiet mode hid fatal reaction diagnostic")
    require(not any(token in output for token in PROGRESS), "quiet error printed progress")
    require("PREPROCESS_MODE_CHECKS_PASSED" not in output, "failed setup reported success")
    print("PREPROCESS_PROGRESS_CHECKS_PASSED", flush=True)


if __name__ == "__main__":
    main()
