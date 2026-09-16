#!/usr/bin/env python3
"""Focused effectiveness checks for the isolated Make support tools."""
from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]


def run(*args: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=True, text=True, **kwargs)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="xnet-build-graph-") as temporary:
        work = pathlib.Path(temporary)
        pp = work / "pp"
        pp.mkdir()
        (pp / "one.F90").write_text("module one\nend module one\n", encoding="utf-8")
        (pp / "two.F90").write_text("module two\n use one\nend module two\n", encoding="utf-8")
        dep = work / "dep" / "fortran.d"
        run(sys.executable, str(ROOT / "tools/build/generate_fortran_deps.py"), "--output", str(dep), "--mapping", f"{work}/one.o={pp}/one.F90", "--mapping", f"{work}/two.o={pp}/two.F90")
        assert f"{work}/two.o: {work}/one.o" in dep.read_text(encoding="utf-8")
        # The deterministic Cray fixture proves the wrapper retains rather than
        # deletes the source seen by the compiler/dependency phase.
        fixture = work / "fixture.F90"
        fixture.write_text("#define VALUE 7\nmodule fixture\ninteger, parameter :: value = VALUE\nend module fixture\n", encoding="utf-8")
        retained = work / "retained"
        environment = os.environ | {"XNET_CPP_OUTPUT_DIR": str(retained), "XNET_CRAY_FTN": "/usr/bin/true", "XNET_CPP": "cpp"}
        run(str(ROOT / "source/crayftn_cpp.sh"), "-eZ", str(fixture), "-o", str(work / "fixture.o"), env=environment)
        output = retained / "fixture.f90"
        assert output.exists() and "parameter :: value = 7" in output.read_text(encoding="utf-8")
        manifest = work / "manifest.json"
        command = [sys.executable, str(ROOT / "tools/build/config_fingerprint.py"), "--field", "PE_ENV=GNU", "--field", "CMODE=OPT", "--write", str(manifest), "--root", str(ROOT)]
        first = subprocess.Popen(command)
        second = subprocess.Popen(command)
        assert first.wait() == second.wait() == 0
        assert json.loads(manifest.read_text(encoding="utf-8"))["configuration"]["PE_ENV"] == "GNU"
        archive_manifest = work / "archive-manifest.json"
        run(sys.executable, str(ROOT / "tools/build/config_fingerprint.py"), "--field", "PE_ENV=GNU", "--write", str(archive_manifest), "--root", str(work))
        assert json.loads(archive_manifest.read_text(encoding="utf-8"))["source_commit"] == "archive"
        missing = pp / "missing.F90"
        missing.write_text("module missing\n use nowhere\nend module missing\n", encoding="utf-8")
        rejected = subprocess.run([sys.executable, str(ROOT / "tools/build/generate_fortran_deps.py"), "--output", str(dep), "--mapping", f"{work}/missing.o={missing}"], text=True, capture_output=True)
        assert rejected.returncode != 0 and "missing provider" in rejected.stderr
        external = pp / "external_consumer.F90"
        external.write_text("module external_consumer\n use precompiled_provider\nend module external_consumer\n", encoding="utf-8")
        run(sys.executable, str(ROOT / "tools/build/generate_fortran_deps.py"), "--output", str(dep), "--mapping", f"{work}/external_consumer.o={external}", "--external-module", "precompiled_provider")
        provider = work / "precompiled_provider.F90"
        provider.write_text("module precompiled_provider\n integer, parameter :: answer = 42\nend module precompiled_provider\n", encoding="utf-8")
        consumer = work / "consumer.F90"
        consumer.write_text("program consumer\n use precompiled_provider\n if (answer /= 42) error stop 1\nend program consumer\n", encoding="utf-8")
        external_mod = work / "external-mod"
        external_mod.mkdir()
        run("gfortran", "-J", str(external_mod), "-c", str(provider), "-o", str(work / "provider.o"))
        run("gfortran", "-I", str(external_mod), str(consumer), str(work / "provider.o"), "-o", str(work / "consumer"))
        run(str(work / "consumer"))
    # Every retained preprocessed source depends on the macro include.  Touch
    # only its timestamp, rebuild, and restore it so this test leaves source
    # content and metadata unchanged.
    macro = ROOT / "source/xnet_macros.fh"
    before = macro.stat().st_mtime_ns
    run("make", "-C", str(ROOT / "source"), "--no-print-directory", "xnet")
    os.utime(macro, None)
    try:
        run("make", "-C", str(ROOT / "source"), "--no-print-directory", "xnet")
    finally:
        os.utime(macro, ns=(before, before))
    source = ROOT / "source"
    quiet = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    # Separate configurations may build simultaneously and must produce only
    # their own roots.  The same configuration may also race manifest creation.
    opt = subprocess.Popen(["make", "-C", str(source), "--no-print-directory", "-j4", "xnet"], **quiet)
    debug = subprocess.Popen(["make", "-C", str(source), "--no-print-directory", "-j4", "CMODE=DEBUG", "xnet"], **quiet)
    assert opt.wait() == debug.wait() == 0
    def root_for(*arguments: str) -> pathlib.Path:
        result = run("make", "-C", str(source), "--no-print-directory", *arguments, "print-BUILD_ROOT", capture_output=True)
        return pathlib.Path(result.stdout.strip().split(" = ", 1)[1])
    opt_root = root_for()
    debug_root = root_for("CMODE=DEBUG")
    assert opt_root != debug_root and (opt_root / "bin/xnet").is_file() and (debug_root / "bin/xnet").is_file()
    first = subprocess.Popen(["make", "-C", str(source), "--no-print-directory", "-j4", "xnet"], **quiet)
    second = subprocess.Popen(["make", "-C", str(source), "--no-print-directory", "-j4", "xnet"], **quiet)
    assert first.wait() == second.wait() == 0
    assert json.loads((opt_root / "manifest.json").read_text(encoding="utf-8"))["digest"]
    assert not (source / "xnet").exists()
    # Concrete compatibility and rejection front ends are visible behavior.
    run("make", "-C", str(source), "--no-print-directory", "xnet_dense", **quiet)
    for target in ("xinab", "xnet_gpu"):
        result = subprocess.run(["make", "-C", str(source), "--no-print-directory", target], **quiet)
        assert result.returncode != 0
    invalid = subprocess.run(["make", "-C", str(source), "--no-print-directory", "GPU_MODE=ON", "GPU_BACKEND=HIP", "GPU_LAPACK_VER=CUBLAS", "xnet"], **quiet)
    assert invalid.returncode != 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
