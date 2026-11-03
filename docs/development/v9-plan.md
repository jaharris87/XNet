# XNet v9: goals and remaining work

XNet v9 should make the reaction network easier to use both as a standalone
program and from CHIMERA and Flash-X. The application-facing work should let
callers initialize the network once, submit repeated burns, obtain results,
and release XNet resources without reproducing the standalone driver or
manipulating solver workspace.

Preserve numerical behavior and CPU/GPU execution while doing this work.
Measure performance before and after the interface changes. No particular
speedup is required for the release.

[Issue #126](https://github.com/jaharris87/XNet/issues/126) coordinates the
release. This page explains the sequence; the component issues record their
implementation requirements, results, and maintainer decisions.

## Where we are

The starting CPU/GPU measurements use source and inputs from
`3825c705b26f11ea67f43d6098452a3d53379dfb`. Later development does not change
that comparison source. See [#126](https://github.com/jaharris87/XNet/issues/126)
for current implementation status.

| Work | Current result | Next step |
| --- | --- | --- |
| [#128: configuration](https://github.com/jaharris87/XNet/issues/128) | Merged: validated `xnet_controls_t`, programmatic configuration, layered standalone namelists, and migrated maintained inputs | Use the existing representation in the application interface |
| [#127: starting CPU measurements](https://github.com/jaharris87/XNet/issues/127) | Complete and accepted: serial dense CPU measurements for four network sizes on both facilities, with MA48 deferred | Preserve this starting point for resulting-code comparisons |
| [#129: application interface and library](https://github.com/jaharris87/XNet/issues/129) | Merged: CPU API/archive (#158), fatal-shutdown reporting (#159), thin EOS adapters (#160), scalar NSE (#161), and timestep output (#162). GPU PR #164 is ready for maintainer review, unmerged | Complete application GPU and remaining execution-mode checks; leave merges to the maintainer |
| [#130: application integrations](https://github.com/jaharris87/XNet/issues/130) | Both initial CPU prototypes are tested and reviewed, including the Flash-X partial-batch repair. Both CHIMERA GPU application attempts stopped in the CPU step | Review the private CHIMERA wrapper cleanup, diagnose the two separate facility failures, then validate required modes and ownership |
| [#131: CPU/GPU and application performance](https://github.com/jaharris87/XNet/issues/131) | Stage A complete: four network sizes on both facilities; stage B remains open | Measure resulting-code and repeated application burns after the relevant #129/#130 work |
| [#132: release checks](https://github.com/jaharris87/XNet/issues/132) | Not yet a release candidate | Verify the final implementation, supported platforms, and documentation |

The CPU results are in the
[#127 measurement summary](https://github.com/jaharris87/XNet/issues/127#issuecomment-6371001835).
They are combined with the completed network-size GPU measurements in
[#131's stage A summary](https://github.com/jaharris87/XNet/issues/131#issuecomment-6420424524),
which passed [independent review](https://github.com/jaharris87/XNet/issues/131#issuecomment-6420561047).
The earlier #149/#152 smoke tests remain separate execution checks, not the
source of those GPU timings. No additional stage A collection is planned.

## 1. Completed standalone CPU/GPU starting measurements

The maintainer accepted #127's reduced CPU collection and MA48 deferral and
authorized closure on 2026-10-23. The matched GPU collection is also complete
as stage A of #131; the resulting-code and application measurements are
stage B and remain open. Keep both starting collections rather than
repeating them as additional smoke tests.

All selected CPU/GPU runs use source and inputs from development commit
`3825c705b26f11ea67f43d6098452a3d53379dfb` on both facilities, the
[maintainer-selected comparison source](https://github.com/jaharris87/XNet/issues/127#issuecomment-5938328100).
The older `86e867c2a64267a674ce4fbf6a3064af39e2f4e0` source is not the
source of these measurements. Its Perlmutter GPU failure and the separately
labeled adjusted-source success remain documented in #152/#155.

The completed cases are alpha, CCSN52, SN160 and ECSN350: 1024 zones,
T9=1.7, density 1.0e8 g cm^-3, equal C12/O16 mass fractions, Ye=0.5, weak
reactions and screening enabled, self-heating off, and a 10-second interval.
This is an early-burn test, not equilibrium or a coupled timestep.

CPU cases use batch size 1. GPU cases use one rank and one device, batch
size 16, with Frontier HIP/ROCm/OpenMP offload or Perlmutter CUDA/OpenACC.
Each has five measured processes after warm-up. Perlmutter ECSN350's five
measurements span two allocations, each with its own recorded warm-up.
The result does not establish an optimal batch size or isolate compiler,
directive or hardware effects.

The linked results include raw wall repetitions, Setup/Total/TimeStep and
available component timers, counters, numerical comparisons, compilers,
build settings, commands, CPU affinity and device visibility. All selected
processes and all 1024 zones passed the existing numerical comparisons.
Each process initializes XNet afresh; its burn timers do not measure an
already-initialized application call. Timers are nested, not additive.

MA48 was not configured for this CPU collection. A licensed-source location
was not established on either facility; this does not establish facility-wide
absence. Sparse measurement remains deferred by the maintainer. Never
redistribute HSL source.

The [compact CPU/GPU tables and raw repetitions](https://github.com/jaharris87/XNet/issues/131#issuecomment-6420424524)
and [review](https://github.com/jaharris87/XNet/issues/131#issuecomment-6420561047)
are the stage A record. Large operational files stay external. Further GPU
batch-size, ranks/GPU, OpenMP and self-heating sweeps are chosen for concrete
stage B questions, not required to finish these starting measurements.

## 2. Implement the application interface from real calls

#129 owns the XNet procedures, types, and conventional Make library target.
#130 owns the application adapters and representative integration checks.
Inspect both consumers before fixing the shared interface. The maintainer
selected CHIMERA to drive the first implementation, followed by Flash-X.

Start with the existing validated configuration and trace what the caller
needs at initialization, for each burn, and at finalization. Keep species
mapping, application layouts, and energy policy in the application adapter.
Use ordinary Fortran procedures and the existing compile-time provider
practices. Keep one XNet instance and document concurrency restrictions.

The dense serial CPU implementation follows the maintainer-approved
[initialize/burn/finalize direction](https://github.com/jaharris87/XNet/issues/129#issuecomment-6372794913):
constant-condition batches, temperature in K, XNet-order mass fractions,
active lanes, auxiliary composition, and the existing penultimate-timestep
meaning. Use CHIMERA table EOS for the first application integration; tests
with the standalone EOS do not establish that integration. The maintainer
[clarified the failure policy](https://github.com/jaharris87/XNet/issues/129#issuecomment-6374869197):
exhaustion after XNet's internal adaptive retries is fatal. The embedded API
must report it so the host can perform its own shutdown; standalone XNet keeps
its existing termination behavior. Application retry, rollback and
successful-lane continuation are not required. Fallback to surrogate or
alternative integration methods is possible later work, not part of this
implementation. Keep the first slice's existing fatal paths documented.
MPI/OpenMP and caller-owned GPU validation remain required before claiming
those modes.

Review detailed signatures and MPI/EOS/GPU ownership in the implementation.
Bring consequential changes to these decisions back to the maintainer;
private helper routines do not each need approval.

The merged CPU implementation builds a driver-free library, exercises
repeated burns through its public procedures, preserves reusable setup, and
compares results with the direct numerical path. Its build and calls are
documented in [Fortran embedding](embedding.md). The optional timestep result
used by Flash-X is merged in #162. Both selected CPU application cases have
run through the API and passed independent review, within the limits below.
Continue standalone tests and focused independently reviewed PRs; an external
test caller does not replace required application checks.

[PR #164](https://github.com/jaharris87/XNet/pull/164) is ready for maintainer
review at `721139d12eda4869a9080012c3aa6d67617aea60`, targeting development
`5468d2aef0572b5bacbc483bd851646c1b9233b2`; it is not merged. Its approved GPU
direction uses one shared initializer/finalizer, named vendor resources with
independent ownership and partial borrowing, and one burn procedure with
optional `data_on_device`. Current library limits are dense, one instance,
one host thread and library MPI off. CUDA/cuBLAS and HIP/ROCm API tests passed
on both facilities at `bf25833e95e0a0351c0f3d840a81c830e8a02060`. The later
cleanup-state repair has separate host tests, review and native rebuilds;
those earlier GPU runs are not relabeled as runs of the later source.
Successful API tests and full CHIMERA GPU links do not establish GPU
application execution. See the [PR's final results and limits](https://github.com/jaharris87/XNet/pull/164#issuecomment-6513396134).

## 3. Validate both consumers and measure repeated use

Under #130, the first representative CPU sequences are complete: CHIMERA's
finite one-rank table-EOS case reached cycle 6, including the delivered-copy
repeat; Flash-X's Cellular/alpha case completed 114 steps on four host MPI
ranks, including repaired batch-10 and batch-16 checks. Independent source and
results reviews passed. These are limited integration comparisons, with
cross-version differences reported descriptively; they do not establish broad
scientific equivalence, performance, or all execution modes. See the
[CHIMERA repeat](https://github.com/jaharris87/XNet/issues/130#issuecomment-6508231286)
and [Flash-X repair/results](https://github.com/jaharris87/XNet/issues/130#issuecomment-6508937667).

Complete the remaining checks against each intended support claim. Check
species ordering, units, normalization, masks and partial batches,
prior timesteps, counters, self-heating, neutrino losses, and the application's
energy responsibilities where applicable. Check repeated initialization/use/
finalization and ownership. Test each GPU integration mode actually claimed;
standalone GPU success does not establish caller-owned GPU support. Multiple
host MPI ranks using a serial library do not establish MPI-enabled embedding.
Restart, other selected application configurations, nonzero network neutrino
loss, threading and application GPU behavior remain unvalidated where listed
in #130; decide support and any named exceptions with the maintainer.

The private CHIMERA wrapper cleanup remains under maintainer source review.
Two finite CPU/GPU application pairs stopped before the GPU step: Frontier
job 5796356 crashed in FFN interpolation during its first CPU burn; its cause
remains unresolved. Perlmutter job 60526850 failed during MPI initialization
with GPU-aware MPI enabled but no CUDA GTL in the CPU binary. A CPU-step-only
launch correction is proposed and untested. Keep these failures separate;
neither full GPU application ran. Both allocations are released and any
retry requires fresh approval of a concrete resource request. See the
[application failure record](https://github.com/jaharris87/XNet/issues/130#issuecomment-6514006239).

If access to an application or its workload is unavailable, report the
specific limitation and ask the maintainer how it affects release scope.
Do not invent a representative workload or waive a required consumer.

Stage B of #131 owns performance of the resulting implementation: reuse #127
and stage A inputs for before/after standalone comparisons, and measure
repeated calls from reviewed consumer samples. Separate one-time setup,
per-call work, and batch evolution. Choose additional OpenMP, GPU batch,
ranks/GPU, MA48, and self-heating points
to answer concrete questions. The full documented matrix is not a Cartesian
product or an automatic requirement to run every configuration.

Use measurements to decide whether an optimization is worthwhile. A proposed
optimization, extra timing package, or provider layer needs a demonstrated
need. Keep unrelated investigations, including #138's late-time C/O question
and #139's optional HDF5 input support, separate unless the maintainer makes
one necessary for a real consumer.

## 4. Verify and document the release

#132 checks the assembled release candidate: component and numerical
regressions, applicable MPI/OpenMP behavior, configuration migration,
library/interface behavior, both integrations, and supported Frontier and
Perlmutter accelerator configurations. State unsupported combinations and
accepted limitations. Older successful runs do not automatically cover code
changed afterward. Bind the release checks to the assembled candidate,
executables, inputs and environments on both facilities, or obtain a named
maintainer-approved exception. Performance measurements do not replace these
correctness checks.

The product documentation should explain how to build and run standalone
XNet, migrate inputs, link the library, call the public procedures, interpret
status/results, and respect ownership and platform limits. Keep measured
results and reproduction commands available alongside those claims.

The maintainer approves scientific/numerical policy, public interface and
support decisions, PR merges, and the final release. Use fresh-context review
as described in [the review playbook](review-playbook.md). Keep the release
plan in #126 and update it when a milestone completes or a decision changes;
avoid creating another hierarchy of planning issues.
