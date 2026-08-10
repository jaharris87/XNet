"""Focused effectiveness tests for the manual Frontier qualification package."""

from dataclasses import replace
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest


FRONTIER_DIRECTORY = Path(__file__).with_name("frontier")
sys.path.insert(0, str(FRONTIER_DIRECTORY))

from frontier_qualification import (  # noqa: E402
    CPU_BUILD_VARIABLES,
    GPU_BUILD_VARIABLES,
    FrontierFailure,
    compare_endpoint_states,
    inventory_regular_files,
    load_policy,
    parse_linalg_probe,
    validate_manifest,
)
from submit_frontier import classify_submission_failure  # noqa: E402
from xnet_regression import ALPHA_SPECIES, FinalState, SolverCounters  # noqa: E402


POLICY = FRONTIER_DIRECTORY / "comparison_policy.json"
HASH = "a" * 64
SOURCE_SHA = "b" * 40


def _state(zone: int) -> FinalState:
    fractions = {species: 0.0 for species in ALPHA_SPECIES}
    fractions.update({"si28": 0.4, "s32": 0.3, "ni56": 0.3})
    return FinalState(
        zone=zone,
        step=10,
        target_time=1.0,
        time=1.0,
        temperature_gk=5.0,
        density=1.0e8,
        electron_fraction=0.5,
        mass_fractions=fractions,
        counters=SolverCounters(10, 20, 20, 21, 21),
    )


def _manifest() -> dict[str, object]:
    artifact = {"path": "evidence.txt", "size": 1, "sha256": HASH}
    executable = {
        "artifact": "bin/xnet",
        "size": 1,
        "sha256": HASH,
        "link_evidence": "build/link.txt",
    }
    return {
        "schema": "xnet-frontier-qualification-v1",
        "status": "passed",
        "failure": None,
        "source": {
            "sha": SOURCE_SHA,
            "worktree_clean": True,
            "archive_sha256": HASH,
        },
        "environment": {
            "modules": [
                "PrgEnv-cray/1",
                "rocm/1",
                "craype-accel-amd-gfx90a",
                "hipfort/1",
            ],
            "gpu_model": "AMD Instinct MI250X",
        },
        "slurm": {"job_id": "123"},
        "builds": {
            "cpu": {
                "status": "passed",
                "variables": CPU_BUILD_VARIABLES,
                "executables": {"xnet": executable},
            },
            "gpu": {
                "status": "passed",
                "variables": GPU_BUILD_VARIABLES,
                "executables": {"xnet": executable},
            },
        },
        "inputs": [artifact],
        "checks": {
            "gpu_linalg": {
                "status": "passed",
                "offloaded": True,
                "data_present": True,
            },
            "partial_batch": {"status": "passed", "zones": list(range(1, 11))},
            "heat_sn160": {"status": "passed", "zones": list(range(1, 7))},
        },
        "artifact_inventory": [artifact],
        "started_at_utc": "2026-08-10T00:00:00+00:00",
        "finished_at_utc": "2026-08-10T00:01:00+00:00",
        "runtime_seconds": 60.0,
    }


def test_policy_accepts_identity_and_rejects_material_endpoint_perturbation() -> None:
    policy = load_policy(POLICY)
    reference = (_state(1),)
    result = compare_endpoint_states(reference, reference, policy, "identity")
    assert result["status"] == "passed"

    fractions = dict(reference[0].mass_fractions)
    fractions["si28"] += 1.0e-3
    fractions["s32"] -= 1.0e-3
    perturbed = (replace(reference[0], mass_fractions=fractions),)
    with pytest.raises(FrontierFailure, match="endpoint comparison failed"):
        compare_endpoint_states(perturbed, reference, policy, "perturbed")


