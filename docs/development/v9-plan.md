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
| [#129: application interface and library](https://github.com/jaharris87/XNet/issues/129) | Merged: public lifecycle/archive, EOS/NSE/timestep/timing results, concurrent application-side CPU batch calls and GPU resource ownership (#164), followed by API/GPU readability work (#180) and shared initialization/cleanup (#191) | Implement the selected #185 worker storage and complete remaining execution-mode checks |
| [#130: application integrations](https://github.com/jaharris87/XNet/issues/130) | Selected CHIMERA 17/160/350 and Flash-X 17/160 CPU comparisons are complete at their recorded sources. Flash-X 350 execution and application GPU checks remain | Reconcile wrappers with the current interface, check resulting code, and validate required modes and ownership; diagnose the two facility failures separately |
| [#171](https://github.com/jaharris87/XNet/issues/171) / [#181: numerical corrections](https://github.com/jaharris87/XNet/issues/181) | Screening correction #175 is merged. Accepted-composition Ye correction #182 is reconciled with the lifecycle merge and remains draft | Complete candidate-specific native checks for #182 |
| [#131: CPU/GPU and application performance](https://github.com/jaharris87/XNet/issues/131) | Stage A complete: four network sizes on both facilities. Six application workloads selected for stage B; no stage B timings yet | Settle implementation and correctness checks before selecting the timing source and measuring repeated application burns |
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
documented in [Fortran library API](embedding.md). The optional timestep result
used by Flash-X is merged in #162. CPU cases from both applications have run
through the API and passed independent review, within the limits below.
Continue standalone tests and focused independently reviewed PRs; an external
test caller does not replace required application checks.

[PR #164](https://github.com/jaharris87/XNet/pull/164) is merged. It adds GPU
resources and preserves the application-side CPU batch loop used by CHIMERA
and Flash-X. CPU `OPENMP_MODE=ON` lets each worker in a fixed, nonnested team
call XNet for its own batch bank; initialization and finalization remain
outside the team. External EOS routines must support concurrent evaluation.
GPU library builds use `OPENMP_MODE=OFF` and serialize
XNet calls; the application may use OpenMP elsewhere. The library uses dense
solves, one instance and library MPI off.

The GPU implementation uses one shared initializer/finalizer, vendor resources
with independent ownership and partial borrowing, and optional
`data_on_device` on the burn procedure. Merged
[#180](https://github.com/jaharris87/XNet/pull/180) makes the API/GPU lifecycle
easier to read, and merged [#188](https://github.com/jaharris87/XNet/pull/188)
does the same for the driver, controls and I/O. Selected native CPU/GPU library
checks pass at their recorded sources, including
[CCE CPU execution at `5f87e4f3`](https://github.com/jaharris87/XNet/pull/164#issuecomment-6662814762)
and [#180's HIP/OpenMP-target and CUDA/OpenACC checks at `4a455a2e`](https://github.com/jaharris87/XNet/pull/180#issuecomment-6748899829).
Compiler warnings remain open. Successful library tests and application links
do not establish application GPU execution, performance or release readiness.

The [screening correction #175](https://github.com/jaharris87/XNet/pull/175)
is merged. [Draft #182](https://github.com/jaharris87/XNet/pull/182) corrects
Ye to describe accepted BE/BDF composition. Its `23fa7675` candidate merges the
`64b1a2c6` lifecycle source and passes
[231 local regressions, library/batch/overlap checks and ten DEBUG processes](https://github.com/jaharris87/XNet/pull/182#issuecomment-6801789870),
with [fresh source/math and test/reference reviews passing](https://github.com/jaharris87/XNet/pull/182#issuecomment-6802006110).
The maintainer [accepted its November 6 native comparisons](https://github.com/jaharris87/XNet/pull/182#issuecomment-6779556459)
at the older `d8dc7efe` source; those results do not establish refreshed-source
native behavior. Current-candidate native compile and execution checks remain.
The [#190](https://github.com/jaharris87/XNet/pull/190) compile workaround for the
[NVIDIA CPU threaded-caller issue #183](https://github.com/jaharris87/XNet/issues/183)
and [#195](https://github.com/jaharris87/XNet/pull/195) caller-output flush are
merged. The latter's [native suite](https://github.com/jaharris87/XNet/pull/195#issuecomment-6786074563)
completed all 28 commands with diagnostic `OMP_STACKSIZE=16M`. This does not
adopt a supported minimum or default. The original timeout/LibSci fault,
IEEE warnings and large affinity report remain under
[#192](https://github.com/jaharris87/XNet/issues/192); GPU-library success does
not cover the CPU caller or explain those failures.

The remaining implementation has separate scopes. [#184](https://github.com/jaharris87/XNet/issues/184)
is implemented by merged [#191](https://github.com/jaharris87/XNet/pull/191):
common standalone/API initialization and cleanup stay in their existing
modules, including provider-specific Jacobian finalization. Its checks retain
the source and configuration limits stated in the PR. Real concurrent oneMKL
PARDISO exposed a separate failure under
[#193](https://github.com/jaharris87/XNet/issues/193). A
[hardware watchpoint](https://github.com/jaharris87/XNet/issues/193#issuecomment-6799611340)
identifies oneMKL writing a shared CSR row pointer in one observed call;
[PR #196](https://github.com/jaharris87/XNet/pull/196) gives each worker private
solver indices. Its [native checks and independent result reviews](https://github.com/jaharris87/XNet/pull/196#issuecomment-6801417552)
pass for GNU11.4/oneMKL2026.1 GNU LP64 with the sequential oneMKL layer,
including one/two/four-worker component checks and standalone BE/BDF histories.
These results do not expand support to other configurations.
The application library remains dense-only.
Standalone trajectories keep their interpolation
and integrator history rather than becoming repeated constant-condition burns.
Important v9 worker/zone-storage work in [#185](https://github.com/jaharris87/XNet/issues/185)
follows the lifecycle work. The maintainer
[selected per-worker plain allocations with conditional OpenMP THREADPRIVATE ownership](https://github.com/jaharris87/XNet/issues/185#issuecomment-6781708708);
the storage rewrite has not started.
[#186](https://github.com/jaharris87/XNet/issues/186) requests arbitrary
species-order preparation and fill-in assessment. The maintainer
[deferred it until after v9.0](https://github.com/jaharris87/XNet/issues/186#issuecomment-6800308199);
it is not a v9.0 release requirement. It has no implementation candidate or
default-order change. Use #126 and the component
records for changing status and source-specific checks.

## 3. Validate both consumers and measure repeated use

Under #130, the selected CHIMERA 17/160/350-species table-EOS CPU sequences
complete through cycle 6 with one/two/four workers. The
[approved CHIMERA summary](https://github.com/jaharris87/XNet/issues/130#issuecomment-6663354031)
records the private 350-species capacity repair, independent source/output
reviews and the maintainer's acceptance of the named thread-count
differences. These nine comparisons keep their recorded source bindings and
introduce no general tolerance or scientific reference.

The selected Flash-X Cellular 17- and 160-species CPU sequences also complete
at frozen public `5f87e4f3`, before #175. The
[approved 160-species summary](https://github.com/jaharris87/XNet/issues/130#issuecomment-6690412335)
covers four MPI ranks and one/two/four workers per rank, with complete
checkpoint and history comparisons. Flash-X 350 application execution remains
unattempted. Earlier alpha-network, restart and CPU-worker results remain
separately identified in #130. Reconcile the wrappers with the current public
interface and check the resulting code before timing; historical comparisons
do not establish current merged-code behavior or application GPU execution.

Complete the remaining checks against each intended support claim. Check
species ordering, units, normalization, masks and partial batches,
prior timesteps, counters, self-heating, neutrino losses, and the application's
energy responsibilities where applicable. Check repeated initialization/use/
finalization and ownership. Test each GPU integration mode actually claimed;
standalone GPU success does not establish caller-owned GPU support. Multiple
host MPI ranks using a serial library do not establish MPI-enabled embedding.
Use #130's recorded results to distinguish checked restart, MPI, CPU worker
and GPU configurations from the modes still requiring validation. Decide
support and any named exceptions with the maintainer.

Both private CHIMERA facility failures remain unresolved and separate:
Frontier's CPU FFN interpolation failure and Perlmutter's CPU MPI/GTL startup
failure. Neither reached application GPU execution. The public FFN repair
does not establish the private failure's cause; Perlmutter's CPU launch
correction remains untested. See the
[application failure record](https://github.com/jaharris87/XNet/issues/130#issuecomment-6514006239)
and #130's current status. Public standalone/library success does not diagnose
either failure. New facility runs require approval of a concrete resource
request; earlier allocation approvals are consumed.

If access to an application or its workload is unavailable, report the
specific limitation and ask the maintainer how it affects release scope.
Do not invent a representative workload or waive a required consumer.

Stage B of #131 owns performance of the resulting implementation: reuse #127
and stage A inputs for before/after standalone comparisons, and measure
repeated calls from reviewed consumer samples. The maintainer selected six
workloads: CHIMERA and Flash-X Cellular, each with 17/160/350 species, starting
with one/two/four CPU workers. CHIMERA keeps its supplied inputs; Flash-X 350
uses public XNet ECSN350. No stage B timings have been collected. Complete the
relevant lifecycle/storage work and resulting-code correctness checks before
selecting the timing source. Deferred #186 does not change the selected
workloads or their species ordering. Keep the completed starting
measurements and use the existing runner rather than restarting the abandoned
benchmark framework.

Separate one-time setup, per-call work, and batch evolution. Choose additional
OpenMP, GPU batch, ranks/GPU, MA48, and self-heating points to answer concrete
questions. The full documented matrix is not a Cartesian
product or an automatic requirement to run every configuration.

The merged `timing%evolve` field measures the interval inside `full_net`.
Time around `xnet_burn_batch` in the application for full-call cost, and record
one-time setup separately. Summed component durations from concurrent workers
are not workload elapsed time. The maintainer selects the stage B measurement
scope in #131; correctness-run durations are not substitutes for those
measurements.

The maintainer [approved five no-change dispositions for v9.0](https://github.com/jaharris87/XNet/issues/131#issuecomment-6692997969):
retain synchronous OpenMP offload, pivoted ROCm solves and dense GPU solving;
defer GPU sparse implementation and fTimer adoption, with follow-up patches
after v9.0. #65 remains open. Deferred work is not a prerequisite for the first
stage B timing series, and the decision supplies no performance result or
release acceptance.

Use measurements to decide whether a later optimization is worthwhile. A
proposed optimization, extra timing package, or provider layer needs a
demonstrated need. Keep unrelated investigations, including #138's late-time C/O question
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

Temporary facility unavailability does not waive the corresponding checks.
There is no final release candidate. Resolve or obtain maintainer dispositions
for the remaining implementation, compiler, application and performance work
before assembling #132's release checks; past comparisons retain their source
limits.

The product documentation should explain how to build and run standalone
XNet, migrate inputs, link the library, call the public procedures, interpret
status/results, and respect ownership and platform limits. Keep measured
results and reproduction commands available alongside those claims.

The maintainer approves scientific/numerical policy, public interface and
support decisions, PR merges, and the final release. Use fresh-context review
as described in [the review playbook](review-playbook.md). Keep the release
plan in #126 and update it when a milestone completes or a decision changes;
avoid creating another hierarchy of planning issues.
