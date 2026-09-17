#!/usr/bin/env python3
"""Focused effectiveness checks for the direct isolated GNU Make graph."""
from __future__ import annotations

import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "source"
PRODUCTION_MAKEFILE = SOURCE / "Makefile.production"


def make(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["make", "-C", str(SOURCE), "--no-print-directory", *arguments],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def require_success(result: subprocess.CompletedProcess[str]) -> None:
    assert result.returncode == 0, result.stdout + result.stderr


def main() -> int:
    makefile = PRODUCTION_MAKEFILE.read_text(encoding="utf-8")
    sparse_jacobian_rule = next(
        line for line in makefile.splitlines() if "$(call solver_obj,$(JAC_SRC)):" in line
    )
    assert "$(call source_obj,$(MPI_SRC))" in sparse_jacobian_rule
    for name in ("xnet_jacobian_MA48.F90", "xnet_jacobian_PARDISO_MKL.F90"):
        assert "Use xnet_parallel" in (SOURCE / name).read_text(encoding="utf-8")

    with tempfile.TemporaryDirectory(prefix="xnet-build-graph-") as temporary:
        build = pathlib.Path(temporary) / "gnu"
        products = make(f"BUILD_DIR={build}", "-j4", "xnet", "xnse", "net_setup")
        require_success(products)
        assert "python" not in (products.stdout + products.stderr).lower()
        for executable in ("xnet", "xnse", "net_setup"):
            assert (build / "bin" / executable).is_file()

        mismatch = make(f"BUILD_DIR={build}", "CMODE=DEBUG", "xnet")
        assert mismatch.returncode != 0
        assert "incompatible BUILD_DIR configuration" in mismatch.stderr

        invalid_record = make(
            f"BUILD_DIR={build.parent / 'invalid-record'}",
            "FFLAGS=safe_flag\nINJECTED=1",
            "xnet",
        )
        assert invalid_record.returncode != 0
        assert "cannot represent single quotes or line breaks" in invalid_record.stderr

        clean = make(f"BUILD_DIR={build}", "clean")
        require_success(clean)
        assert not build.exists()
    print("direct isolated GNU Make graph checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
