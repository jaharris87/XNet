#!/usr/bin/env python3
"""Bounded failure-path checks for the minimal benchmark runner."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).with_name("run.py")
SPEC = importlib.util.spec_from_file_location("minimal_benchmark_run", RUNNER)
assert SPEC is not None and SPEC.loader is not None
run = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = run
SPEC.loader.exec_module(run)


class RunnerTests(unittest.TestCase):
    def make_repository(self, root: Path) -> tuple[Path, str]:
        repository = root / "source"
        repository.mkdir()
        subprocess.run(["git", "init", "-q", repository], check=True)
        subprocess.run(["git", "-C", repository, "config", "user.name", "Benchmark Test"], check=True)
        subprocess.run(["git", "-C", repository, "config", "user.email", "benchmark@example.invalid"], check=True)
        (repository / "tracked").write_text("clean\n", encoding="utf-8")
        subprocess.run(["git", "-C", repository, "add", "tracked"], check=True)
        subprocess.run(["git", "-C", repository, "commit", "-q", "-m", "fixture"], check=True)
        revision = subprocess.check_output(["git", "-C", repository, "rev-parse", "HEAD"], text=True).strip()
        return repository, revision

    def test_wrong_and_dirty_source_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository, revision = self.make_repository(Path(temporary))
            self.assertEqual(run.verify_source(repository, revision)["revision"], revision)
            with self.assertRaisesRegex(run.BenchmarkError, "source revision"):
                run.verify_source(repository, "0" * 40)
            (repository / "tracked").write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(run.BenchmarkError, "tracked modifications"):
                run.verify_source(repository, revision)

    def test_failed_build_is_retained(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "Makefile").write_text("xnet:\n\tfalse\n", encoding="utf-8")
            output = root / "record"
            output.mkdir()
            command, status = run.build_xnet(source, root / "build", output, {}, 1)
            self.assertNotEqual(status, 0)
            self.assertEqual(command[-1], "xnet")
            self.assertTrue((output / "build.log").is_file())

    def test_failed_execution_and_missing_diagnostic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "fail.sh"
            executable.write_text("#!/bin/sh\nexit 7\n", encoding="utf-8")
            executable.chmod(0o755)
            completed, wall = run.run_process([str(executable)], root, {}, 5.0)
            self.assertEqual(completed.returncode, 7)
            self.assertGreaterEqual(wall, 0.0)
            with self.assertRaisesRegex(run.BenchmarkError, "no nonempty net_diag"):
                run.compare_diagnostics(root, {})

    def test_controlled_input_constants(self) -> None:
        text = run.trajectory_text()
        self.assertIn("1.000000E+01    Stop Time", text)
        control = run.control_text("alpha", "Data_alpha", ("c12", "o16"), 4, 1, False)
        self.assertIn("1         Include Weak Reactions", control)
        self.assertIn("0         Include self-heating", control)


if __name__ == "__main__":
    unittest.main()
