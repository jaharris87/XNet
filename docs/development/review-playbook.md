# Independent review playbook

> Use this playbook to select and record independent review for work intended
> for merge. Apply it in proportion to the change; do not activate every role
> for a low-risk change.

This playbook turns recurring XNet review experience into a small, composable
protocol. It supplements the [maintainer workflow](maintainer-workflow.md).
The governing issue remains the source of authority, and human maintainers
retain scientific, numerical, architectural, support, and repository-setting
decisions.

## Declare risks and evidence

Before implementation, select every applicable risk class. Add or remove a
default role when the governing issue or actual diff justifies it, and record
the reason. Requirements and scope review is the minimum independent role for
merge-intended work. A documentation-only correction normally stops there
unless it makes scientific, support, or operational claims.

| Risk class | Applies when | Default roles | Minimum evidence | Human-only decisions exposed |
| --- | --- | --- | --- | --- |
| `D` — documentation/process | Contributor guidance, templates, or descriptive text changes without product behavior changes | requirements/scope | rendered or structurally validated text, checked links and paths, claim-to-source comparison | new support, policy, authority, or repository-setting commitments |
| `T` — tests/infrastructure | Test runners, comparison tools, validators, schemas, retained evidence, or developer tooling changes | requirements/scope; test effectiveness; software correctness/maintainability; provenance/operational evidence when evidence is retained | focused positive and negative cases, pre-fix or controlled-mutation behavior, relevant existing checks | acceptance of new scientific or numerical policy encoded by the tooling |
| `P` — production behavior | Production code, runtime interfaces, diagnostics, error handling, or dependencies change | requirements/scope; software correctness/maintainability; test effectiveness | clean build, direct execution where applicable, focused behavior and preservation checks | architecture, public-interface, support, and consequential compatibility choices |
| `S` — scientific/numerical/reference | Physics, rates, solvers, convergence, tolerances, scientific inputs, references, or accepted results change | requirements/scope; scientific/numerical behavior; test effectiveness; provenance/operational evidence for references or retained data | applicable scientific-validation record, independent comparisons, explicit tolerances and identities, controlled scientific mutations | scientific validity, numerical policy, reference acceptance, and interpretation |
| `B` — build/portability/concurrency | Make logic, compiler selection, MPI, threading, accelerator, solver library, configuration, or concurrent behavior changes | requirements/scope; build/portability/concurrency; software correctness/maintainability; test effectiveness | clean requested builds, exact resolved configuration, configuration-specific execution, relevant negative or substitution probes | compiler/platform support claims and consequential concurrency or dependency policy |
| `H` — manual/HPC qualification | Evidence requires an allocation, specialized hardware, site software, or a manual retained run | requirements/scope; provenance/operational evidence; build/portability/concurrency; any role for the behavior being qualified | exact candidate-to-run binding, requested and resolved environment, complete status and artifact record, independently recomputed claims where practical | qualification scope, platform support, exceptions, and unavailable reruns |

The roles are review viewpoints, not required people or agents:

- **requirements/scope:** checks the governing issue, exclusions, interfaces,
  acceptance criteria, and claims against the complete diff;
- **software correctness/maintainability:** traces behavior, failure paths,
  state, interfaces, and bounded maintenance consequences;
- **test effectiveness:** asks whether a check can fail for the claimed defect
  and pass for the corrected behavior, including the reason for rejection;
- **scientific/numerical behavior:** checks scientific inputs, equations,
  conventions, numerical policy, comparisons, tolerances, and interpretation;
- **build/portability/concurrency:** checks requested and resolved build/runtime
  configurations, dependencies, compilers, workers, devices, and platform
  limits; and
- **provenance/operational evidence:** binds claims to the exact source,
  executable, run, inventory, environment, and immutable retained evidence.

Keep evidence categories distinct. A build shows that a compiler produced
requested artifacts. Execution shows that the requested artifact and
configuration ran and completed. Software evidence shows required behavior
and failure handling. Numerical evidence compares values under stated rules.
Scientific evidence supports the physical interpretation, inputs, and
method. Portability evidence applies only to checked configurations unless a
broader argument is supplied. Performance evidence requires a stated method
and comparison; none of the other categories implies performance.

## Prepare a reviewer brief

Independent review starts only after the candidate is committed, pushed, and
present in a draft PR targeting `development`. Give each fresh-context
reviewer a read-only brief containing:

- the governing issue and acceptance criteria;
- the draft PR number and exact pushed candidate SHA;
- the applicable risk classes and assigned review role;
- this playbook at an identified repository revision;
- the applicable repository documents and required evidence; and
- a precise context boundary: the PR diff and evidence supplied, plus any
  files, platforms, or checks unavailable to the reviewer.

Do not give a favorable implementation narrative, prior reviewer conclusions,
or instructions to repair the candidate. Ask the reviewer to check the issue
and claims directly, seek counterexamples and false passes, and report only
evidence needed to understand the result. A local checkout may supplement the
open PR but cannot replace it as the review source of record.

Record each invocation without retaining private reasoning or complete
prompts:

```text
Review invocation: RV-<round>-<role>
Role:
PR and exact candidate SHA:
Playbook revision:
Risk classes:
Supplied context boundary:
Reviewer/session class: human or fresh-context agent; session identifier if available
Read-only: yes/no and explanation if no
Checks independently run:
Result: PASS or finding IDs
Limitations:
```

