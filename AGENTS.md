# XNet repository guidance

This file applies to the whole repository. Follow a governing issue or
explicit maintainer instruction when it is more specific and remains
consistent with repository-wide safety, compatibility, and evidence
requirements. Report apparent conflicts before proceeding.

## Project purpose

XNet is a thermonuclear reaction-network code for astrophysical
nucleosynthesis, written primarily in Fortran. It evolves abundances for an
arbitrary collection of nuclei linked by nuclear reaction rates. The stiff ODE
system is integrated with implicit Backward Euler or BDF methods and selectable
linear-algebra implementations.

The principal uses are stand-alone post-processing calculations, commonly
from Lagrangian tracer-particle histories, and integration into multiphysics
simulation packages such as Flash-X and CHIMERA. XNet supports astrophysical
problems ranging from supernovae and neutron-star mergers to X-ray bursts,
novae, and big-bang nucleosynthesis. Portability spans laptops, HPC systems,
multiple compilers, MPI, CPUs, and accelerators.

## Smallest useful working set

Start with the governing issue, the source being changed, and the tests or
inputs that exercise it. Read additional guidance when the task calls for it:

| Read this | When |
| --- | --- |
| `docs/development/build-and-test.md` | Changing build logic, configurations, tests, numerical results, or performance |
| `docs/development/maintainer-workflow.md` | Creating issues, branches, PRs, reviews, or coordinated work |
| `docs/development/scientific-validation.md` | Changing physics, rates, solvers, convergence, tolerances, or numerical behavior |
| `docs/development/architecture-overview.md` | Work spans modules or requires architectural reasoning |
| `doc/XNet_Formatting_Guidelines.md` | Editing production Fortran |

## Sources of truth

- Use the governing issue for the intended change, its limits, and acceptance
  criteria.
- Use current source and Makefiles for program and build behavior.
- Treat `test/` as historical inputs and run instructions. Establish
  correctness through explicit inspection and appropriate comparisons.
- Use documentation for orientation, then verify task-relevant claims against
  the code.
- Describe current state and proposed design separately. Current structure may
  reflect legacy constraints.
- Report disagreements among the issue, code, tests, and documentation and
  resolve them from evidence or maintainer direction.

## Repository map

- `source/` contains production Fortran, the stand-alone driver, utility
  programs, and the GNU Make build.
- `test/` contains the legacy shell drivers, runtime settings, problem inputs,
  and pre-built `Data_*` networks.
- `tools/` contains vendored numerical code and supporting network-building,
  analysis, thermodynamic, and data utilities. Verify each tool before relying
  on it.
- `doc/` contains current formatting guidance and scientific or solver
  references.
- `docs/development/` contains task-specific developer and maintainer
  guidance.

## Build and test essentials

Build the tracked default configuration from the repository root:

```bash
make -C source -j
```

Builds are in-place, and configurations share object and module filenames.
Run `make -C source clean` before changing compiler, numerical flags, parallel
mode, accelerator mode, EOS, linear-algebra library, or matrix solver, then
rebuild the requested target.

The legacy test commands provide useful run recipes and comparisons with
unreliable pass/fail behavior. Treat the wrapper's exit status as wrapper
status. Confirm XNet invocation and completion from direct program status and
produced diagnostics, then inspect diff files before reporting numerical
agreement. See `docs/development/build-and-test.md` for tracked defaults,
utility targets, runtime inputs, test side effects, and evidence requirements.

## Core change rules

- Keep changes bounded to the issue. Separate functional work from unrelated
  cleanup, reformatting, file moves, and renames.
- Preserve current behavior before refactoring it. Add characterization
  evidence when behavior lacks clear coverage.
- Record nearby technical debt for separate work.
- Require issue-level evidence and approval before deleting code or data.
- Scope changes to public interfaces, runtime file formats, diagnostic
  formats, numerical algorithms, convergence criteria, physical constants,
  dependencies, and compiler requirements explicitly in the governing issue.
- Avoid new mutable module-global state. Broad removal of existing global
  state requires a dedicated task and adequate tests.
- Preserve serial, MPI, threaded, and accelerator considerations in shared
  code. Report portability for the configurations actually checked.
- Update explicit object prerequisites in `source/Makefile` when a changed
  `Use` dependency affects parallel builds.
- Keep generated objects, module files, executables, runtime outputs,
  comparison files, local paths, and machine-specific settings out of commits.
- Treat the line-oriented `control` input and fixed diagnostic outputs as
  compatibility-sensitive interfaces.

Scientific validity and consequential numerical or architectural choices
remain human maintainer decisions. Agents expose assumptions and evidence for
those decisions.

## Fortran essentials

Use surrounding production source as the primary style reference and
`doc/XNet_Formatting_Guidelines.md` as a secondary reference. Vendor binding
files may follow external conventions.

- Limit formatting changes to lines touched by the task.
- Use kinds from `xnet_types`, normally `dp`, consistently with nearby code.
- Retain existing integer-valued control flags across touched interfaces.
- Use `Implicit None`, explicit argument `Intent`, and focused
  `Use ..., Only: ...` lists in ordinary XNet source.
- Comment scientific intent, units, assumptions, and non-obvious algorithms.
- Cite material scientific sources accurately.

## Development workflow

The fork's `main` branch mirrors upstream `main`. Feature work branches from
the verified current `development` base and targets PRs back to `development`.
The maintainer coordinates eventual upstream integration and subsequent
branch synchronization. See `docs/development/maintainer-workflow.md` before
performing repository operations.

Repository work intended for merge follows this compact flow:

1. Create or identify a governing issue with acceptance criteria and required
   evidence.
2. Investigate first for nontrivial work and identify the smallest credible
   change.
3. Implement on a feature branch with appropriate tests or other objective
   evidence.
4. Self-review the complete local diff against the issue.
5. Commit and push the review candidate.
6. Open a draft PR to `development` with exact verification results and
   remaining checks.
7. Only after the draft PR exists and the review candidate is committed and
   pushed, obtain independent, fresh-context review for the active review
   roles. Identify the PR and exact candidate commit in the reviewer brief or
   review record.
8. Give every consequential finding a documented disposition. Push
   substantive review fixes and identify the new commit in any required
   re-review.
9. Hand the PR to the human maintainer after required checks pass and
   merge-blocking findings are resolved.

Successful implementation and local verification do not complete work
intended for merge. Continue through the steps above unless the maintainer
explicitly requested local-only work or a documented blocker prevents
progress; report the blocker when handing off incomplete work.

## Communication

Use plain, direct language in issues, plans, PRs, review comments,
documentation, and reports. Name the file, behavior, limit, test, or affected
user directly.

Prefer concrete phrases such as `quick test`, `initial setup`, `requirement`,
`required check`, `reference result`, and `basic verification` when those are
what is meant. Use specialized terms such as `idempotent`, `contract`,
`boundary`, or `oracle` when their precise technical meaning matters, and
explain the concrete behavior first. State exactly what will be added,
checked, restricted, or changed.

Report evidence separately from interpretation. Include command outcomes and
important limitations. Treat a successful compile, a zero exit status, and one
hardware configuration as specifically limited evidence.
