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
        "#define XDIR $omp\n"
        "#define XPRIVATE(...) private(__VA_ARGS__)\n"
        "Integer Function probe()\n"
        "Implicit None\n"
        "!XDIR declare target\n"
        'character(len=*), parameter :: joined = "a" // "b"\n'
        "!XDIR parallel XPRIVATE(first,second)\n"
        "probe = 0\n"
        "End Function probe\n",
        encoding="utf-8",
    )
    capture = tmp_path / "preprocessed.f90"
    compiler = tmp_path / "capture-compiler"
    compiler.write_text(
        "#!/bin/bash\n"
        "for argument in \"$@\"; do source_file=$argument; done\n"
        "cp \"${source_file}\" \"${XNET_CAPTURE}\"\n",
        encoding="utf-8",
    )
    compiler.chmod(0o755)
    environment = os.environ.copy()
    environment.update(
        {"XNET_CRAY_FTN": str(compiler), "XNET_CAPTURE": str(capture)}
    )
    wrapper = FRONTIER_DIRECTORY.parents[2] / "source" / "crayftn_cpp.sh"
    completed = subprocess.run(
        [str(wrapper), "-eZ", "-c", str(source), "-o", str(tmp_path / "probe.o")],
        capture_output=True,
        text=True,
        env=environment,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    preprocessed = capture.read_text(encoding="utf-8")
    assert 'joined = "a" // "b"' in preprocessed
    assert preprocessed.index("Implicit None") < preprocessed.index("!$omp declare target")
    assert "!$omp parallel private(first,second)" in preprocessed


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
