# Production build-system checks

Run the focused build-system checks from the repository root:

```bash
python3 test/build_system/test_build_system.py
```

The script invokes the repository-root Makefile and builds the three programs
in temporary GNU build directories. It
checks generic and Perlmutter defaults, explicit machine selection, separate
parallel builds, automatic and explicit build-directory names, incremental
rebuilds, configuration-reuse protection,
configuration-specific cleaning, solver selection, CUDA path selection,
host OpenMP preprocessing definitions, accelerator compiler options, and
early rejection of incompatible options. The accelerator checks exercise Make
selection only; they do not qualify accelerator hardware or toolchains.

Run only the host OpenMP and accelerator flag checks, including caller flag
overrides and environment flags with `make -e`, with:

```bash
python3 - <<'PY'
import os, pathlib, runpy, tempfile
checks = runpy.run_path("test/build_system/test_build_system.py")
with tempfile.TemporaryDirectory(prefix="xnet-host-flags-") as temporary:
    checks["check_host_openmp_flags"](pathlib.Path(temporary), dict(os.environ))
print("host OpenMP flag checks passed")
PY
```

The external-EOS check compiles a small application thermodynamics module
with a host-module import, alongside XNet's composition and screening module.
It checks parallel library construction, module include order, recorded
settings, recompilation after a host module changes at the same path, and
rejection of the reserved `xnet_eos` filename stem, standalone targets, or
incompatible directory reuse. It does not validate an application's EOS or
burn results.