def test_linalg_report_requires_device_offload_success_and_small_residuals() -> None:
    report = "\n".join(
        (
            "XNET_GPU_LINALG device_count    1",
            "XNET_GPU_LINALG device    0",
            "XNET_GPU_LINALG offloaded T",
            "XNET_GPU_LINALG data_present T",
            "XNET_GPU_LINALG batch    1 info    0 relative_residual   1.0E-16",
            "XNET_GPU_LINALG batch    2 info    0 relative_residual   2.0E-16",
            "XNET_GPU_LINALG status passed",
        )
    )
    assert parse_linalg_probe(report)["status"] == "passed"
    with pytest.raises(FrontierFailure, match="stayed on the host"):
        parse_linalg_probe(report.replace("offloaded T", "offloaded F"))
    with pytest.raises(FrontierFailure, match="solve data is not present"):
        parse_linalg_probe(report.replace("data_present T", "data_present F"))
    with pytest.raises(FrontierFailure, match="batch 2"):
        parse_linalg_probe(report.replace("2.0E-16", "2.0E-2"))
    with pytest.raises(FrontierFailure, match="batch 1"):
        parse_linalg_probe(report.replace("batch    1 info    0", "batch    1 info    3"))


def test_inventory_hashes_all_regular_outputs_but_not_staged_links(tmp_path: Path) -> None:
    (tmp_path / "nested").mkdir()
    (tmp_path / "nested" / "output").write_text("result\n", encoding="utf-8")
    (tmp_path / "link").symlink_to(tmp_path / "nested" / "output")
    inventory = inventory_regular_files(tmp_path)
    assert [item["path"] for item in inventory] == ["nested/output"]
    assert inventory[0]["size"] == 7


def test_manifest_validator_requires_complete_success_evidence() -> None:
    manifest = _manifest()
    validate_manifest(manifest)
    manifest["checks"]["partial_batch"]["zones"] = list(range(1, 10))
    with pytest.raises(FrontierFailure, match="partial-batch zones"):
        validate_manifest(manifest)

    manifest = _manifest()
    del manifest["checks"]["gpu_linalg"]["data_present"]
    with pytest.raises(FrontierFailure, match="linear-algebra evidence"):
        validate_manifest(manifest)


def test_failed_manifest_retains_classification_without_false_success() -> None:
    manifest = _manifest()
    manifest.update(
        {
            "status": "failed",
            "failure": {
                "category": "allocation",
                "phase": "slurm-step",
                "message": "GPU unavailable",
            },
            "environment": {},
            "builds": {},
            "inputs": [],
            "checks": {},
        }
    )
    validate_manifest(manifest, require_pass=False)
    with pytest.raises(FrontierFailure, match="status is not passed"):
        validate_manifest(manifest)


@pytest.mark.parametrize(
    ("message", "category"),
    (
        ("Invalid account or account/partition combination", "allocation"),
        ("Unable to contact slurm controller", "facility"),
        ("JOB CANCELLED AT DEADLINE", "queue"),
        ("unrecognized option", "submission"),
    ),
)
def test_submission_failures_are_classified(message: str, category: str) -> None:
    assert classify_submission_failure(message) == category


def test_manifest_schema_file_is_versioned_and_matches_runner() -> None:
    schema = json.loads(
        (FRONTIER_DIRECTORY / "manifest.schema.json").read_text(encoding="utf-8")
    )
    assert schema["properties"]["schema"]["const"] == _manifest()["schema"]


