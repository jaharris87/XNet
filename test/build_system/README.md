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
configuration-specific cleaning, solver selection, CUDA path selection, and
early rejection of incompatible options. The CUDA checks exercise Make
selection only; they do not qualify NVIDIA hardware or a CUDA toolchain.

The external-EOS check compiles a small application thermodynamics module
with a host-module import, alongside XNet's composition and screening module.
It checks parallel library construction, module include order, recorded
settings, recompilation after a host module changes at the same path, and
rejection of the reserved `xnet_eos` filename stem, standalone targets, or
incompatible directory reuse. It does not validate an application's EOS or
burn results.
