"""Check failure records through the batch runner's command-line entry point."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest


@pytest.mark.parametrize("timeout", [False, True])
def test_failed_command_keeps_output_and_record(tmp_path, monkeypatch, timeout):
    source = Path(__file__).with_name("run_host_batch_openmp_tests.py")
    spec = importlib.util.spec_from_file_location("batch_runner_under_test", source)
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    setup = tmp_path / "net_setup"
    setup.write_text(
        f"#!{sys.executable}\n"
        "import sys, time\n"
        "print('stdout before failure', flush=True)\n"
        "print('stderr before failure', file=sys.stderr, flush=True)\n"
        + ("time.sleep(10)\n" if timeout else "sys.exit(7)\n")
    )
    setup.chmod(0o700)
    consumer = tmp_path / "consumer"
    consumer.write_text("unused: the first preprocessor must stop the suite\n")
    archive = tmp_path / "libxnet.a"
    archive.write_bytes(b"unused archive for runner record test\n")
    config = tmp_path / "xnet-config.mk"
    config.write_text(f"XNET_FC := {sys.executable}\nXNET_ARCHIVE := {archive}\nXNET_CPPFLAGS := -DXNET_OMP\n")
    (tmp_path / "config.txt").write_text("OPENMP_MODE=ON\nPE_ENV=GNU\n")
    work_root = tmp_path / "runs"
    monkeypatch.setattr(sys, "argv", [str(source), "--root", str(source.parents[2]),
        "--consumer", str(consumer), "--library-config", str(config), "--net-setup", str(setup),
        "--work-dir", str(work_root)])
    original_run = subprocess.run

    def bounded_run(argv, **kwargs):
        if argv == [str(setup)]:
            # Use the real pipe/TimeoutExpired behavior with a harmless short-lived process.
            kwargs["timeout"] = 0.5
        return original_run(argv, **kwargs)

    monkeypatch.setattr(runner.subprocess, "run", bounded_run)
    if timeout:
        with pytest.raises(subprocess.TimeoutExpired):
            runner.main()
    else:
        with pytest.raises(RuntimeError, match="direct exit 7"):
            runner.main()
    work, = work_root.glob("host-batch-*")
    records = json.loads((work / "commands.json").read_text())
    record, = records
    assert record["argv"] == [str(setup)]
    assert record["cwd"] == str(work / "Data_alpha")
    assert record["OMP_NUM_THREADS"] == 1
    log = Path(record["log"])
    output = log.read_text()
    assert "stdout before failure" in output and "stderr before failure" in output
    assert record["log_sha256"] == hashlib.sha256(log.read_bytes()).hexdigest()
    if timeout:
        assert record["returncode"] is None and record["timeout_seconds"] == 0.5
        assert output.endswith("PROCESS_TIMEOUT_SECONDS 0.5\n")
        assert "PROCESS_EXIT_STATUS" not in output
    else:
        assert record["returncode"] == 7 and "timeout_seconds" not in record
        assert output.endswith("PROCESS_EXIT_STATUS 7\n")
    assert not (work / "worker-owners.json").exists()
    assert not (work / "SN160-be-heat1-parallel4").exists()


@pytest.mark.parametrize("scenario, expected_error", [
    ("valid", "direct exit 7"),
    ("empty", "expected one storage completion row"),
    ("missing", "expected one storage completion row"),
    ("wrong-capacity", "storage completion capacity/workers"),
    ("wrong-workers", "storage completion capacity/workers"),
    ("duplicate", "expected one storage completion row"),
])
def test_storage_completion_and_input_binding(tmp_path, monkeypatch, capsys, scenario, expected_error):
    source = Path(__file__).with_name("run_host_batch_openmp_tests.py")
    spec = importlib.util.spec_from_file_location("batch_runner_storage_test", source)
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    setup = tmp_path / "net_setup"
    setup.write_text(
        f"#!{sys.executable}\n"
        "from pathlib import Path\n"
        "for name in ('sunet', 'netwinv', 'nets3', 'nets4', 'match_data'):\n"
        "    Path(name).touch()\n"
    )
    consumer = tmp_path / "consumer"
    consumer.write_text(f"#!{sys.executable}\nimport sys\nsys.exit(7)\n")
    storage = tmp_path / "storage"
    storage.write_text(
        f"#!{sys.executable}\n"
        "import os, sys\n"
        f"scenario = {scenario!r}\n"
        "capacity, workers = int(sys.argv[2]), int(os.environ['OMP_NUM_THREADS'])\n"
        "if scenario == 'empty': sys.exit(0)\n"
        "if scenario == 'missing':\n"
        "    print('zero exit without storage completion')\n"
        "    sys.exit(0)\n"
        "if scenario == 'wrong-capacity': capacity += 1\n"
        "if scenario == 'wrong-workers': workers += 1\n"
        "row = f'PASS worker storage, capacity/workers: {capacity:5d}{workers:5d}'\n"
        "print(row)\n"
        "if scenario == 'duplicate': print(row)\n"
    )
    for executable in (setup, consumer, storage):
        executable.chmod(0o700)
    archive = tmp_path / "libxnet.a"
    archive.write_bytes(b"unused archive for storage runner test\n")
    config = tmp_path / "xnet-config.mk"
    config.write_text(f"XNET_FC := {sys.executable}\nXNET_ARCHIVE := {archive}\nXNET_CPPFLAGS := -DXNET_OMP\n")
    (tmp_path / "config.txt").write_text("OPENMP_MODE=ON\nPE_ENV=GNU\n")
    work_root = tmp_path / "runs"
    monkeypatch.setattr(sys, "argv", [str(source), "--root", str(source.parents[2]),
        "--consumer", str(consumer), "--storage-consumer", str(storage), "--library-config", str(config),
        "--net-setup", str(setup), "--work-dir", str(work_root)])
    with pytest.raises(RuntimeError, match=expected_error):
        runner.main()
    work, = work_root.glob("host-batch-*")
    records = json.loads((work / "commands.json").read_text())
    probes = [record for record in records if record["argv"][0] == str(storage)]
    assert len(probes) == (12 if scenario == "valid" else 1)
    assert all(record["returncode"] == 0 for record in probes)
    if scenario == "valid":
        assert {(record["argv"][1], int(record["argv"][2]), record["OMP_NUM_THREADS"]) for record in probes} == {
            (network, capacity, workers)
            for network in ("Data_alpha", "Data_SN160") for capacity in (4, 16) for workers in (1, 2, 4)
        }
        assert records[-1]["argv"][0] == str(consumer) and records[-1]["returncode"] == 7
    else:
        assert not any(record["argv"][0] == str(consumer) for record in records)
    assert ("PASS worker storage:" in capsys.readouterr().out) == (scenario == "valid")
    hashes = json.loads((work / "inputs.json").read_text())["sha256"]
    for path in (storage, source.with_name("worker_storage_consumer.F90")):
        assert hashes[str(path)] == hashlib.sha256(path.read_bytes()).hexdigest()