def test_cray_wrapper_preserves_fortran_and_expands_variadic_macros(
    tmp_path: Path,
) -> None:
    if shutil.which("cpp") is None:
        pytest.skip("system C preprocessor is unavailable")
    source = tmp_path / "probe.F90"
    source.write_text(
        '#include "xnet_macros.fh"\n'
        "Integer Function probe()\n"
        "Implicit None\n"
        "!XDIR declare target\n"
        'character(len=*), parameter :: joined = "a" // "b"\n'
        "integer :: first, second\n"
        "!XDIR XENTER_DATA XASYNC(1) &\n"
        "!XDIR XCOPYIN(probe)\n"
        "!XDIR XUPDATE XWAIT(1) &\n"
        "!XDIR XHOST(probe)\n"
        "!XDIR XWAIT(1)\n"
        "!XDIR parallel &\n"
        "!XDIR XPRESENT(probe) &\n"
        "!XDIR XPRIVATE(first,second)\n"
        "!XDIR XLOOP(1) XASYNC(1) &\n"
        "!XDIR XPRESENT(probe)\n"
        "Do first = 1, 1\n"
        "EndDo\n"
        "probe = 0\n"
        "End Function probe\n",
        encoding="utf-8",
    )
    capture = tmp_path / "preprocessed.f90"
    compiler = tmp_path / "capture-compiler"
    compiler.write_text(
        "#!/bin/bash\n"
        "for argument in \"$@\"; do source_file=$argument; done\n"
        "cp \"${source_file}\" \"${XNET_CAPTURE}\"\n"
        "printf '%s\\n' \"${source_file##*/}\" > \"${XNET_CAPTURE_NAME}\"\n",
        encoding="utf-8",
    )
    compiler.chmod(0o755)
    environment = os.environ.copy()
    environment.update(
        {
            "XNET_CRAY_FTN": str(compiler),
            "XNET_CAPTURE": str(capture),
            "XNET_CAPTURE_NAME": str(tmp_path / "source-name.txt"),
        }
    )
    wrapper = FRONTIER_DIRECTORY.parents[2] / "source" / "crayftn_cpp.sh"
    completed = subprocess.run(
        [
            str(wrapper),
            "-DXNET_OMP_OL",
            f"-I{FRONTIER_DIRECTORY.parents[2] / 'source'}",
            "-eZ",
            "-c",
            str(source),
            "-o",
            str(tmp_path / "probe.o"),
        ],
        capture_output=True,
        text=True,
        env=environment,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    assert (tmp_path / "source-name.txt").read_text(encoding="utf-8") == "probe.f90\n"
    preprocessed = capture.read_text(encoding="utf-8")
    normalized = "\n".join(" ".join(line.split()) for line in preprocessed.splitlines())
    assert 'joined = "a" // "b"' in preprocessed
    assert preprocessed.index("Implicit None") < preprocessed.index("!$omp declare target")
    assert "!$omp target enter data &" in normalized
    assert "!$omp target update &" in normalized
    assert "!$omp from(probe)" in preprocessed
    assert "!$omp parallel &" in normalized
    assert "!$omp private(first,second)" in preprocessed
    assert "!$omp target teams distribute parallel do simd collapse(1)" in normalized
    assert "!present" not in preprocessed
    assert "nowait" not in preprocessed
    assert "barrier" not in preprocessed
    assert "\n!$omp\n" not in preprocessed


def test_accelerator_routine_directives_follow_ordered_specification_statements() -> None:
    repository = FRONTIER_DIRECTORY.parents[2]
    source_files = list((repository / "source").glob("*.F90"))
    source_files.extend((repository / "tools" / "starkiller-helmholtz").glob("*.F90"))

    for source_file in source_files:
        lines = source_file.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if "XROUTINE_SEQ" not in line and "XROUTINE_VECTOR" not in line:
                continue
            for following in lines[index + 1 :]:
                statement = following.strip()
                if not statement or statement.startswith("!") or statement.startswith("#"):
                    continue
                assert not statement.lower().startswith(("use ", "implicit none")), (
                    f"{source_file}:{index + 1}: accelerator routine directive "
                    f"precedes {statement!r}"
                )
                break


def test_accelerator_clauses_use_backend_macros() -> None:
    repository = FRONTIER_DIRECTORY.parents[2]
    source_files = list((repository / "source").glob("*.F90"))
    source_files.extend((repository / "tools" / "starkiller-helmholtz").glob("*.F90"))

    for source_file in source_files:
        for line_number, line in enumerate(
            source_file.read_text(encoding="utf-8").splitlines(), start=1
        ):
            directive = line.strip()
            if not directive.startswith("!XDIR"):
                continue
            clause = directive.removeprefix("!XDIR").lstrip()
            assert not clause.startswith(("ASYNC(", "HOST(", "PRIVATE(")), (
                f"{source_file}:{line_number}: accelerator clause bypasses its "
                "backend macro"
            )


def test_openmp_device_pointer_helpers_query_mapped_addresses() -> None:
    if shutil.which("cpp") is None:
        pytest.skip("system C preprocessor is unavailable")
    repository = FRONTIER_DIRECTORY.parents[2]
    completed = subprocess.run(
        [
            "cpp",
            "-P",
            "-C",
            "-nostdinc",
            "-DXNET_OMP_OL",
            f"-I{repository / 'source'}",
            str(repository / "source" / "xnet_gpu.F90"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.count("omp_get_mapped_ptr( C_LOC( a )") == 3
    assert "use_device_ptr" not in completed.stdout


def test_openmp_rocm_batched_factor_and_solve_use_contiguous_strides() -> None:
    if shutil.which("cpp") is None:
        pytest.skip("system C preprocessor is unavailable")
    repository = FRONTIER_DIRECTORY.parents[2]
    completed = subprocess.run(
        [
            "cpp",
            "-P",
            "-C",
            "-nostdinc",
            "-DXNET_GPU",
            "-DXNET_HIP",
            "-DXNET_OMP_OL",
            "-DXNET_LA_ROCM",
            f"-I{repository / 'source'}",
            str(repository / "source" / "xnet_linalg.F90"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    batched_solve = completed.stdout.split("Subroutine LinearSolveBatched(", 1)[1]
    batched_solve = batched_solve.split("End Subroutine LinearSolveBatched", 1)[0]
    assert "Call LinearSolveBatched_ROCM_Strided" in batched_solve
    assert "Call LinearSolveBatched_GPU" not in batched_solve
    assert "target enter data" not in batched_solve
    strided_solve = completed.stdout.split(
        "Subroutine LinearSolveBatched_ROCM_Strided", 1
    )[1]
    strided_solve = strided_solve.split(
        "End Subroutine LinearSolveBatched_ROCM_Strided", 1
    )[0]
    assert "Call LUDecompBatched_ROCM_Strided" in strided_solve
    assert "Call LUBksubBatched_ROCM_Strided" in strided_solve

    strided_factor = completed.stdout.split(
        "Subroutine LUDecompBatched_ROCM_Strided", 1
    )[1]
    strided_factor = strided_factor.split(
        "End Subroutine LUDecompBatched_ROCM_Strided", 1
    )[0]
    assert "hipblasDgetrfStridedBatched" in strided_factor

    strided_bksub = completed.stdout.split(
        "Subroutine LUBksubBatched_ROCM_Strided", 1
    )[1]
    strided_bksub = strided_bksub.split(
        "End Subroutine LUBksubBatched_ROCM_Strided", 1
    )[0]
    assert "hipblasDgetrsStridedBatched" in strided_bksub

    factor = completed.stdout.split("Subroutine LUDecompBatched_GPU", 1)[1]
    factor = factor.split("End Subroutine LUDecompBatched_GPU", 1)[0]
    assert "Call LUDecompBatched_ROCM_Strided" in factor
    assert "hipblasDgetrfBatched" not in factor
    assert "dev_ptr( da(1) )" not in factor

    bksub = completed.stdout.split("Subroutine LUBksubBatched_GPU", 1)[1]
    bksub = bksub.split("End Subroutine LUBksubBatched_GPU", 1)[0]
    assert "Call LUBksubBatched_ROCM_Strided" in bksub
    assert "Call stream_sync( stream )" in bksub
    assert "hipblasDgetrsBatched" not in bksub
    assert "dev_ptr( da(1) )" not in bksub

    openacc = subprocess.run(
        [
            "cpp",
            "-P",
            "-C",
            "-nostdinc",
            "-DXNET_GPU",
            "-DXNET_HIP",
            "-DXNET_OACC",
            "-DXNET_LA_ROCM",
            f"-I{repository / 'source'}",
            str(repository / "source" / "xnet_linalg.F90"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert openacc.returncode == 0, openacc.stderr
    factor = openacc.stdout.split("Subroutine LUDecompBatched_GPU", 1)[1]
    factor = factor.split("End Subroutine LUDecompBatched_GPU", 1)[0]
    assert "hipblasDgetrfBatched" in factor
    assert "dev_ptr( da(1) )" in factor

    bksub = openacc.stdout.split("Subroutine LUBksubBatched_GPU", 1)[1]
    bksub = bksub.split("End Subroutine LUBksubBatched_GPU", 1)[0]
    assert "hipblasDgetrsBatched" in bksub
    assert "dev_ptr( da(1) )" in bksub


def test_helmholtz_allocatable_lifetime_matches_accelerator_model() -> None:
    if shutil.which("cpp") is None:
        pytest.skip("system C preprocessor is unavailable")
    repository = FRONTIER_DIRECTORY.parents[2]
    completed = subprocess.run(
        [
            "cpp",
            "-P",
            "-C",
            "-nostdinc",
            "-DXNET_GPU",
            "-DXNET_OMP_OL",
            f"-I{repository / 'source'}",
            str(repository / "tools" / "starkiller-helmholtz" / "actual_eos.F90"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    declarations = completed.stdout.split("contains", 1)[0]
    assert "!$omp declare target link(itmax, jtmax, d, t)" in declarations

    omp_eos_type = subprocess.run(
        [
            "cpp",
            "-P",
            "-C",
            "-nostdinc",
            "-DXNET_GPU",
            "-DXNET_OMP_OL",
            f"-I{repository / 'source'}",
            str(repository / "tools" / "starkiller-helmholtz" / "eos_type.F90"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert omp_eos_type.returncode == 0, omp_eos_type.stderr
    declarations = omp_eos_type.stdout.split("contains", 1)[0]
    assert (
        "!$omp declare target link(mintemp, maxtemp, mindens, maxdens)"
        in declarations
    )

    initialization = completed.stdout.split("subroutine actual_eos_init", 1)[1]
    initialization = initialization.split("end subroutine actual_eos_init", 1)[0]
    assert "!$omp target enter data" in initialization
    assert "map(to:itmax, jtmax, d, t)" in initialization
    assert "!$omp target update" not in initialization
    assert "map(alloc:" not in initialization
    assert "always" not in initialization

    finalization = completed.stdout.split("subroutine actual_eos_finalize", 1)[1]
    finalization = finalization.split("end subroutine actual_eos_finalize", 1)[0]
    assert "!$omp target exit data" in finalization
    assert "map(release:itmax, jtmax, d, t)" in finalization

    openacc = subprocess.run(
        [
            "cpp",
            "-P",
            "-C",
            "-nostdinc",
            "-DXNET_GPU",
            "-DXNET_OACC",
            f"-I{repository / 'source'}",
            str(repository / "tools" / "starkiller-helmholtz" / "actual_eos.F90"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert openacc.returncode == 0, openacc.stderr
    declarations = openacc.stdout.split("contains", 1)[0]
    assert "!$acc declare create(itmax, jtmax, d, t)" in declarations

    openacc_eos_type = subprocess.run(
        [
            "cpp",
            "-P",
            "-C",
            "-nostdinc",
            "-DXNET_GPU",
            "-DXNET_OACC",
            f"-I{repository / 'source'}",
            str(repository / "tools" / "starkiller-helmholtz" / "eos_type.F90"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert openacc_eos_type.returncode == 0, openacc_eos_type.stderr
    declarations = openacc_eos_type.stdout.split("contains", 1)[0]
    assert (
        "!$acc declare create(mintemp, maxtemp, mindens, maxdens)" in declarations
    )

    initialization = openacc.stdout.split("subroutine actual_eos_init", 1)[1]
    initialization = initialization.split("end subroutine actual_eos_init", 1)[0]
    assert "!$acc update" in initialization
    assert "!$acc device(itmax, jtmax, d, t)" in initialization
    assert "!$acc enter data" not in initialization

    finalization = openacc.stdout.split("subroutine actual_eos_finalize", 1)[1]
    finalization = finalization.split("end subroutine actual_eos_finalize", 1)[0]
    assert "!$acc exit data" not in finalization
