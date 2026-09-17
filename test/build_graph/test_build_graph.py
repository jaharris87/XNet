#!/usr/bin/env python3
"""Focused effectiveness checks for XNet's predictable isolated Make graph."""
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "source"
DEPENDENCIES = ROOT / "tools/build/generate_fortran_deps.py"
CONFIG_RECORD = ROOT / "tools/build/config_record.py"


def source_products(root: pathlib.Path = SOURCE) -> set[str]:
    """Inventory generated names that must never appear in a source tree."""
    products = {
        "xnet",
        "xnse",
        "net_setup",
        "xnetd",
        "xnetd_mpi",
        "xnetm",
        "xnetm_mpi",
        "xnetp",
        "xnetp_mpi",
        "frontier_gpu_linalg_probe",
    }
    suffixes = {".o", ".mod", ".smod", ".d", ".lst", ".cub", ".ptx", ".i", ".T", ".diag", ".tmp"}
    return {
        str(path.relative_to(root))
        for path in root.rglob("*")
        if path.is_file() and (path.name in products or path.suffix in suffixes)
    }


def result(*command: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)


def run(*command: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, text=True, **kwargs)


def make(*arguments: str, source: pathlib.Path = SOURCE, **kwargs: object) -> subprocess.CompletedProcess[str]:
    return run("make", "-C", str(source), "--no-print-directory", *arguments, **kwargs)


def make_result(*arguments: str, source: pathlib.Path = SOURCE, **kwargs: object) -> subprocess.CompletedProcess[str]:
    return result("make", "-C", str(source), "--no-print-directory", *arguments, **kwargs)


