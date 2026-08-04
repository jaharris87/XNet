# Maintainer workflow

> Read this document when creating or changing issues, branches, pull
> requests, review findings, coordinated work, or repository integration.

This workflow keeps development bounded, evidence-oriented, independently
reviewed, and ready for human scientific judgment. Apply its detail in
proportion to the risk and size of the task.

## Branch policy

The fork's branches have distinct roles:

- `main` mirrors upstream `main` and receives synchronization updates from
  upstream.
- `development` receives feature work and supplies the staged changes for
  eventual upstream integration.
- feature branches start from the current `development` branch and target PRs
  back to `development`.

Agent-created feature branches normally use:

```text
codex/<issue-number>-<short-name>
```

Confirm the base branch and worktree state before branching. Preserve user
changes and report any overlap with the intended work.

For a feature branch:

1. inspect the worktree and current branch;
2. fetch `origin`;
3. compare local `development` with `origin/development`, including ahead,
   behind, and divergence state;
4. resolve unexpected local commits or missing remote commits with the
   maintainer;
5. branch from the exact `development` commit confirmed for the issue.

A clean worktree describes file state. The branch comparison establishes the
base commit for the proposed change.

The maintainer decides when accumulated work on `development` is ready for an
upstream PR or other upstream integration process. After upstream accepts the
work, synchronize the fork's `main` and reconcile `development` as directed by
the maintainer. Record the integration decision and combined validation in the
relevant issue or PR.

## Governing issue

Create or identify the governing GitHub issue before repository work intended
for merge. A useful issue states:

- the observed problem or requested capability;
- scientific or user motivation;
- relevant files or subsystems when known;
- constraints and non-goals;
- acceptance criteria;
- required tests and validation evidence;
- expected numerical, compatibility, portability, or performance changes;
- behavior and interfaces that must remain stable.

Separate the problem and acceptance criteria from a speculative implementation
when the solution still requires investigation.

An issue can add task-specific detail while repository-wide safety,
compatibility, and evidence requirements remain in force. Report conflicts or
ambiguous authority to the maintainer before proceeding.

## Investigation

For nontrivial work, investigate before modification and record a concise
report or plan covering:

- involved entry points and code paths;
- build-time and runtime configurations involved;
- shared state, interfaces, and assumptions;
- existing tests and their limitations;
- uncertainties and questions requiring maintainer input;
- the smallest credible change;
- likely failure modes and unintended effects;
- planned evidence for each acceptance criterion.

Small, low-risk tasks can combine investigation and implementation. Changes to
physics, numerical algorithms, public interfaces, build logic, dependencies,
or performance-sensitive paths benefit from an explicit scope check before
editing.

## Implementation

Implement one cohesive issue scope on the feature branch:

- keep the diff focused;
- preserve unrelated user work;
- add or update tests and reproducible evidence;
- record necessary departures from the issue or investigation plan;
- keep generated and machine-specific files out of commits;
- review changes for serial, MPI, threading, accelerator, and compiler effects
  relevant to the touched code.

For a defect fix, identify or add evidence that distinguishes faulty behavior
from corrected behavior. Prefer demonstrating the pre-fix failure when
practical. See `scientific-validation.md` for numerical and physics changes.

## Self-review before the PR

Review the complete diff against the governing issue:

- check every acceptance criterion;
- identify unnecessary edits and cleanup creep;
- confirm tests exercise the intended defect or requirement;
- inspect error paths and relevant limiting cases;
- check comments and documentation against the implementation;
- check for generated files, debug code, and local paths;
- assess floating-point ordering, reproducibility, compatibility, portability,
  and performance effects;
- align the summary with the evidence actually collected.

Self-review prepares the change for independent review.

## Opening the PR

Open the feature PR against `development` and link the governing issue. Record:

- the problem and implemented change;
- explicit non-goals and deferred work;
- files, interfaces, and users affected;
- exact build and test commands;
- compiler and relevant build variables;
- numerical comparisons, reference sources, and tolerances;
- expected and observed behavior;
- performance measurements when relevant;
- remaining checks and unavailable configurations;
- known uncertainties or maintainer decisions still needed.

Keep claims proportional to the recorded evidence.

## Independent adversarial review

