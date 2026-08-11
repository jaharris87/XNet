# Review-effectiveness evaluation

> Use this document when evaluating whether
> [`review-playbook.md`](review-playbook.md) detects known XNet review
> failure modes without inventing unsupported findings on repaired candidates.

This is a bounded seed evaluation for issue
[#71](https://github.com/jaharris87/XNet/issues/71). It evaluates the first
repository review playbook merged by PR
[#73](https://github.com/jaharris87/XNet/pull/73) at
`5395b1ed117536787d26871c3dc7d03e559aaedd`.

The case set is finite. It is not a benchmark, model ranking, finding quota,
automatic merge gate, AI-code detector, or recurring workflow program. New
cases are added or replaced only when a material playbook change or a distinct
consequential post-merge or review failure justifies a bounded update.

## Authority and boundaries

The preserved dispositions from the historical PR records define the accepted
findings for this seed. The evaluation may justify a documentation correction
to the playbook, or record that no correction is justified. It does not
authorize production Fortran, tests, scientific results, support claims,
architecture, workflow files, repository settings, automatic repair, or merge
policy changes.

Fresh-context evaluation reviewers are read-only. They receive a minimal
review source and must not be given prior findings, favorable implementation
summaries, repair explanations, later candidate SHAs, disposition comments, or
other evaluation results.

## Evaluation procedure

1. Select only genuinely distinct historical failure modes needed to cover
   PRs [#52](https://github.com/jaharris87/XNet/pull/52),
   [#54](https://github.com/jaharris87/XNet/pull/54),
   [#59](https://github.com/jaharris87/XNet/pull/59),
   [#60](https://github.com/jaharris87/XNet/pull/60), and
   [#66](https://github.com/jaharris87/XNet/pull/66).
2. For each retained case, evaluate the defective candidate and the exact
   repair candidate as separate fresh-context review tasks. If the exact
   repair candidate later became a defective candidate for a distinct retained
   case, or if a later evidence-only head is the useful clean counterexample,
   record both states instead of collapsing them into one repaired result.
   A reviewer may know the governing issue, selected `review-playbook.md`
   revision, assigned risk classes and role, historical base SHA, candidate
   SHA, and applicable repository files at that candidate.
3. The supplied context boundary is:
   - the governing issue body only, without issue comments;
   - `docs/development/review-playbook.md` at the identified playbook
     revision;
   - the local base-to-candidate diff;
   - files at the candidate SHA needed to inspect the diff; and
   - commands the reviewer independently runs within that boundary.
4. The withheld context includes:
   - PR bodies, comments, reviews, final summaries, and disposition records;
   - later repair commits and paired repaired or defective candidates;
   - favorable implementation narratives;
   - prior reviewer findings; and
   - other evaluation-review outputs.
5. Record every invocation with the playbook terms:
   - review ID;
   - role;
   - exact candidate SHA;
   - playbook revision;
   - risk classes;
   - supplied context boundary;
   - reviewer/session class, model when exposed, and effort when exposed;
   - read-only status;
   - checks independently run;
   - result;
   - limitations.
6. Compare each output with the accepted historical record. Distinguish:
   accepted-finding detection, missed accepted findings, unsupported new
   findings, severity/confidence quality, evidence quality, smallest-fix
   quality, and correct repaired-candidate `PASS` results.
7. Make only evidence-driven playbook corrections. If misses or unsupported
   findings result from reviewer limits, historical context that was
   intentionally withheld, or case-specific complexity rather than playbook
   wording, record that no playbook correction is justified.
8. If the playbook is corrected, rerun every affected case with the corrected
   revision and record the prior and replacement playbook revisions.

## Case catalog

The accepted findings and disposition links in this section are the evaluation
answer key. Do not include them in fresh-context reviewer briefs.

### RVCASE-52A: field coverage and mutation effectiveness

- Governing issue: [#45](https://github.com/jaharris87/XNet/issues/45).
- Historical PR: [#52](https://github.com/jaharris87/XNet/pull/52).
- Historical base:
  `c526d680132cd35f77ecf38a9d9698ca93c3bfb6`.
- Defective candidate:
  `30333f54074fdd05d632842dded200557579d06a`.
- Repair candidate:
  `32807caa89a4e3f136424f0707f239a3579fdf49`.
- Useful repaired `PASS` counterexample:
  `e11c21ebe8d4771f6fe0d291e5e030b0361b7d42`, with final
  documentation-only update
  `fd56813579e9938fc83ece43a8f47b2e6c9f2353`.
- Expected risk classes: `T`, `P`, `B`.
- Expected role: test effectiveness, with build/portability/concurrency only
  where needed for the qualification claim.
- Minimum supplied context:
  - issue #45 body;
  - `review-playbook.md` at `5395b1e`;
  - diff `c526d680..30333f5`;
  - `source/xnet_evolve.F90`;
  - `source/xnet_integrate_be.F90`;
  - `test/qualification/parallel_zones.py`;
  - `test/qualification/test_parallel_zones.py`; and
  - `test/qualification/parallel_zones/` fixture files.
- Accepted findings:
  - ASCII endpoint comparison omitted energy-generation and neutrino-loss
    fields named by the qualification claim.
  - A claimed zero-status mutation was not actually exercised.
  - The tracked `control` fixture was ignored before the repair.
- Disposition and verification:
  - PR #52 body records the fixed field comparison and mutation checks.
  - [Final review record](https://github.com/jaharris87/XNet/pull/52#issuecomment-5226786001)
    verified the accepted findings resolved at `e11c21e`.

### RVCASE-52B: requested topology and executable substitution

- Governing issue: [#45](https://github.com/jaharris87/XNet/issues/45).
- Historical PR: [#52](https://github.com/jaharris87/XNet/pull/52).
- Historical base:
  `c526d680132cd35f77ecf38a9d9698ca93c3bfb6`.
- Defective candidate:
  `32807caa89a4e3f136424f0707f239a3579fdf49`.
- Repair candidate:
  `e11c21ebe8d4771f6fe0d291e5e030b0361b7d42`.
- Useful repaired `PASS` counterexample:
  `fd56813579e9938fc83ece43a8f47b2e6c9f2353`.
- Expected risk classes: `T`, `P`, `B`.
- Expected role: build/portability/concurrency and provenance/operational
  evidence.
- Minimum supplied context:
  - issue #45 body;
  - `review-playbook.md` at `5395b1e`;
  - diff `c526d680..32807ca`;
  - `test/qualification/parallel_zones.py`;
  - `test/qualification/test_parallel_zones.py`; and
  - relevant production diagnostic formats.
- Accepted finding:
  - Passing the serial executable as `--openmp-executable` could satisfy the
    comparison because output equality did not prove the requested OpenMP
    topology.
- Disposition and verification:
  - PR #52 body records an adversarial serial-as-OpenMP failure.
  - [Final review record](https://github.com/jaharris87/XNet/pull/52#issuecomment-5226786001)
    verified topology records at `e11c21e`.
  - [MPI binding follow-up](https://github.com/jaharris87/XNet/pull/52#issuecomment-5227292763)
    verified `fd56813` remained clear.

### RVCASE-54A: scientific identity, build prerequisite, and parser contracts

- Governing issue: [#41](https://github.com/jaharris87/XNet/issues/41).
- Historical PR: [#54](https://github.com/jaharris87/XNet/pull/54).
- Historical base:
  `65271bcbeea430534c1adc92748ef13bea10c228`.
- Defective candidate:
  `61ab3c920b3376e4734648a0da55cf103af722cb`.
- Repair candidate:
  `147f3e6eb6e5e33a2d95b4758219188c5cfce093`.
- Useful repaired `PASS` counterexample:
  `147f3e6eb6e5e33a2d95b4758219188c5cfce093`.
- Expected risk classes: `S`, `T`, `B`.
- Expected role: scientific/numerical behavior, test effectiveness,
  build/portability/concurrency, and provenance/operational evidence.
- Minimum supplied context:
  - issue #41 body;
  - `review-playbook.md` at `5395b1e`;
  - diff `65271bc..61ab3c9`;
  - `test/unit/Makefile`;
  - `test/unit/test_nse_scientific_validation.F90`;
  - `test/unit/support/nse_validation_support.F90`;
  - `test/nse_validation/extract_inputs.py`;
  - `test/nse_validation/generate_reference.py`;
  - `test/nse_validation/reference_solver.py`;
  - `test/nse_validation/test_reference_tooling.py`;
  - `test/build_net/partf_module.f90`; and
  - retained `test/nse_validation/reference.json` and `reference.dat`.
- Accepted findings:
  - A delayed clean parallel build failed because `testdrive.mod` lacked an
    explicit prerequisite.
  - Fortran reference identity carried species names but not `(A,Z,N)`.
  - Unrelated malformed mass rows containing `#` were skipped too broadly.
  - Retained residual changes did not affect the scientific fingerprint.
- Disposition and verification:
  - [Independent review record](https://github.com/jaharris87/XNet/pull/54#issuecomment-5236161792)
    records fixes and re-review of `147f3e6`.

### RVCASE-54B: mutable preflight evidence

- Governing issue: [#41](https://github.com/jaharris87/XNet/issues/41).
- Historical PR: [#54](https://github.com/jaharris87/XNet/pull/54).
- Historical base:
  `65271bcbeea430534c1adc92748ef13bea10c228`.
- Defective candidate:
  `66e3ee7399e522011aae17fc714a942511f47041`.
- Repair candidate:
  `742b3c9ff1680f09987f71858d414e31c03eff41`.
- Useful repaired `PASS` counterexample:
  `742b3c9ff1680f09987f71858d414e31c03eff41`.
- Expected risk classes: `S`, `T`.
- Expected role: provenance/operational evidence and scientific/numerical
  behavior.
- Minimum supplied context:
  - issue #41 body;
  - `review-playbook.md` at `5395b1e`;
  - diff `65271bc..66e3ee7`;
  - `test/nse_validation/preflight_states.py`;
  - `test/nse_validation/test_reference_tooling.py`; and
  - generated preflight output schema in `reference.json`.
- Accepted finding:
  - The non-gating preflight solved one manifest but later reloaded its path,
    so a post-analysis rewrite could attach a new fingerprint to stale
    compositions.
- Disposition and verification:
  - [Final disposition](https://github.com/jaharris87/XNet/pull/54#issuecomment-5242235599)
    records immutable in-memory snapshots and controlled rewrite rejection at
    `742b3c9`.

### RVCASE-59A: duplicate executable substitution

- Governing issue: [#44](https://github.com/jaharris87/XNet/issues/44).
- Historical PR: [#59](https://github.com/jaharris87/XNet/pull/59).
- Historical base:
  `9ae2e0d4c8eb57f8092ad8a6fb33fda610352eb0`.
- Defective candidate:
  `a21eeb1c9b0f24af9b2d91edb59e6dd7344a841a`.
- Repair candidate:
  `e8a65079f8d970d65f84f504cb9a8228c224a1c8`.
- Useful repaired `PASS` counterexample:
  `e8a65079f8d970d65f84f504cb9a8228c224a1c8`.
- Expected risk classes: `T`, `B`, `P`.
- Expected role: test effectiveness, build/portability/concurrency, and
  provenance/operational evidence.
- Minimum supplied context:
  - issue #44 body;
  - `review-playbook.md` at `5395b1e`;
  - diff `9ae2e0d..a21eeb1`;
  - `test/qualification/sparse_backends/compare_heat_sn160.py`;
  - `test/unit/run_real_sparse_contracts.sh`;
  - `test/unit/test_sparse_contracts.F90`;
  - `test/regression/xnet_regression.py`; and
  - relevant sparse-backend README text.
- Repair-candidate additional context:
  - diff `9ae2e0d..e8a6507`; and
  - `test/qualification/sparse_backends/test_compare_heat_sn160.py`, which is
    present at `e8a6507` but absent at `a21eeb1`.
- Accepted findings:
  - The same executable content could be supplied as both dense and sparse
    executables.
  - Durable evidence was incomplete until the repair recorded exact hosts,
    link selections, statuses, residual maxima, hashes, comparison quantities,
    and cleanup/archive evidence.
- Disposition and verification:
  - [Disposition comment](https://github.com/jaharris87/XNet/pull/59#issuecomment-5243414536)
    records equal SHA-256 rejection and re-review at `e8a6507`.

### RVCASE-60A: manifest false success and built-source binding

- Governing issue: [#46](https://github.com/jaharris87/XNet/issues/46).
- Historical PR: [#60](https://github.com/jaharris87/XNet/pull/60).
- Historical base:
  `9ae2e0d4c8eb57f8092ad8a6fb33fda610352eb0`.
- Defective candidate:
  `7c7ec32321eca5f40daedc2738888fffb2428210`.
- Repair candidate:
  `f35fcc211434917105fe76cef4347edbef89441b`.
- Useful repaired `PASS` counterexample:
  `581656cfab3d472323001d255ff308746e49ed68`, evidence-only over qualified
  source `97174bc0b382ed2c580eb517b05479e0ee63b184`.
- Expected risk classes: `H`, `T`, `B`, `P`.
- Expected role: provenance/operational evidence and
  build/portability/concurrency.
- Minimum supplied context:
  - issue #46 body;
  - `review-playbook.md` at `5395b1e`;
  - diff `9ae2e0d..7c7ec32`;
  - `test/qualification/frontier/frontier_qualification.py`;
  - `test/qualification/frontier/submit_frontier.py`;
  - `test/qualification/frontier/frontier_job.sh`;
  - `test/qualification/frontier/manifest.schema.json`;
  - `test/qualification/test_frontier_qualification.py`; and
  - retained evidence manifest and review note for job 5230728.
- Accepted findings:
  - The manifest validator could accept false successful evidence with
    missing, failed, duplicate, unsafe, or contradictory records.
  - The archive hash did not bind the source tree actually built after queue
    wait and extraction.
- Disposition and verification:
  - [Original findings](https://github.com/jaharris87/XNet/pull/60#issuecomment-5248191094)
    and [disposition](https://github.com/jaharris87/XNet/pull/60#issuecomment-5248343624)
    record fixes at `f35fcc2`.

### RVCASE-60B: self-authorizing numerical and nested evidence

- Governing issue: [#46](https://github.com/jaharris87/XNet/issues/46).
- Historical PR: [#60](https://github.com/jaharris87/XNet/pull/60).
- Historical base:
  `9ae2e0d4c8eb57f8092ad8a6fb33fda610352eb0`.
- Defective candidate:
  `f35fcc211434917105fe76cef4347edbef89441b`.
- Repair candidate:
  `97174bc0b382ed2c580eb517b05479e0ee63b184`.
- Useful repaired `PASS` counterexample:
  `581656cfab3d472323001d255ff308746e49ed68`.
- Expected risk classes: `H`, `T`, `B`, `S`.
- Expected role: scientific/numerical behavior and provenance/operational
  evidence.
- Minimum supplied context:
  - issue #46 body;
  - `review-playbook.md` at `5395b1e`;
  - diff `9ae2e0d..f35fcc2`;
  - `test/qualification/frontier/frontier_qualification.py`;
  - `test/qualification/frontier/comparison_policy.json`;
  - `test/qualification/frontier/manifest.schema.json`;
  - `test/qualification/test_frontier_qualification.py`; and
  - retained v1 manifest/review note where relevant.
- Accepted findings:
  - Validation trusted reported `allowed`, maximum-ratio, and
    selected-species fields instead of recomputing from tracked policy and raw
    observations.
  - Nested size/hash claims were not compared with authoritative inventory
    records.
  - JSON Schema and runtime validation disagreed about failure envelopes.
  - Pre-extraction source-failure classification used the wrong stream.
- Disposition and verification:
  - [Re-review findings](https://github.com/jaharris87/XNet/pull/60#issuecomment-5248382827)
    and [disposition](https://github.com/jaharris87/XNet/pull/60#issuecomment-5248417864)
    record fixes at `97174bc`.
  - [Final evidence review](https://github.com/jaharris87/XNet/pull/60#issuecomment-5248536872)
    records `PASS` at evidence-only head `581656c`.

### RVCASE-66A: scientific identity and provenance-only inputs

- Governing issue: [#41](https://github.com/jaharris87/XNet/issues/41).
- Historical PR: [#66](https://github.com/jaharris87/XNet/pull/66).
- Historical routing note: PR #66 was opened as a reopened preservation
  repair within the #46/#36 integration path, but the candidate files identify
  the NSE validation authority as issue #41. Fresh case reviews should use
  issue #41, not the Frontier-qualification text from issue #46.
- Historical base:
  `ae2197861eb4996fd6dfa283432533dcf65a07d7`.
- Defective candidate:
  `d8ebc841eaee20b9d12c757d48ac1f004ff3533f`.
- Repair candidate:
  `5c16d9809d5b760bcca4401130f716dd3f4db8cc`.
- Useful repaired `PASS` counterexample:
  `5c16d9809d5b760bcca4401130f716dd3f4db8cc`.
- Expected risk classes: `S`, `T`.
- Expected role: scientific/numerical behavior and provenance/operational
  evidence.
- Minimum supplied context:
  - issue #41 body;
  - `review-playbook.md` at `5395b1e`;
  - diff `ae21978..d8ebc84`;
  - `test/nse_validation/README.md`;
  - `test/nse_validation/extract_inputs.py`;
  - `test/nse_validation/generate_reference.py`;
  - `test/nse_validation/reference.json`; and
  - `test/nse_validation/test_reference_tooling.py`.
- Accepted findings:
  - The scientific fingerprint included constant `source_lexeme`, so an
    equivalent literal spelling with the same compiled binary64 value changed
    identity.
  - Full species records included reconciliation-only `mass_source`
    annotations, so otherwise identical calculation inputs changed identity.
  - Current extractor/generator source hashes were allowed to remain stale
    while tests accepted any 64-hex value, so generation provenance was not
    exactly bound to the candidate source until the historical/current split
    was made explicit.
  - README byte-comparison instructions and historical hash naming became
    misleading once current provenance could differ from frozen generation
    provenance.
- Disposition and verification:
  - [Findings](https://github.com/jaharris87/XNet/pull/66#issuecomment-5248782267)
    and [disposition](https://github.com/jaharris87/XNet/pull/66#issuecomment-5248834389)
    record fixes and re-review at `5c16d98`.

## Initial evaluation record

The initial run used fresh-context internal subagents with no inherited thread
context. Each subagent was instructed to work read-only, use only the supplied
context boundary, and avoid PR bodies, PR comments, later commits, repair
explanations, prior findings, disposition records, favorable summaries, and
cross-review results. The tool exposes the session class as an internal
subagent. For the initial inherited sessions it did not expose the concrete
model or effort, so those fields are recorded as inherited/not exposed rather
than invented.

The defective-candidate and repaired-candidate summaries below are the initial
evaluation result. Full private reasoning was not requested or retained.

### Defective-candidate results

| Review ID | Candidate | Result | Accepted finding detection | Missed accepted findings | Unsupported new findings | Quality and limitations |
| --- | --- | --- | --- | --- | --- | --- |
| EVAL-52A | `30333f5` | `TST-001`, `TST-002` | Detected the missing tracked `control` fixture and incomplete final ASCII field coverage. This covers the accepted ignored-fixture and omitted-energy-field classes. | It did not separately identify the unexercised zero-status mutation claim. | Broadened omitted-field coverage to binary content, `kmon`, diagnostic step, and counters. These are reasonable review questions but not preserved accepted findings for this seed. | High-confidence static evidence from `git ls-tree`, `git show`, and runner/source inspection. No builds or qualification runs. |
| EVAL-52B | `32807ca` | `BLD-001`, `PRO-001` | Detected that serial or otherwise wrong executables could pass because requested MPI/OpenMP topology was not proved. | None for the selected accepted topology case. | Reported missing candidate/executable/environment manifesting. This is plausible, but the preserved accepted finding for this seed was the topology false pass. | High-confidence source evidence. No builds or qualification runs. |
| EVAL-54A | `61ab3c9` | `BLD-001` | Detected the missing `testdrive.mod` prerequisite through an actual clean object-build failure in a temporary candidate archive. | Missed names-only `(A,Z,N)` identity, overly broad malformed `#` row handling, and missing residuals in the scientific fingerprint. | None. | Strong build evidence. Review stopped after the reproduced build failure and did not complete all scientific/provenance false-pass probes. |
| EVAL-54B | `66e3ee7` | `PASS` | None. | Missed mutable non-gating preflight evidence: the reviewer regenerated retained references and inspected preflight code, but did not complete the full preflight rerun or construct the post-analysis rewrite counterexample. | None. | Medium confidence for preflight because the full 7852-species rerun was interrupted after about 90 seconds. |
| EVAL-59A | `a21eeb1` | `PRO-001`, `TST-001` | Detected duplicate executable substitution for the dense/sparse comparison. | Durable-evidence incompleteness was only partly covered through provider/executable provenance. | Reported residual-mutation intended-reason validation as a merge blocker. That was not preserved as an accepted #59 finding. | High-confidence static evidence from candidate-local files. No real MA48/oneMKL runs. The formal review found that the first catalog incorrectly listed a repair-only pytest file for this defective SHA; the corrected rerun did not use that file and reached the same two findings. |
| EVAL-60A | `7c7ec32` | `PRO-001`, `PRO-002` | Detected false-success manifest validation. Also detected the exact-candidate/run binding gap for the retained run source. | Did not independently enumerate every accepted false-success subcase, but the validator counterexamples covered wrong source, excessive residual, missing GPU batches, failed nested endpoint, and one-item inventory. | The exact-candidate/run mismatch was an accepted pending evidence gate rather than the main preserved defect for this case. | Strong code and local validator-mutation evidence. No Frontier rerun. |
| EVAL-60B | `f35fcc2` | `PRO-001`, `SCI-001`, `PRO-002`, `PRO-003` | Detected self-authorizing numerical limits, nested inventory hash/size mismatch, schema/runtime failure-envelope disagreement, and wrong stream for source-failure classification. | None for the selected accepted validation cases. | Reported missing v2 exact-candidate retained evidence, which was a known pending gate at `f35fcc2`, not a playbook-detection defect. | High-confidence static evidence. No Frontier rerun; one attempted checkout-based validator command was non-authoritative because the live checkout was not the candidate. |
| EVAL-66A | `d8ebc84` | `SCI-001` | Detected scientific identity coupled to equivalent constant spelling and reconciliation-only annotations. | Documentation/reproducibility wording and historical-hash naming were not separately reported. | None. | High-confidence controlled mutation in a temporary candidate archive. This first run used issue #46 and a too-specific identity focus; the corrected issue #41 rerun below supersedes it for case scoring. |

### Repair-SHA and repaired-PASS results

Exact repair SHAs are intentionally recorded even when they are not useful
`PASS` counterexamples. Some historical repair commits fixed one accepted
finding but still carried a later distinct defect, while some final accepted
states were evidence-only heads over an already-qualified source SHA.

| Review ID | Candidate | Candidate type | Result | Correct repaired `PASS`? | False positives, detection, and limitations |
| --- | --- | --- | --- | --- | --- |
| RERUN-52A-REPAIR | `32807ca` | Exact repair for RVCASE-52A; defective candidate for RVCASE-52B | `TST-001`, `TST-002` | No. It is not a clean counterexample because it correctly exposes the later topology and failure-probe issues. | Detected the RVCASE-52B topology/failure-intent class. No builds or MPI/OpenMP qualification run. |
| PASS-52A | `e11c21e` | Useful `PASS` counterexample for RVCASE-52A | `PASS` | Yes. It found no consequential test-effectiveness issue and noted coverage of topology, output inventory, ASCII `dE/dt`/`sqnu`/timestep fields, OpenMP repetition, and focused helper negatives. | None. Read-only static review; no builds or MPI/OpenMP qualification run. |
| RERUN-52B-REPAIR | `e11c21e` | Exact repair for RVCASE-52B | `BLD-001`, `PRO-001` | No. | Reported serial-reference topology and non-root failure-reason concerns. Those are unsupported new findings for this seed because the preserved accepted #52B defect was serial-as-OpenMP substitution, and the historical final review accepted `e11c21e` for that case. |
| PASS-52B | `fd56813` | Later documentation-only useful counterexample for RVCASE-52B | `BLD-001` | No. | Reported the same serial-reference topology concern; treated as a repaired-candidate false positive for this seed. Static review only. |
| PASS-54A | `147f3e6` | Exact repair and useful `PASS` counterexample for RVCASE-54A | `PASS` | Yes. It found no consequential scientific, test, build, or provenance issue and checked retained hashes, identity uniqueness, and Python tooling tests. | None. Did not run compiled Fortran tests in the read-only context. |
| PASS-54B | `742b3c9` | Exact repair and useful `PASS` counterexample for RVCASE-54B | `PASS` | Yes. It found no consequential preflight/provenance issue and confirmed immutable reference/provenance surfaces and post-analysis rewrite protection by inspection. | None. Did not rerun full preflight, reference generation, or optional pynucastro corroboration. |
| PASS-59A | `e8a6507` | Exact repair and historically accepted useful counterexample for RVCASE-59A | `PASS` | Yes for this invocation. | It found no consequential sparse qualification issue and noted identical-executable rejection plus bounded support claims. Real MA48/oneMKL dependencies were unavailable. |
| RERUN-59A-REPAIR | `e8a6507` | Corrected repair rerun after fixing candidate-local context | `PRO-001`, `TST-001` | No. | Reported broader same-source manifest and residual-mutation reason checks. These are unsupported new findings for the historical seed; the preserved PR #59 record accepted `e8a6507` after documenting exact host, link, status, residual, hash, and cleanup/archive evidence. |
| RERUN-60A-REPAIR | `f35fcc2` | Exact repair for RVCASE-60A; defective candidate for RVCASE-60B | `PRO-001`, `PRO-002`, `PRO-003` | No. | Correctly exposed stale v1 evidence and validation holes that were later part of RVCASE-60B or pending evidence gates. No Frontier rerun. |
| RERUN-60B-REPAIR | `97174bc` | Exact repair for RVCASE-60B before final evidence-only head | `PRO-001` | No. | Correctly found the retained evidence did not validate against the exact repair candidate because the final Frontier evidence was added later at `581656c`. No Frontier rerun. |
| PASS-60A | `581656c` | Evidence-only useful counterexample over qualified source `97174bc` | `PRO-001` | No for this invocation. | Reported that the evidence-only head was not itself the Frontier run source. The preserved historical record accepted this relationship because `581656c` adds retained evidence for qualified source `97174bc`; withholding that explanation caused the false positive. |
| PASS-60B | `581656c` | Evidence-only useful counterexample over qualified source `97174bc` | `PASS` | Yes. It distinguished the evidence-only head from the qualified run source by inspecting ancestry and found the v2 retained evidence sufficient under the assigned scientific/provenance role. | None. No Frontier rerun; current checkout was the playbook revision. |
| RERUN-66A-REPAIR | `5c16d98` | Exact repair and useful `PASS` counterexample for RVCASE-66A | `PASS` | Yes. | Corrected rerun used issue #41. It ran 13 candidate tooling tests in a temporary archive and confirmed scientific identity stayed stable while canonical historical provenance remained distinct. |

### Invocation details

All evaluations used this invocation class unless otherwise stated:
fresh-context internal subagent, no inherited thread context, read-only,
inherited model and effort not otherwise exposed by the tool. The common
playbook revision was `5395b1ed117536787d26871c3dc7d03e559aaedd`.

| Review ID | Commands and output summary | Result quality notes |
| --- | --- | --- |
| EVAL-52A | Read issue #45 body; read `review-playbook.md`; ran `git diff --stat`, `git diff --name-status`, `git ls-tree`, `git show`, and targeted source/runner inspection. `git show 30333f5:test/qualification/parallel_zones/control` failed because the file was absent. | Severity/confidence high for missing fixture and omitted fields. Smallest fixes were bounded to adding the fixture and extending comparator coverage. |
| EVAL-52B | Read issue #45 body and playbook; ran `git diff --stat`, `git diff --name-status`, `git diff`, `git show`, `git grep`, and line-numbered inspection. | Severity/confidence high for topology substitution. Manifesting recommendation was broader than the preserved finding. |
| EVAL-54A | Read issue #41 body and playbook; inspected candidate files; regenerated reference in `/private/tmp`; ran Python tooling tests in a temporary candidate copy; clean object build failed with `Cannot open module file 'testdrive.mod'`. | Build finding was directly reproduced. Misses show one reviewer can stop after a blocking build defect and leave other role questions unexplored. |
| EVAL-54B | Read issue #41 body and playbook; ran `git diff --check`; inspected NSE tooling; regenerated retained reference from candidate archive; attempted full preflight but interrupted it after about 90 seconds. | Returned `PASS` with medium preflight confidence, causing one missed accepted finding. |
| EVAL-59A | Read issue #44 body and playbook; inspected sparse qualification script, tests, real sparse runner, Makefile, and PARDISO adapter with `git diff`, `git show`, and `git grep`. | Detected the duplicate-executable false pass. Added one unsupported intended-reason mutation concern. |
| EVAL-60A | Read issue #46 body and playbook; inspected Frontier runner, submitter, README, manifest, review note, and build diffs; computed retained manifest SHA; imported candidate validator and tried controlled mutants. Wrong source SHA, large residual, missing GPU batches, failed nested endpoint status, and one-item inventory were accepted. | Strong direct evidence for false-success validation and candidate/run binding. |
| EVAL-60B | Read issue #46 body and playbook; inspected Frontier validator, schema, retained manifest/review, submission/job scripts, tests, and accelerator diffs; identified non-authoritative checkout validator failure. | Detected every selected accepted #60B class. |
| EVAL-66A | Read issue #46 body and playbook; inspected NSE identity files; ran controlled mutations in a temporary archive showing equivalent source spelling and reconciliation-only annotations changed identity while physical mass change was detected. | Direct controlled evidence. Issue-body mismatch was a case-context limitation. |
| PASS-52A | Read issue #45 body and playbook; inspected production and qualification files; no build or qualification run. | Correct `PASS` with field, topology, inventory, repetition, and negative-probe coverage observed by inspection. |
| PASS-52B | Read issue #45 body and playbook; inspected final runner and production fixes; ran `git diff --check`. | False positive on serial-topology validation when prior accepted historical concern was serial-as-OpenMP substitution. |
| PASS-54A | Read issue #41 body and playbook; inspected NSE files; ran `git diff --check`; checked retained SHA-256 values and Python tooling tests; verified 489 unique `(A,Z,N)` identities. | Correct `PASS`; compiled Fortran tests were not run. |
| PASS-54B | Read issue #41 body and playbook; inspected NSE reference and preflight files; checked retained JSON/hash surfaces and identity uniqueness. | Correct `PASS`; no full preflight rerun. |
| PASS-59A | Read issue #44 body and playbook; inspected sparse backend docs/tooling/tests and PARDISO adapter; ran `git diff --check`; checked oneMKL handle allocation/indexing by `git grep`. | Correct `PASS`; real-library runs unavailable. |
| PASS-60A | Read issue #46 body and playbook; inspected Frontier retained evidence and searched for `581656c` in the retained package. | False positive on evidence-only head/run-source separation because the withheld final review record accepted that relationship. |
| PASS-60B | Read issue #46 body and playbook; inspected v2 manifest with `jq`; checked run-source ancestry to evidence-only head; reviewed retained residuals, zone coverage, nonzero neutrino loss, build/link evidence, and inventory. | Correct `PASS`; no Frontier rerun. |
| PASS-66A | Read issue #46 body and playbook; inspected NSE identity diff; confirmed `reference.dat` unchanged; ran 13 candidate tooling tests in a temporary archive. | Correct `PASS`, but issue-body mismatch was a case-context limitation. Superseded for scoring by corrected issue #41 rerun. |

Correction reruns were launched after formal draft-PR review identified
case-context and repair-SHA gaps. They used no inherited thread context,
read-only instructions, the same playbook revision, and the corrected supplied
context listed below.

| Review ID | Session/model/effort | Commands and output summary | Result quality notes |
| --- | --- | --- | --- |
| RERUN-52A-REPAIR | Fresh-context internal subagent; inherited model/effort not exposed | Read issue #45 body and playbook; inspected `c526d680..32807ca` and candidate files. | Correctly detected topology and failure-intent defects because this exact repair later became RVCASE-52B. |
| RERUN-52B-REPAIR | Fresh-context internal subagent; inherited model/effort not exposed | Read issue #45 body and playbook; ran `git diff --stat/name-status/check`; inspected `c526d680..e11c21e`. | Reported serial-reference topology and non-root failure-reason concerns; treated as unsupported new findings for this seed. |
| RERUN-59A-DEFECTIVE | Fresh-context internal subagent; inherited model/effort not exposed | Read issue #44 body and playbook; inspected `9ae2e0d..a21eeb1`. `git grep compare_heat_sn160 -- test` found only README references, confirming the repair-only pytest was absent. | Corrected context still detected duplicate executable substitution and the residual-mutation intended-reason concern. |
| RERUN-59A-REPAIR | Fresh-context internal subagent; inherited model/effort not exposed | Read issue #44 body and playbook; inspected `9ae2e0d..e8a6507`; ran `git diff --check` with no output. | Reported broader same-source/provenance and mutation-reason findings; treated as unsupported new findings for this seed. |
| RERUN-60A-REPAIR | Fresh-context internal subagent; inherited model/effort not exposed | Read issue #46 body and playbook; inspected `9ae2e0d..f35fcc2`, v1/v2 schema differences, retained manifest source fields, and validator behavior. | Correctly showed this exact repair still lacked final retained evidence and retained RVCASE-60B validation defects. |
| RERUN-60B-REPAIR | Fresh-context internal subagent; inherited model/effort not exposed | Read issue #46 body and playbook; inspected `9ae2e0d..97174bc`, retained manifest/schema, and heat evidence keys. | Correctly showed the final evidence-only head was still needed before repaired-candidate `PASS`. |
| RERUN-66A-WRONG-ISSUE | Fresh-context internal subagent; inherited model/effort not exposed | Read issue #46 body and playbook; inspected `ae21978..d8ebc84` and `ae21978..5c16d98`. | Not scored. The repair-side reviewer correctly rejected the mismatch because issue #46 describes Frontier qualification while the candidate files implement issue #41. |
| RERUN-66A-DEFECTIVE | Fresh-context internal subagent; model exposed as GPT-5-based Codex; effort not exposed | Read issue #41 body and playbook; inspected `ae21978..d8ebc84`; computed candidate extractor/generator hashes and compared them to retained hashes. | Detected accepted scientific identity and stale-provenance classes with high-confidence source/hash evidence. |
| RERUN-66A-REPAIR | Fresh-context internal subagent; model exposed as GPT-5-based Codex; effort not exposed | Read issue #41 body and playbook; inspected `ae21978..5c16d98`; archived the candidate to `/private/tmp`; ran `python3 -B test/nse_validation/test_reference_tooling.py`, 13 tests OK; compared retained/current scientific and canonical hashes. | Correct `PASS`; no false positives. |

### Finding quality assessment

| Finding | Reported severity | Reported confidence | Severity quality | Confidence quality | Evidence quality | Smallest-fix quality |
| --- | --- | --- | --- | --- | --- | --- |
| EVAL-52A `TST-001` missing tracked fixture | Merge-blocking | High | Matched accepted ignored-fixture defect. | Supported by direct candidate-tree inspection. | Direct absent-path evidence from candidate tree and runner behavior. | Bounded and appropriate: add the fixture and require it in staging. |
| EVAL-52A `TST-002` omitted ASCII fields | Merge-blocking | High | Matched omitted claimed endpoint fields. | Supported by direct comparator/source inspection. | Direct comparator/source evidence. | Bounded and appropriate: extend comparison to the claimed `dE/dt`, `sqnu`, and timestep fields. |
| EVAL-52B `BLD-001` topology substitution | Merge-blocking | High | Matched the accepted serial-as-OpenMP false pass. | Supported by direct runner and diagnostic-format inspection. | Direct source evidence. | Bounded and appropriate: require observed MPI/OpenMP topology and adversarial helper tests. |
| EVAL-52B `PRO-001` manifesting | Not recorded | Not recorded | Not assessable; broader than the preserved accepted #52 finding. | Not assessable. | Plausible evidence gap, but not an accepted seed finding. | Broader than necessary for the selected case. |
| EVAL-54A `BLD-001` `testdrive.mod` prerequisite | Merge-blocking | High | Matched accepted clean-build defect. | Supported by reproduced build failure. | Strong command evidence from clean object build failure. | Bounded and appropriate: add explicit Makefile prerequisite. |
| EVAL-59A `PRO-001` duplicate executable substitution | Merge-blocking | High | Matched accepted duplicate-executable finding. | Supported by direct runner/hash inspection. | Direct argument/runner/hash evidence. | Bounded and appropriate: reject identical executable content before staging and add a negative test. |
| EVAL-59A `TST-001` residual mutation reason | Merge-blocking | High | Overstated for this seed; not part of preserved #59 disposition. | Supported as a plausible hardening concern. | Real static evidence from the residual-mutation wrapper. | Useful hardening suggestion, but not required for the retained case. |
| EVAL-60A `PRO-001` false-success manifest validation | Merge-blocking | High | Matched accepted false-success class. | Supported by validator-mutation evidence. | Strong direct evidence from controlled validator mutations. | Bounded and appropriate: reject missing, failed, duplicate, unsafe, or contradictory records. |
| EVAL-60A `PRO-002` built-source binding | Merge-blocking | High | Matched accepted source/run binding defect. | Supported by manifest/archive/source evidence. | Direct retained-manifest and archive evidence. | Bounded and appropriate: bind extracted tree and build/run evidence to the exact candidate. |
| EVAL-60B `PRO-001` self-authorizing numerical limits | Merge-blocking | High | Matched accepted numerical-limit validation defect. | Supported by static validator/policy inspection. | Direct schema, validator, and retained-manifest evidence. | Bounded and appropriate: recompute limits from tracked policy and raw observations. |
| EVAL-60B `SCI-001` retained evidence completeness | Merge-blocking | High | Matched high-impact retained-evidence gap for the exact repair state. | Supported by retained-manifest/source inspection. | Direct retained-manifest evidence. | Bounded and appropriate: retain candidate-bound v2 evidence. |
| EVAL-60B `PRO-002` nested inventory mismatch | Merge-blocking | High | Matched accepted nested inventory defect. | Supported by validator/inventory inspection. | Direct nested-claim versus inventory evidence. | Bounded and appropriate: compare nested size/hash claims to authoritative inventory entries. |
| EVAL-60B `PRO-003` schema/runtime and stream classification | Merge-blocking | High | Matched accepted failure-envelope and stream-classification defects. | Supported by schema/runtime/source inspection. | Direct schema and failure-stream evidence. | Bounded and appropriate: align schema/runtime envelopes and classify source failures from the correct stream. |
| EVAL-66A `SCI-001` scientific identity | Not recorded | Not recorded | Not assessable for the initial invocation; superseded for scoring because it used issue #46 and a too-specific identity focus. | Not assessable. | Direct controlled-mutation evidence, but collected under mismatched issue context. | Appropriate in substance: exclude source spelling and reconciliation-only annotations from scientific identity. |
| RERUN-52A-REPAIR `TST-001` topology evidence | Merge-blocking | High | Correct for the later RVCASE-52B defect; not a clean RVCASE-52A `PASS`. | Supported by candidate runner and diagnostics. | Direct source and diagnostic-format evidence. | Bounded and appropriate: require exact MPI/OpenMP worker diagnostics. |
| RERUN-52A-REPAIR `TST-002` non-root failure intent | Merge-blocking | High | Correct as a later failure-probe concern; outside RVCASE-52A's original accepted finding. | Supported by static runner evidence. | Direct failure-probe source evidence. | Bounded and appropriate: validate intended missing-input reason and rank. |
| RERUN-52B-REPAIR `BLD-001` serial-reference topology | Merge-blocking | High | Over-classified relative to accepted historical record. | Supported by source evidence, but outside preserved #52B false pass. | Specific static source evidence. | Larger than necessary for the retained case. |
| RERUN-52B-REPAIR `PRO-001` non-root failure reason | Consequential non-blocking | Medium | Non-blocking classification was proportionate, but outside the preserved seed finding. | Supported by static source evidence. | Specific failure-probe source evidence. | Larger than necessary for the retained case. |
| PASS-52B `BLD-001` serial topology | Not recorded | Not recorded | Not assessable; treated as a repaired-candidate false positive for this seed. | Not assessable. | Static source evidence, but contradicted by preserved final acceptance. | Broader than the accepted serial-as-OpenMP repair requirement. |
| RERUN-59A-DEFECTIVE `PRO-001` duplicate executable substitution | Merge-blocking | High | Matched accepted duplicate-executable finding after candidate-local context correction. | Supported by direct runner/source inspection. | Direct argument/runner/hash evidence. | Bounded and appropriate: reject duplicate dense/sparse executable content. |
| RERUN-59A-DEFECTIVE `TST-001` mutation reason | Merge-blocking | High | Overstated for the retained #59 seed. | Supported as a real intended-reason concern. | Direct wrapper/source evidence. | Useful hardening suggestion, not required for the retained case. |
| RERUN-59A-REPAIR `PRO-001` same-source/provider binding | Merge-blocking | High | Over-classified relative to accepted historical record. | Supported by source evidence; withheld PR evidence explains historical acceptance. | Specific comparison-runner evidence. | Broader than the retained #59 repair requirement. |
| RERUN-59A-REPAIR `TST-001` mutation reason | Consequential non-blocking | High | Proportionate as a hardening concern, but outside preserved #59 disposition. | Supported by static wrapper evidence. | Specific residual-mutation wrapper evidence. | Useful hardening suggestion, not required for the retained case. |
| RERUN-60A-REPAIR `PRO-001` stale v1 evidence | Merge-blocking | High | Correct; exact repair SHA was not yet a useful `PASS` counterexample. | Supported by manifest/schema inspection. | Direct retained-manifest source/schema evidence. | Bounded and appropriate: rerun/retain v2 evidence bound to exact SHA. |
| RERUN-60A-REPAIR `PRO-002` self-authorizing limits | Merge-blocking | High | Correct; maps to RVCASE-60B validation defect. | Supported by validator/policy inspection. | Direct endpoint-evidence validation evidence. | Bounded and appropriate: recompute all allowed bounds and maxima from tracked policy and raw values. |
| RERUN-60A-REPAIR `PRO-003` nested artifact claims | Merge-blocking | Medium-high | Correct; maps to RVCASE-60B nested-inventory defect. | Supported by validator/inventory inspection. | Direct nested artifact claim evidence. | Bounded and appropriate: require nested artifact claims to match inventory size/hash entries. |
| RERUN-60B-REPAIR `PRO-001` stale retained evidence | Merge-blocking | High | Correct; final evidence-only head was still needed before `PASS`. | Supported by retained-manifest/schema inspection. | Direct v1/v2 manifest and missing-key evidence. | Bounded and appropriate: rerun Frontier qualification from exact SHA and retain passing v2 manifest. |
| PASS-60A `PRO-001` evidence-only head/source mismatch | Not recorded | Not recorded | Not assessable; treated as a false positive because preserved disposition accepted the evidence-only relationship. | Not assessable. | Static retained-evidence inspection without final PR context. | Broader than needed once qualified source and evidence-only head are distinguished. |
| RERUN-66A-WRONG-ISSUE `PRO-001` issue mismatch | Merge-blocking | High | Correctly diagnosed an invocation authority mismatch, not a candidate defect. | Supported by candidate files identifying issue #41. | Direct issue-body and file-surface evidence. | Bounded and appropriate: rerun with issue #41. |
| RERUN-66A-DEFECTIVE `PRO-001` stale generator hashes | Merge-blocking | High | Matched retained provenance/historical-current split problem. | Supported by retained-vs-candidate SHA-256 comparison. | Direct hash evidence. | Bounded and appropriate: restore exact provenance binding or split historical/current provenance. |
| RERUN-66A-DEFECTIVE `SCI-001` scientific identity | Consequential non-blocking | High | Matched effective scientific-identity defect. | Supported by identity-function and solver-input inspection. | Direct source evidence. | Bounded and appropriate: hash only calculation-effective fields and keep provenance in a separate identity. |

### Formal draft-PR review disposition

Draft PR #75 candidate `cb5d1c0b1b522449a71475030d8479bac1718c83`
was reviewed by fresh read-only internal subagents after the draft PR was
opened. The requirements/scope role used Sol with high effort. The
test-effectiveness/provenance role used Terra with high effort. The original
finding record was also preserved in the PR conversation:
[formal review comment](https://github.com/jaharris87/XNet/pull/75#issuecomment-5258420551).

| Finding | Disposition |
| --- | --- |
| `REQ-001` exact repair candidates were not all evaluated separately. | Accepted. Exact repair SHAs for RVCASE-52A, RVCASE-52B, RVCASE-60A, and RVCASE-60B were rerun and recorded separately from later useful `PASS` counterexamples. |
| `REQ-002` / `TST-001` RVCASE-59A listed a repair-era pytest file that was absent at `a21eeb1`. | Accepted. The defective-candidate context now excludes that file, the repair-only context names it separately, and both #59 sides were rerun. |
| `REQ-003` PR body listed invalid multi-item `gh issue view` and `gh pr view` commands. | Accepted. The PR body is maintained outside this repository file and uses per-item loops for reproduced link/state checks. |
| `REQ-004` / `TST-003` result summaries lacked explicit severity/confidence/evidence/smallest-fix quality. | Accepted. The finding quality table above records those dimensions. |
| `TST-002` #66 review used a too-specific brief and the wrong issue authority. | Accepted. #66 was rerun with issue #41 and neutral source-backed context; the issue #46 rerun is retained only as an invocation limitation. |
| `PRO-001` invocation metadata was vague where the tool did not expose model/effort. | Accepted. Session class, no-context-fork setup, and exposed or not-exposed model/effort fields are now recorded explicitly. |

Replacement candidate `c3399437d5b3c86446026a02586b2512feeaf5b9` was then
reviewed by fresh read-only internal subagents. The requirements/scope role
again used Sol with high effort; the test-effectiveness/provenance role used
Terra with high effort. The findings were preserved in the PR conversation:
[replacement review comment](https://github.com/jaharris87/XNet/pull/75#issuecomment-5258618001).

| Finding | Disposition |
| --- | --- |
| `RR-TST-001` the live PR record was stale and still contained invalid multi-item GitHub CLI verification commands when the reviewer inspected it. | Accepted. The PR body was updated to name `c3399437d5b3c86446026a02586b2512feeaf5b9`, use per-item loops, and record the replacement-candidate verification state. |
| `RR-REQ-004` the finding-quality table still grouped findings and used qualitative labels instead of explicit severity and confidence values. | Accepted. The table above now splits non-`PASS` findings and records reported severity and reported confidence separately, using `not recorded` and `not assessable` where the original output did not expose those values. |

Replacement candidate `d166f5c89371c51e5907fe2a684102987222921f` was then
reviewed by fresh read-only internal subagents. The findings were preserved in
the PR conversation:
[second replacement review comment](https://github.com/jaharris87/XNet/pull/75#issuecomment-5258719715).

| Finding | Disposition |
| --- | --- |
| `RR-REQ-004-R1` / `RR-REQ-005` the table still omitted the initial wrong-issue `EVAL-66A SCI-001` quality row. | Accepted. The quality table now records `EVAL-66A SCI-001` separately with `not recorded`/`not assessable` severity and confidence metadata and notes that the corrected issue #41 rerun supersedes it for scoring. |
| `RR-PRO-002` the PR-body comment validation loop omitted replacement review comment `5258618001`. | Accepted. The live PR body is updated outside this repository file when the final replacement SHA is known, and final handoff verification includes that comment id. |

## Playbook correction decision

No playbook correction is justified by the initial evaluation and correction
reruns.

The missed accepted findings are already covered by the merged playbook:

- RVCASE-54A missed scientific identity and fingerprint coverage even though
  the playbook asks whether scientific identity covers effective physical
  identity and every result-bearing field.
- RVCASE-54A missed overly broad malformed-row handling even though the
  playbook asks whether mutations and negative probes reject for the intended
  reason.
- RVCASE-54B missed mutable preflight evidence even though the playbook asks
  whether inputs, results, nested claims, and inventories are immutable and
  mutually bound at the point they are used.

The misses are attributable to reviewer execution limits, case-context errors,
and case complexity: one reviewer stopped after reproducing a clean-build
failure, another did not complete the full preflight or construct the
post-analysis rewrite counterexample, the first #59 catalog included a
repair-only file for the defective SHA, and the first #66 brief used the
Frontier issue instead of the NSE validation issue. The corrected reruns fixed
the context errors without requiring a playbook wording change.

The repaired-candidate false positives are also not playbook wording failures.
They arose from deliberately withheld historical disposition context about an
accepted final candidate relationship, from exact repair SHAs that were not
yet useful `PASS` counterexamples, or from asking a stricter substitution or
manifest-binding question than the preserved accepted finding.

Because the playbook was not changed, no playbook-correction-triggered rerun
is required. The reruns recorded above addressed formal review findings about
case context and exact repair-SHA coverage.

## Development refresh record

Issue #71 started final procedure work from
`origin/development@5395b1ed117536787d26871c3dc7d03e559aaedd`, the merge of
PR [#73](https://github.com/jaharris87/XNet/pull/73) for issue
[#69](https://github.com/jaharris87/XNet/issues/69). After PR
[#74](https://github.com/jaharris87/XNet/pull/74) for issue
[#70](https://github.com/jaharris87/XNet/issues/70) merged, the branch was
fast-forwarded to
`origin/development@5d71ae2754539db24ba6217c061390bbff6d11fe` before
self-review, staging, commit, push, or PR creation.

PR #74 changed live-status, follow-up, and final-`development` freshness
records in `docs/development/maintainer-workflow.md` and the issue/PR
templates. It did not change `docs/development/review-playbook.md`, so the
historical evaluation remains tied to playbook revision
`5395b1ed117536787d26871c3dc7d03e559aaedd`. This document does not define
live-status or PR handoff fields; the eventual PR and handoff should use the
current workflow/template terminology.

## Update rule

Update this case set only when one of these events occurs:

- the review playbook materially changes a risk class, role, reviewer brief,
  finding schema, false-pass question, disposition rule, or re-review rule;
- a future review or post-merge failure demonstrates a distinct consequential
  failure mode not represented by the retained cases; or
- a retained link, SHA, or path becomes unusable and must be replaced with an
  equivalent preserved record.

For each update, record the triggering event, the cases added, replaced, or
retired, the reason the set remains finite, and whether affected cases were
rerun. Do not add cases merely because time passed, another model is
available, or another ordinary review produced an equivalent finding.
