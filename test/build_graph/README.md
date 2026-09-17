# Isolated build-graph effectiveness checks

Run the focused build-graph checks from the repository root:

```bash
python3 test/build_graph/test_build_graph.py
```

The script uses temporary fake compiler wrappers to inspect provider selection,
configuration mismatches, concurrency, cleaning boundaries, and the retained
Cray preprocessing path without claiming those configurations are qualified.
It also exercises the dependency scanner with nested Fortran includes,
submodules, missing and duplicate providers, and precompiled external modules.
A final real GNU build checks module-output isolation plus incremental source,
module, and macro propagation. All temporary fixtures are removed; the real
check uses ignored `build/effectiveness-real/`.
