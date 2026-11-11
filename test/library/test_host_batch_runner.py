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