Use a fresh-context reviewer agent for each review role activated by the issue
or maintainer. Select roles from the actual risks of the change. The role set
can evolve as recurring XNet work establishes useful specialties.

Provide each reviewer with:

- the governing issue and acceptance criteria;
- the complete diff or PR state;
- relevant current documentation;
- build, test, numerical, and performance evidence.

Keep the review context free of implementation discussion so reviewers reach
their own conclusions. Ask reviewers to:

- check requirements and claims directly against code;
- seek counterexamples and relevant limiting cases;
- inspect whether tests can expose the defect or missing behavior;
- identify unintended changes and compatibility effects;
- distinguish confirmed defects, likely defects, and speculative concerns;
- flag missing evidence and questions requiring scientific judgment;
- state consequence and confidence clearly.

Useful finding categories include:

- merge-blocking defect;
- likely defect;
- missing evidence;
- maintainability concern;
- scientific or domain question;
- non-blocking suggestion.

Preserve the independent reviewer's original findings before implementation
responses materially alter the reviewed code. Post confirmed or potentially
consequential findings to the PR. Summarize low-value duplicates and clearly
inapplicable findings so the review record stays useful.

## Findings disposition

Give every consequential finding one disposition:

- **Agree and fix:** change the implementation or evidence and verify the
  result.
- **Disagree with evidence:** explain the reasoning and cite code, tests,
  numerical results, or authoritative references.
- **Defer with reason:** explain why the work is outside the PR, record the
  consequence, and create or identify an appropriate follow-up location.

Post a disposition summary after each substantive review round. Include
non-blocking findings in the summary when they affect future maintenance or
scientific understanding.

Repeat independent review after substantive fixes when the changes can
introduce new defects or materially change the reviewed solution. Review is
complete when:

- merge-blocking findings are resolved;
- remaining findings have documented dispositions;
- required evidence is present;
- further review is unlikely to add useful evidence.

Escalate persistent disagreement, repeated review churn, scientific
uncertainty, or an unclear stopping point to the maintainer.

## Ready-to-merge handoff

Hand the PR to the human maintainer with:

- a final issue and acceptance-criteria check;
- a concise diff summary;
- exact verification evidence;
- the review and disposition summary;
- remaining non-blocking work and limitations;
- any scientific or architectural decisions requiring human judgment.

The human maintainer owns final scientific and architectural judgment, the
merge of ordinary feature PRs, and the final integrated umbrella result. An
umbrella issue can explicitly delegate component-PR merges to its orchestrator
under the rules below.

## Post-merge closeout

After the human maintainer merges an ordinary feature PR into `development`:

1. confirm that the merged PR satisfies the governing issue's acceptance
   criteria, or record the remaining work and keep the issue open;
2. when the issue is complete, close it as completed; and
3. add a closing comment that links the merged PR and identifies any deferred
   follow-up work.

The human maintainer initiates this closeout. An agent may prepare the record
or close the issue only with explicit maintainer authorization.

GitHub processes issue-closing keywords such as `Closes #123` only for pull
requests targeting the repository's default branch. XNet feature PRs target
`development`, so those keywords do not replace this post-merge step. Keep
the governing issue linked in the PR; the reference remains useful during later
integration to `main`.

## Coordinated umbrella work

Use an orchestrating agent when an explicitly authorized umbrella issue
contains bounded sub-issues whose work can proceed through separate
development cycles. A single bounded PR remains the normal shape for ordinary
tasks.

The orchestrator:

- defines or confirms sub-issue scope and dependencies;
- assigns each sub-issue to its own task and issue-to-PR-review cycle;
- tracks decisions and evidence across components;
- prevents component work from broadening into neighboring scopes;
- reviews component findings and dispositions;
- assesses component readiness and, when the umbrella issue explicitly grants
  it, performs component-PR merges;
- performs integrated build, numerical, compatibility, and performance checks
  required by the parent issue;
- hands the final integrated result to the human maintainer.

Component agents remain within their sub-issue and leave cross-component
scope and merge decisions to the orchestrator.

Review roles, issue/PR templates, labels, and automation can be introduced as
real workflow experience establishes a recurring need. The current process can
operate through ordinary GitHub issues, branches, PRs, comments, and manually
selected fresh-context reviews.