`PASS` is a valid result when the reviewer cannot establish a consequential
issue. It does not erase limitations or prove claims outside the supplied
context.

## Record and dispose of findings

Assign a stable ID such as `REQ-001`, `SWE-001`, `TST-001`, `SCI-001`,
`BLD-001`, or `PRO-001`. Never reuse or renumber an ID after it enters the PR
record. Preserve the original consequential finding before changing the
candidate.

Each finding records:

```text
Finding ID and role:
Severity: merge-blocking / consequential non-blocking / suggestion
Confidence: high / medium / low
Candidate SHA:
Path and line, when applicable:
Evidence:
Consequence:
Smallest appropriate fix:
Verification: required check and result when disposed
```

Give every finding one disposition:

- **Agree and fix:** change the candidate or evidence and run the stated
  verification.
- **Disagree with evidence:** preserve the finding and answer it with specific
  code, checks, results, or an authoritative source.
- **Defer:** record why it is outside the PR, its consequence, and the linked
  follow-up location.
- **Accepted limitation:** preserve the bounded gap and identify the human
  authority accepting it; this cannot silently waive an acceptance criterion.

Substantive repairs receive a new pushed candidate. Re-review records the
prior and replacement SHAs, the finding IDs checked, independent verification
of each accepted fix, new checks run, and any material risk introduced by the
repair. Activate another role if the repair changes the risk classes. A
wording-only or evidence-only follow-up may omit a rerun only when the record
explains why it cannot affect the previously reviewed behavior.

## XNet false-pass questions

The questions below come from accepted findings in
[#52](https://github.com/jaharris87/XNet/pull/52),
[#54](https://github.com/jaharris87/XNet/pull/54),
[#59](https://github.com/jaharris87/XNet/pull/59),
[#60](https://github.com/jaharris87/XNet/pull/60), and
[#66](https://github.com/jaharris87/XNet/pull/66). Use only the questions
relevant to the selected risks.

| Review role | Concrete question | Historical finding reproduced |
| --- | --- | --- |
| build/portability/concurrency; provenance/operational evidence | Does retained topology or independently identified executable content prove that each requested configuration, worker type, device, or solver actually ran, rather than accepting a substituted serial or duplicate executable? | #52 accepted serial as OpenMP; #59 accepted one executable in both solver roles |
| test effectiveness; scientific/numerical behavior | Do comparisons cover every field named by the claim, including energy, neutrino, timestep, normalization, and complete-vector fields where applicable? | #52 omitted ASCII energy fields |
| test effectiveness | Was each claimed mutation or negative probe actually executed, and does its diagnostic show rejection for the intended reason rather than an earlier unrelated failure? | #52's zero-status mutation was not exercised; #54 exposed overly broad malformed-row handling |
| build/portability/concurrency | Can a clean delayed or parallel build expose a missing explicit module/object prerequisite hidden by a prior in-place build? | #54 missed a `testdrive.mod` prerequisite |
| scientific/numerical behavior; provenance/operational evidence | Does scientific identity cover effective physical identity and every result-bearing field, while excluding source spelling and reconciliation-only provenance that cannot change the calculation? | #54 used names-only nuclear identity and omitted residuals from the fingerprint; #66 coupled identity to an equivalent literal and reconciliation annotations |
| provenance/operational evidence | Are inputs, source trees, executables, results, nested claims, and authoritative inventories immutable and mutually bound at the point they are used? | #54 compared stale compositions with a rewritten manifest; #60 left the built tree and nested claims unbound |
| provenance/operational evidence; test effectiveness | Can a nominally successful manifest contain failed, missing, partial, stale, duplicate, unsafe, or contradictory records and still validate? | #60 accepted false-success and incomplete manifest evidence |
| scientific/numerical behavior; provenance/operational evidence | Does validation recompute permitted bounds and selected data from tracked policy and raw observations, rather than trusting reported `allowed`, maximum, or selection fields? | #60 allowed evidence to authorize its own numerical limits |
| test effectiveness; provenance/operational evidence | Would missing late-written outputs, logs, submission records, zones, inactive lanes, or nonzero diagnostic values be detected, and is the inventory finalized only after writers finish? | #52 initially omitted relevant output fields; #60 inventoried partial evidence and lacked nonzero neutrino evidence |

These questions do not authorize automatic repair, scientific approval, or
merge. They also do not impose finding quotas, diff-size limits, complexity
thresholds, style gates, or authorship detection.

## Proportionate walkthroughs

- A documentation-only change normally uses class `D`, one requirements/scope
  reviewer, Markdown/link or schema evidence, and a `PASS` or bounded finding
  record.
- Test or validation infrastructure uses `T`; add `B` for configuration
  claims, `S` for numerical/scientific policy, and `H` for retained manual
  runs. Controlled false-pass cases should fail for their stated reason.
- Production work uses `P`; add `S` for scientific or numerical behavior and
  `B` for build, portability, or concurrency effects. Build, execution,
  software, numerical, and scientific evidence remain separate.
- Scientific or reference work uses `S` even when only data or tooling changes.
  Human scientific and numerical acceptance remains explicit.
- Build, portability, or concurrency work uses `B` and proves the actual
  requested configuration. One checked compiler or platform does not create a
  general support claim.
- Manual HPC qualification uses `H` plus the behavior's other risk classes.
  Review binds the exact pushed source, resolved environment, executable, run,
  and finalized artifacts; unavailable hardware and rerun limits remain
  visible.