def executable(path: pathlib.Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


def fake_toolchain(work: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    tools = work / "tools"
    tools.mkdir()
    log = work / "compiler.log"
    compiler = tools / "compiler"
    executable(
        compiler,
        "#!/bin/sh\n"
        "case \"${1:-}\" in\n"
        "  --version) echo 'XNet deterministic compiler 1.0'; exit 0;;\n"
        "  --showme:compile|--showme|-show|--cray-print-opts=all) echo \"$0 -DFIXTURE\"; exit 0;;\n"
        "  -print-file-name=*) echo \"${0%/*}/${1#*=}\"; exit 0;;\n"
        "esac\n"
        "printf '%s\\n' \"$*\" >> \"$XNET_FAKE_LOG\"\n"
        "[ -z \"${XNET_FAKE_SOURCE_PRODUCT:-}\" ] || : > \"$XNET_FAKE_SOURCE_PRODUCT\"\n"
        "case \"$*\" in *xnet_types.f90*) [ -z \"${XNET_FAKE_DELAY:-}\" ] || sleep \"$XNET_FAKE_DELAY\";; esac\n"
        "out=; previous=\n"
        "for argument in \"$@\"; do [ \"$previous\" != -o ] || out=$argument; previous=$argument; done\n"
        "[ -z \"$out\" ] || { mkdir -p \"${out%/*}\"; : > \"$out\"; }\n",
    )
    for name in ("ftn", "gfortran", "gcc", "g++", "cc", "nvcc"):
        (tools / name).symlink_to(compiler.name)
    (tools / "mpif.h").write_text("integer :: mpi_fixture\n", encoding="utf-8")
    return tools, log


def fake_args(tools: pathlib.Path) -> list[str]:
    return [
        f"FC={tools / 'gfortran'}",
        f"CC={tools / 'gcc'}",
        f"CXX={tools / 'g++'}",
        f"LDR={tools / 'gfortran'}",
        f"NVCC={tools / 'nvcc'}",
    ]


def dependency_checks(work: pathlib.Path) -> None:
    sources = work / "sources"
    sources.mkdir()
    nested = sources / "nested.inc"
    first = sources / "first.inc"
    nested.write_text("use provider\n", encoding="utf-8")
    first.write_text("include 'nested.inc'\n", encoding="utf-8")
    provider = sources / "provider.f90"
    parent = sources / "parent.f90"
    child = sources / "child.f90"
    grandchild = sources / "grandchild.f90"
    consumer = sources / "consumer.f90"
    provider.write_text("module provider\nend module provider\n", encoding="utf-8")
    parent.write_text("module parent\nend module parent\n", encoding="utf-8")
    child.write_text("submodule(parent) child\nend submodule child\n", encoding="utf-8")
    grandchild.write_text("submodule(parent:child) grandchild\nend submodule grandchild\n", encoding="utf-8")
    consumer.write_text("module consumer\ninclude 'first.inc'\nuse external_mod\nend module consumer\n", encoding="utf-8")
    modules = work / "modules"
    modules.mkdir()
    (modules / "external_mod.mod").write_bytes(b"fixture")
    dep = work / "dep/fortran.d"
    mappings: list[str] = []
    for source in (consumer, grandchild, child, parent, provider):
        mappings.extend(("--mapping", f"{work / (source.stem + '.o')}={source}"))
    run(
        sys.executable,
        str(DEPENDENCIES),
        "--output",
        str(dep),
        *mappings,
        "--include-dir",
        str(sources),
        "--external-module-dir",
        str(modules),
    )
    text = dep.read_text(encoding="utf-8")
    dep_rule = next(line for line in text.splitlines() if line.startswith(str(dep)))
    assert str(first.resolve()) in dep_rule and str(nested.resolve()) in dep_rule
    assert f"{work / 'consumer.o'}: {work / 'provider.o'}" in text
    assert str(first.resolve()) in text and str(nested.resolve()) in text
    assert f"{work / 'child.o'}: {work / 'parent.o'}" in text
    assert f"{work / 'grandchild.o'}: {work / 'child.o'}" in text

    missing = sources / "missing.f90"
    missing.write_text("module missing\nuse absent\nend module missing\n", encoding="utf-8")
    rejected = result(
        sys.executable,
        str(DEPENDENCIES),
        "--output",
        str(dep),
        "--mapping",
        f"{work / 'missing.o'}={missing}",
    )
    assert rejected.returncode and "missing provider" in rejected.stderr
    duplicate = sources / "duplicate.f90"
    duplicate.write_text("module provider\nend module provider\n", encoding="utf-8")
    rejected = result(
        sys.executable,
        str(DEPENDENCIES),
        "--output",
        str(dep),
        "--mapping",
        f"{work / 'provider.o'}={provider}",
        "--mapping",
        f"{work / 'duplicate.o'}={duplicate}",
    )
    assert rejected.returncode and "duplicate provider" in rejected.stderr
    bad_include = sources / "bad.f90"
    bad_include.write_text("include 'absent.inc'\n", encoding="utf-8")
    rejected = result(
        sys.executable,
        str(DEPENDENCIES),
        "--output",
        str(dep),
        "--mapping",
        f"{work / 'bad.o'}={bad_include}",
    )
    assert rejected.returncode and "includes missing file" in rejected.stderr


def config_and_cray_checks(work: pathlib.Path) -> None:
    record = work / "atomic/config.txt"
    environment = os.environ.copy()
    environment["CFG"] = "quoted macro='a  b'"
    command = [
        sys.executable,
        str(CONFIG_RECORD),
        "--output",
        str(record),
        "--environment",
        "CFG=FLAGS",
    ]
    run(*command, env=environment)
    run(*command, env=environment)
    assert record.read_text(encoding="utf-8") == "XNET_CONFIG_SCHEMA=1\nFLAGS=quoted macro='a  b'\n"
    changed = environment.copy()
    changed["CFG"] = "quoted macro='a b'"
    rejected = result(*command, env=changed)
    assert rejected.returncode and "FLAGS" in rejected.stderr
    newline = environment.copy()
    newline["CFG"] = "first\nsecond"
    rejected = result(*command, env=newline)
    assert rejected.returncode and "unrepresentable config field FLAGS" in rejected.stderr

    retained = work / "cray-retained.f90"
    source = work / "fixture.F90"
    source.write_text("#define VALUE 7\nmodule fixture\ninteger :: n = VALUE\nend module fixture\n", encoding="utf-8")
    run(
        str(SOURCE / "crayftn_cpp.sh"),
        "-DSECOND=2",
        str(source),
        env={**os.environ, "XNET_CPP_OUTPUT": str(retained), "XNET_CPP": "cpp", "XNET_CRAY_FTN": ":"},
    )
    assert "integer :: n = 7" in retained.read_text(encoding="utf-8")


def graph_checks(work: pathlib.Path) -> None:
    tools, log = fake_toolchain(work)
    environment = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}", "XNET_FAKE_LOG": str(log)}
    arguments = fake_args(tools)
    initial_source_products = source_products()
    inventory_fixture = work / "inventory-fixture"
    inventory_fixture.mkdir()
    assert not source_products(inventory_fixture)
    (inventory_fixture / "xnet").touch()
    assert source_products(inventory_fixture) == {"xnet"}
    xnet_only = work / "xnet-only"
    make(
        f"BUILD_DIR={xnet_only}",
        *arguments,
        "-j8",
        "xnet",
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    assert (xnet_only / "bin/xnet").is_file()
    assert not (xnet_only / "bin/xnse").exists() and not (xnet_only / "bin/net_setup").exists()
    assert not (xnet_only / "pp/source/nse_slice.f90").exists()
    assert not (xnet_only / "pp/source/net_setup.f90").exists()
    assert not (xnet_only / "pp/source/gpu_linalg_probe.f90").exists()
    database = make_result(f"BUILD_DIR={xnet_only}", *arguments, "-np", "xnet", env=environment)
    assert database.returncode == 0
    retained_target = f"{xnet_only}/pp/source/model_input_ascii.f90:"
    retained_rule = next(line for line in database.stdout.splitlines() if line.startswith(retained_target))
    assert f"{xnet_only}/pp/source/" not in retained_rule.split()
    object_target = f"{xnet_only}/obj/source/model_input_ascii.o:"
    object_rule = next(line for line in database.stdout.splitlines() if line.startswith(object_target))
    assert f"{xnet_only}/obj/source/" not in object_rule.split()

    build = work / "default"
    make(f"BUILD_DIR={build}", *arguments, "-j8", "all", env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for product in ("xnet", "xnse", "net_setup"):
        assert (build / "bin" / product).is_file()
    assert (build / "obj/source/xnet_types.o").is_file()
    assert (build / "obj/eos/actual_eos.o").is_file()
    assert (build / "obj/solver/xnet_jacobian_dense.o").is_file()
    assert (build / "obj/lapack/dgesv.o").is_file()
    config = (build / "config.txt").read_text(encoding="utf-8")
    assert "PARALLEL_PROVIDER=" in config and "xnet_parallel_stubs.F90" in config
    assert "EOS_PROVIDERS=" in config and "actual_eos.F90" in config
    assert "JACOBIAN_PROVIDER=" in config and "xnet_jacobian_dense.F90" in config
    assert "LAPACK_PROVIDER_SOURCES=" in config and "dgesv.f" in config
    default_link = next(
        line for line in log.read_text(encoding="utf-8").splitlines() if f"-o {build / 'bin/xnet'}." in line
    )
    for artifact in (
        build / "obj/source/xnet_parallel_stubs.o",
        build / "obj/eos/actual_eos.o",
        build / "obj/solver/xnet_jacobian_dense.o",
        build / "obj/lapack/dgesv.o",
    ):
        assert str(artifact) in default_link.split()
    for competing in (
        build / "obj/source/xnet_parallel.o",
        build / "obj/eos/xnet_eos_bahcall.o",
        build / "obj/solver/xnet_jacobian_MA48.o",
    ):
        assert str(competing) not in default_link.split()
    assert source_products() == initial_source_products
    before = log.stat().st_size
    make(f"BUILD_DIR={build}", *arguments, "xnet", env=environment, stdout=subprocess.DEVNULL)
    assert log.stat().st_size == before
    make(f"BUILD_DIR={build}", *arguments, "xnet_dense", env=environment, stdout=subprocess.DEVNULL)

    helmholtz = work / "helm-provider"
    helmholtz.mkdir()
    vector_include = helmholtz / "vector_eos.dek"
    vector_include.write_text("integer :: fixture_vector\n", encoding="utf-8")
    nested_helm_include = helmholtz / "nested_helm.dek"
    nested_helm_include.write_text("integer :: nested_fixture\n", encoding="utf-8")
    (helmholtz / "helmholtz.F90").write_text(
        "module helmholtz_fixture\ninclude 'nested_helm.dek'\nend module helmholtz_fixture\n",
        encoding="utf-8",
    )
    positive_rows = [
        ("mpi", ["MPI_MODE=ON"], ["obj/source/xnet_parallel.o"], ["xnet_parallel.F90"]),
        ("bahcall", ["EOS=BAHCALL"], ["obj/eos/xnet_eos_bahcall.o"], ["xnet_eos_bahcall.F90"]),
        (
            "helmholtz",
            ["EOS=HELMHOLTZ", f"HELMHOLTZ_PATH={helmholtz}"],
            ["obj/eos/xnet_eos_helm.o", "obj/eos/helmholtz.o"],
            ["xnet_eos_helm.F90", "helmholtz.F90"],
        ),
        (
            "cuda",
            ["GPU_MODE=ON", "GPU_BACKEND=CUDA", "GPU_LAPACK_VER=CUBLAS", "GPU_TARGET=Pascal", "OPENACC_MODE=ON"],
            ["obj/gpu/cudaf.o", "obj/gpu/cublasf.o", "obj/gpu/openaccf.o"],
            ["cudaf.F90", "cublasf.F90", "openaccf.F90"],
        ),
        (
            "pardiso",
            ["MATRIX_SOLVER=PARDISO", "LAPACK_VER=MKL", "MKL_LIBS=-lmkl_fixture"],
            ["obj/solver/xnet_jacobian_PARDISO_MKL.o"],
            ["xnet_jacobian_PARDISO_MKL.F90", "-lmkl_fixture"],
        ),
    ]
    for name, selectors, artifacts, providers in positive_rows:
        selected = work / name
        line_count = len(log.read_text(encoding="utf-8").splitlines())
        completed = make_result(
            f"BUILD_DIR={selected}",
            *arguments,
            *selectors,
            "-j8",
            "xnet",
            env=environment,
        )
        assert completed.returncode == 0, (name, completed.stdout, completed.stderr)
        link = next(
            line
            for line in log.read_text(encoding="utf-8").splitlines()[line_count:]
            if f"-o {selected / 'bin/xnet'}." in line
        )
        for artifact in artifacts:
            assert (selected / artifact).is_file()
            assert str(selected / artifact) in link.split()
        selected_config = (selected / "config.txt").read_text(encoding="utf-8")
        for provider in providers:
            assert provider in selected_config or provider in link.split()

    helm_build = work / "helmholtz"
    before = len(log.read_text(encoding="utf-8").splitlines())
    old_time = vector_include.stat().st_mtime_ns
    time.sleep(0.02)
    vector_include.write_text("use xnet_flux\ninteger :: fixture_vector\n", encoding="utf-8")
    os.utime(vector_include, None)
    try:
        make(
            f"BUILD_DIR={helm_build}",
            *arguments,
            "EOS=HELMHOLTZ",
            f"HELMHOLTZ_PATH={helmholtz}",
            "-j8",
            "xnet",
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        new_log = log.read_text(encoding="utf-8").splitlines()[before:]
        assert any(f"-I{helmholtz}" in line and "pp/eos/xnet_eos_helm.f90" in line for line in new_log)
        helm_dep = (helm_build / "dep/fortran.d").read_text(encoding="utf-8")
        helm_rule = next(line for line in helm_dep.splitlines() if "obj/eos/xnet_eos_helm.o:" in line)
        assert "obj/source/xnet_flux.o" in helm_rule
    finally:
        vector_include.write_text("integer :: fixture_vector\n", encoding="utf-8")
        os.utime(vector_include, ns=(old_time, old_time))

    mismatch_cases = [
        ["FC=/bin/false"],
        ["FFLAGS=-DFIXTURE=one"],
        ["MPI_MODE=ON"],
        ["EOS=BAHCALL"],
        ["MATRIX_SOLVER=PARDISO", "LAPACK_VER=MKL", "MKL_LIBS=-lmkl_fixture"],
        ["LAPACK_VER=ATLAS"],
        ["GPU_MODE=ON", "GPU_BACKEND=CUDA", "GPU_LAPACK_VER=CUBLAS", "GPU_TARGET=Pascal", "OPENACC_MODE=ON"],
    ]
    module_dir = work / "external-modules"
    module_dir.mkdir()
    (module_dir / "site_module.mod").write_bytes(b"fixture")
    mismatch_cases.append([f"XNET_EXTERNAL_MODULE_DIRS={module_dir}"])
    for changed in mismatch_cases:
        changed_names = {item.split("=", 1)[0] for item in changed}
        unchanged_arguments = [item for item in arguments if item.split("=", 1)[0] not in changed_names]
        completed = make_result(
            f"BUILD_DIR={build}", *unchanged_arguments, *changed, "print-XNET_EXE", env=environment
        )
        assert completed.returncode and "incompatible BUILD_DIR configuration" in completed.stderr, (
            changed,
            completed.returncode,
            completed.stdout,
            completed.stderr,
        )

    whitespace = work / "whitespace"
    first_flags = "FFLAGS=-DNAME='a b'"
    second_flags = "FFLAGS=-DNAME='a  b'"
    make(f"BUILD_DIR={whitespace}", *arguments, first_flags, "print-XNET_EXE", env=environment)
    completed = make_result(f"BUILD_DIR={whitespace}", *arguments, second_flags, "print-XNET_EXE", env=environment)
    assert completed.returncode and "FFLAGS" in completed.stderr

    invalid = [
        (("PE_ENV=UNKNOWN", "xnet"), "unsupported PE_ENV"),
        (("LAPACK_VER=ACML", "xnet"), "unsupported or unwired LAPACK_VER"),
        (("LAPACK_VER=LIBSCIACC", "xnet"), "unsupported or unwired LAPACK_VER"),
        (
            ("GPU_MODE=ON", "GPU_BACKEND=CUDA", "GPU_LAPACK_VER=CUBLAS", "GPU_TARGET=Ampere", "OPENACC_MODE=ON", "xnet"),
            "broken sm80 mapping",
        ),
        (("xinab",), "xinab is unsupported"),
        (("xnet_gpu",), "xnet_gpu is unsupported"),
        (("frontier_gpu_linalg_probe",), "requires exact Frontier"),
        ((f"XNET_EXTERNAL_MODULE_DIRS={work / 'absent-modules'}", "xnet"), "external module directory does not exist"),
        (("MATRIX_SOLVER=MA41", "xnet"), "selected provider source does not exist"),
        ((f"MPI_SRC={SOURCE / 'xnet_parallel_stubs.F90'}", "MPI_MODE=ON", "xnet"), "provider variables are internal"),
        ((f"EOS_SRC={SOURCE / 'xnet_eos_bahcall.F90'}", "EOS=STARKILLER", "xnet"), "provider variables are internal"),
        (("LAPACK_SRC=", "xnet"), "provider variables are internal"),
        (("SOLVER_SRC=", "xnet"), "provider variables are internal"),
        ((f"BUILD_DIR={work / 'invalid-base'}", f"BUILD_BASE={work / 'invalid-base'}", "xnet"), "BUILD_DIR may not equal BUILD_BASE"),
        ((f"BUILD_DIR={work / 'reserved.xnet-lock'}", "xnet"), "names ending in .xnet-lock are reserved"),
        ((f"BUILD_DIR={ROOT / '.xnet-build-gate'}", "xnet"), "may not equal the global acquisition gate"),
        (("clean", "xnet"), "clean targets cannot be combined"),
        (("xnet_dense", "xnet_MA48"), "select at most one solver compatibility target"),
        (("MATRIX_SOLVER=MA48", "xnet_dense"), "conflicts with MATRIX_SOLVER"),
    ]
    for case, diagnostic in invalid:
        before = log.stat().st_size
        completed = make_result(f"BUILD_DIR={work / 'invalid'}", *arguments, *case, env=environment)
        assert completed.returncode and diagnostic in completed.stderr, (case, completed.stderr)
        assert log.stat().st_size == before

    for name, extra, diagnostic in (
        ("missing-module", ["XNET_EXTERNAL_MODULES="], "uses missing provider module/submodule"),
    ):
        before = log.stat().st_size
        completed = make_result(
            f"BUILD_DIR={work / name}", *arguments, *extra, "-j8", "xnet", env=environment
        )
        assert completed.returncode and diagnostic in completed.stderr, completed.stderr
        assert log.stat().st_size == before

    source_mutation = SOURCE / "xnet"
    assert not source_mutation.exists()
    mutation_environment = {**environment, "XNET_FAKE_SOURCE_PRODUCT": str(source_mutation)}
    try:
        make(
            f"BUILD_DIR={work / 'source-product-mutation'}",
            *arguments,
            "-j8",
            "xnet",
            env=mutation_environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        assert source_products() != initial_source_products
    finally:
        source_mutation.unlink(missing_ok=True)
    assert source_products() == initial_source_products

    # Exact Frontier selectors exercise retained Cray output, HIP/ROCm providers,
    # and the qualification-only artifact without claiming a real facility build.
    frontier = work / "frontier"
    hipfort = work / "hipfort"
    hipfort_modules = hipfort / "include/hipfort/amdgcn"
    hipfort_modules.mkdir(parents=True)
    for module in (
        "hipfort_check",
        "hipfort",
        "hipfort_hipblas_enums",
        "hipfort_hipblas",
        "hipfort_rocblas_enums",
        "hipfort_rocblas",
        "hipfort_rocsparse_enums",
        "hipfort_rocsparse",
        "hipfort_rocsolver",
    ):
        (hipfort_modules / f"{module}.mod").write_bytes(b"fixture")
    rocm = work / "rocm"
    (rocm / "include").mkdir(parents=True)
    (rocm / "lib").mkdir()
    frontier_args = [
        f"BUILD_DIR={frontier}",
        "PE_ENV=CRAY",
        "MACHINE=frontier",
        "CMODE=OPT",
        "MPI_MODE=OFF",
        "OPENMP_MODE=OFF",
        "GPU_MODE=ON",
        "GPU_BACKEND=HIP",
        "GPU_LAPACK_VER=ROCM",
        "OPENMP_OL_MODE=ON",
        "OPENACC_MODE=OFF",
        "EOS=STARKILLER",
        "MATRIX_SOLVER=dense",
        "LAPACK_VER=LIBSCI",
        f"HIPFORT_DIR={hipfort}",
        f"ROCM_DIR={rocm}",
        f"XNET_CRAY_FTN={tools / 'ftn'}",
        *arguments,
    ]
    make(*frontier_args, "-j8", "frontier_gpu_linalg_probe", env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert (frontier / "bin/frontier_gpu_linalg_probe").is_file()
    frontier_config = (frontier / "config.txt").read_text(encoding="utf-8")
    assert "hipf.F90" in frontier_config and "rocsolverf.F90" in frontier_config

    # Distinct build directories may proceed together.
    left = subprocess.Popen(
        ["make", "-C", str(SOURCE), "--no-print-directory", f"BUILD_DIR={work / 'left'}", *arguments, "-j8", "xnet"],
        env=environment,
        stdout=subprocess.DEVNULL,
    )
    right = subprocess.Popen(
        ["make", "-C", str(SOURCE), "--no-print-directory", f"BUILD_DIR={work / 'right'}", *arguments, "-j8", "xnet"],
        env=environment,
        stdout=subprocess.DEVNULL,
    )
    assert left.wait() == 0 and right.wait() == 0

    # A delayed provider proves same-directory prompt rejection and retry.
    delayed = work / "delayed"
    delayed_environment = {**environment, "XNET_FAKE_DELAY": "2"}
    delayed_selection = [f"BUILD_BASE={work}", "BUILD_NAME=delayed"]
    first = subprocess.Popen(
        ["make", "-C", str(SOURCE), "--no-print-directory", *delayed_selection, *arguments, "-j8", "xnet"],
        env=delayed_environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    lock = pathlib.Path(str(delayed) + ".xnet-lock")
    deadline = time.monotonic() + 20
    while not lock.is_dir() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert lock.is_dir()
    rejected = make_result(*delayed_selection, *arguments, "xnet", env=environment)
    assert rejected.returncode and "BUILD_DIR is busy" in rejected.stderr
    clean_all = make_result(f"BUILD_BASE={work}", "CONFIRM_CLEAN_ALL=yes", "clean-all", env=environment)
    assert clean_all.returncode and "build lock exists" in clean_all.stderr
    assert first.wait() == 0
    make(*delayed_selection, *arguments, "xnet", env=environment, stdout=subprocess.DEVNULL)

    # The acquisition gate is repository-stable even when BUILD_BASE differs.
    clean_base = work / "cross-clean-base"
    cross_build = clean_base / "cross"
    cross_environment = {**environment, "XNET_FAKE_DELAY": "2"}
    cross = subprocess.Popen(
        [
            "make",
            "-C",
            str(SOURCE),
            "--no-print-directory",
            f"BUILD_BASE={work / 'unrelated-base'}",
            f"BUILD_DIR={cross_build}",
            *arguments,
            "-j8",
            "xnet",
        ],
        env=cross_environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    cross_lock = pathlib.Path(str(cross_build) + ".xnet-lock")
    deadline = time.monotonic() + 20
    while not cross_lock.is_dir() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert cross_lock.is_dir()
    rejected = make_result(f"BUILD_BASE={clean_base}", "CONFIRM_CLEAN_ALL=yes", "clean-all", env=environment)
    assert rejected.returncode and str(cross_lock) in rejected.stderr
    assert cross.wait() == 0
    assert source_products() == initial_source_products


def clean_and_archive_checks(work: pathlib.Path) -> None:
    base = work / "clean-base"
    unmarked = base / "unmarked"
    unmarked.mkdir(parents=True)
    (unmarked / "keep").write_text("keep", encoding="utf-8")
    rejected = make_result(f"BUILD_BASE={base}", "BUILD_NAME=unmarked", "clean")
    assert rejected.returncode and "unmarked" in rejected.stderr and (unmarked / "keep").is_file()
    symlink = base / "link"
    target = work / "outside"
    target.mkdir()
    symlink.symlink_to(target, target_is_directory=True)
    rejected = make_result(f"BUILD_BASE={base}", "BUILD_NAME=link", "clean")
    assert rejected.returncode and "symlink" in rejected.stderr
    rejected = make_result(f"BUILD_BASE={base}", "BUILD_NAME=link", "print-XNET_EXE")
    assert rejected.returncode and "BUILD_DIR may not be a symlink" in rejected.stderr
    assert not (target / "config.txt").exists()

    marked = base / "marked"
    marked.mkdir()
    (marked / "config.txt").write_text("XNET_CONFIG_SCHEMA=1\n", encoding="utf-8")
    stale = pathlib.Path(str(marked) + ".xnet-lock")
    stale.mkdir()
    (stale / "owner").write_text("stale fixture\n", encoding="utf-8")
    rejected = make_result(f"BUILD_BASE={base}", "CONFIRM_CLEAN_ALL=yes", "clean-all")
    assert rejected.returncode and "build lock exists" in rejected.stderr and marked.is_dir()
    shutil.rmtree(stale)

    hidden = base / ".active"
    hidden.mkdir()
    (hidden / "config.txt").write_text("XNET_CONFIG_SCHEMA=1\n", encoding="utf-8")
    hidden_lock = pathlib.Path(str(hidden) + ".xnet-lock")
    hidden_lock.mkdir()
    rejected = make_result(f"BUILD_BASE={base}", "CONFIRM_CLEAN_ALL=yes", "clean-all")
    assert rejected.returncode and str(hidden_lock) in rejected.stderr and hidden.is_dir()
    hidden_lock.rmdir()

    parent = base / "parent"
    parent.mkdir()
    (parent / "config.txt").write_text("XNET_CONFIG_SCHEMA=1\n", encoding="utf-8")
    nested_lock = parent / "nested.xnet-lock"
    holder = subprocess.Popen(
        [
            str(ROOT / "tools/build/xnet_lock.sh"),
            str(ROOT / ".xnet-build-gate"),
            str(nested_lock),
            "sleep",
            "2",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + 20
    while not nested_lock.is_dir() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert nested_lock.is_dir()
    rejected = make_result(f"BUILD_BASE={base}", "CONFIRM_CLEAN_ALL=yes", "clean-all")
    assert rejected.returncode and str(nested_lock) in rejected.stderr and parent.is_dir()
    assert holder.wait() == 0
    make(f"BUILD_BASE={base}", "CONFIRM_CLEAN_ALL=yes", "clean-all")
    assert not marked.exists() and not parent.exists() and unmarked.exists() and symlink.is_symlink()

    independent = base / "independent"
    independent.mkdir()
    (independent / "config.txt").write_text("XNET_CONFIG_SCHEMA=1\nPE_ENV=GNU\n", encoding="utf-8")
    make(f"BUILD_BASE={base}", "BUILD_NAME=independent", "PE_ENV=UNKNOWN", "PYTHON=/bin/false", "clean")
    assert not independent.exists()

    stale_build = base / "stale-build"
    stale_lock = pathlib.Path(str(stale_build) + ".xnet-lock")
    stale_lock.mkdir()
    (stale_lock / "owner").write_text("stale fixture\n", encoding="utf-8")
    rejected = make_result(f"BUILD_BASE={base}", "BUILD_NAME=stale-build", "print-XNET_EXE")
    assert rejected.returncode and "BUILD_DIR is busy (stale fixture)" in rejected.stderr
    shutil.rmtree(stale_lock)
    make(f"BUILD_BASE={base}", "BUILD_NAME=stale-build", "print-XNET_EXE")

    # Represent the other deterministic race order: clean-all owns the global
    # acquisition gate before a new build attempts to acquire its directory lock.
    slow_tools = work / "slow-tools"
    slow_tools.mkdir()
    executable(slow_tools / "rm", "#!/bin/sh\nsleep 1\nexec /bin/rm \"$@\"\n")
    clean_target = base / "clean-target"
    clean_target.mkdir()
    (clean_target / "config.txt").write_text("XNET_CONFIG_SCHEMA=1\n", encoding="utf-8")
    gate = ROOT / ".xnet-build-gate"
    cleaner = subprocess.Popen(
        [
            "make",
            "-C",
            str(SOURCE),
            "--no-print-directory",
            f"BUILD_BASE={base}",
            "CONFIRM_CLEAN_ALL=yes",
            "clean-all",
        ],
        env={**os.environ, "PATH": f"{slow_tools}{os.pathsep}{os.environ['PATH']}"},
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + 20
    while not gate.is_dir() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert gate.is_dir()
    make(f"BUILD_BASE={base}", "BUILD_NAME=race", "print-XNET_EXE", stdout=subprocess.DEVNULL)
    assert cleaner.wait() == 0 and not clean_target.exists() and (base / "race/config.txt").is_file()

    # An acquisition gate that outlives its owner is never guessed stale.
    # The diagnostic tells the caller to verify and remove it explicitly.
    gate.mkdir()
    rejected = make_result(
        f"BUILD_BASE={base}", "BUILD_NAME=stale-gate", "print-XNET_EXE", env={**os.environ, "XNET_GATE_RETRIES": "1"}
    )
    assert rejected.returncode and "remove a confirmed stale gate" in rejected.stderr
    gate.rmdir()

    archive = work / "archive"
    shutil.copytree(
        ROOT,
        archive,
        ignore=shutil.ignore_patterns(".git", "__pycache__", "*.o", "*.mod", "*.smod"),
    )
    assert not (archive / ".git").exists()
    make("BUILD_NAME=gitless", "print-XNET_EXE", source=archive / "source")
    config = archive / "build/gitless/config.txt"
    assert config.is_file() and f"SOURCE_ROOT={archive.resolve()}" in config.read_text(encoding="utf-8")

    duplicate_source = archive / "source/net.F90"
    duplicate_source.write_text(
        "module xnet_types\nend module xnet_types\n" + duplicate_source.read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    duplicate = make_result(
        "BUILD_NAME=duplicate-provider",
        "FC=/bin/false",
        "CC=/bin/false",
        "CXX=/bin/false",
        "LDR=/bin/false",
        "-j8",
        "xnet",
        source=archive / "source",
    )
    assert duplicate.returncode and "duplicate provider for module/submodule xnet_types" in duplicate.stderr


def real_incremental_checks() -> None:
    build = ROOT / "build/effectiveness-real"
    make(f"BUILD_DIR={build}", "clean")
    make(f"BUILD_DIR={build}", "-j8", "xnet", stdout=subprocess.DEVNULL)
    executable_path = build / "bin/xnet"
    types_object = build / "obj/source/xnet_types.o"
    constants_object = build / "obj/source/xnet_constants.o"
    lapack_object = build / "obj/lapack/dgesv.o"
    module_files = list(build.rglob("*.mod")) + list(build.rglob("*.smod"))
    assert executable_path.is_file() and module_files
    assert all(path.parent == build / "mod" for path in module_files)
    before = (types_object.stat().st_mtime_ns, constants_object.stat().st_mtime_ns)
    source = SOURCE / "xnet_types.F90"
    old_time = source.stat().st_mtime_ns
    time.sleep(0.02)
    os.utime(source, None)
    try:
        make(f"BUILD_DIR={build}", "-j8", "xnet", stdout=subprocess.DEVNULL)
        assert types_object.stat().st_mtime_ns > before[0]
        assert constants_object.stat().st_mtime_ns > before[1]
    finally:
        os.utime(source, ns=(old_time, old_time))

    macro = SOURCE / "xnet_macros.fh"
    pp = build / "pp/source/xnet_types.f90"
    old_time = macro.stat().st_mtime_ns
    before_pp = pp.stat().st_mtime_ns
    time.sleep(0.02)
    os.utime(macro, None)
    try:
        make(f"BUILD_DIR={build}", "-j8", "xnet", stdout=subprocess.DEVNULL)
        assert pp.stat().st_mtime_ns > before_pp
    finally:
        os.utime(macro, ns=(old_time, old_time))

    build_logic = SOURCE / "Makefile.production"
    old_time = build_logic.stat().st_mtime_ns
    before_lapack = lapack_object.stat().st_mtime_ns
    time.sleep(0.02)
    os.utime(build_logic, None)
    try:
        make(f"BUILD_DIR={build}", "-j8", "xnet", stdout=subprocess.DEVNULL)
        assert lapack_object.stat().st_mtime_ns > before_lapack
    finally:
        os.utime(build_logic, ns=(old_time, old_time))


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="xnet-build-graph-") as temporary:
        work = pathlib.Path(temporary)
        build = work / "gnu"
        completed = make_result(f"BUILD_DIR={build}", "-j4", "xnet", "xnse", "net_setup")
        assert completed.returncode == 0, completed.stderr
        assert "python" not in (completed.stdout + completed.stderr).lower()
        assert (build / "bin" / "xnet").is_file()
        assert (build / "bin" / "xnse").is_file()
        assert (build / "bin" / "net_setup").is_file()
        mismatch = make_result(f"BUILD_DIR={build}", "CMODE=DEBUG", "xnet")
        assert mismatch.returncode != 0 and "incompatible BUILD_DIR configuration" in mismatch.stderr
        cleaned = make_result(f"BUILD_DIR={build}", "clean")
        assert cleaned.returncode == 0 and not build.exists()
    print("XNet isolated build graph effectiveness checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
