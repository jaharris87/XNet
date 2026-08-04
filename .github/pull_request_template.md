## Summary

What does this change do, and why?

## Governing issue

Closes #

## Scope

Describe the implemented change and any intentional departure from the issue,
investigation findings, or implementation plan.

## Verification

List the exact commands and configurations used.

```text
command
```

- Compiler and version:
- Relevant build variables:
- Input or test problem:
- Comparison or reference source:
- Tolerances, when applicable:
- Observed result:

A successful build, zero exit status, or completed legacy test script is not by
itself evidence of numerical or scientific correctness.

## Numerical, scientific, and performance effects

Select the statements that apply:

- [ ] No numerical behavior is expected to change.
- [ ] Numerical behavior changes as described below.
- [ ] Floating-point ordering or reproducibility may change.
- [ ] Scientific interpretation or validity requires maintainer review.
- [ ] Runtime inputs, outputs, diagnostics, or public interfaces change.
- [ ] Performance may change and was measured as described below.
- [ ] Performance was not evaluated because it is outside the scope of this change.

Details:

## Portability and configurations

- Configurations tested:
- Configurations affected but not tested:
- Known platform, compiler, MPI, accelerator, or library limitations:

Do not claim portability from one successful configuration.

## Test effectiveness

For defect fixes or new behavioral checks:

- What incorrect or missing behavior does the check detect?
- Was the check demonstrated to fail before the implementation change?
- If not, why was that impractical or unnecessary?

## Review notes

Identify assumptions, uncertain areas, consequential choices, or parts of the
change that deserve particular attention.

## Checks not run

List meaningful checks that were not available, not practical, or outside the
scope of this change.

## Checklist

- [ ] The change is bounded to the governing issue.
- [ ] Unrelated cleanup, renaming, file movement, and reformatting have been excluded.
- [ ] Generated files, runtime outputs, local paths, and machine-specific settings are not included.
- [ ] Documentation was updated where current behavior or interfaces changed.
- [ ] Numerical tolerances were not loosened merely to obtain a passing result.
- [ ] Checks not run and important limitations are stated explicitly.
- [ ] The worktree was inspected for unintended generated or modified files.
