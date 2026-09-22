# Draft facility local-session prompts

Current status: #133 implements only serial-dense capture for the two ready
representative cases. Run the smoke below now. All nonserial profiles and the
controlled common-state input family are blocked on reviewed input and
execution-profile PRs; do not improvise a site-specific repair.

## Frontier

```text
Use Frontier <FRONTIER_ACCOUNT_PROJECT>, queue <FRONTIER_QUEUE>, and source SHA
86e867c2a64267a674ce4fbf6a3064af39e2f4e0 with reviewed harness revision
<HARNESS_REVISION> and benchmark input revision <BENCHMARK_INPUT_REVISION>.
Discover current scheduler syntax, modules, compiler, runtime, launcher,
CPU/GPU topology, binding, and writable filesystem locally. First request 1
node/10 minutes and run only the current serial-dense smoke for batch_alpha and
heat_sn160. Validate and package each portable record.

After the required reviewed PRs land, build only the configurations needed for
these assigned <NODES>/<WALLTIME> slices. Run one setup/smoke point before each
slice, then retain five raw repetitions unless the evidence justifies a change:

- controlled network ladder alpha/52/160/179/350 on one-rank, one-thread dense
  CPU and one-rank GPU at batch 16;
- dense CPU thread scaling for 52/179/350 at 1,2,4,8,P threads, fixed 256 zones
  and batch 64, where P is one recorded physical-core-count point;
- dense versus MA48 for 160/179/350, one rank/thread and batch 16, only where
  maintainer-held licensed HSL is available;
- CPU versus GPU for 52/179/350 with the same 256-zone workload: P CPU threads
  versus one rank/GPU, batch 16;
- GPU batch 1,4,16,64 at fixed 256 zones for 52/179/350, plus batch 64 with 257
  zones for a deliberate partial final batch;
- one versus two ranks sharing one GPU for 179/350, fixed 256 zones/GPU and
  batch 64;
- representative 179/350 self-heating off/on on one CPU and one GPU profile;
- full component breakdown for the reused 179/350 CPU/GPU points;
- the ready representative cases and one bounded SN160 CPU-dense BDF spot.

Do not interpret representative-case differences as network-size scaling. For
every point retain
numerical comparison status, source/harness/input identities, command,
allocation/job ID, modules/compiler/runtime, topology/binding, build config,
launcher, stdout/stderr/diagnostics, all emitted XNet timers/counters, and
checksum inventory. Host timers are not asynchronous GPU kernel timings. Stop
and report a harness defect; do not change source. Package records and a concise
execution summary for return to the coordinator.
```

## Perlmutter

```text
Use Perlmutter <PERLMUTTER_ACCOUNT_PROJECT>, queue <PERLMUTTER_QUEUE>, and
source SHA 86e867c2a64267a674ce4fbf6a3064af39e2f4e0 with reviewed harness
revision <HARNESS_REVISION> and benchmark input revision
<BENCHMARK_INPUT_REVISION>. Discover scheduler, modules, compiler, runtime,
launcher, CPU/GPU topology, binding, and writable storage locally. First use
1 node/10 minutes for the current serial-dense batch_alpha and heat_sn160 smoke,
then validate and package portable records.

Only after reviewed input/execution-profile PRs land, build only the required
configurations. Run a setup/smoke point before each assigned <NODES>/<WALLTIME>
slice, then retain five raw repetitions unless evidence justifies a change:

- controlled alpha/52/160/179/350 ladder on one-rank, one-thread dense CPU and
  one-rank GPU at batch 16;
- 52/179/350 dense CPU threads 1,2,4,8,P at fixed 256 zones/batch64, with P the
  recorded physical-core-count point;
- licensed-HSL dense/MA48 160/179/350 at one rank/thread and batch 16;
- same-workload CPU/GPU 52/179/350 at 256 zones/batch16;
- GPU batch 1,4,16,64 at 256 zones for 52/179/350, plus batch64/257 zones for a
  deliberate partial final batch;
- one/two ranks per GPU for 179/350 at fixed 256 zones/GPU and batch64;
- representative 179/350 self-heating off/on on one CPU and one GPU profile;
- full component breakdown for reused 179/350 CPU/GPU points;
- ready representative cases and one bounded SN160 CPU-dense BDF spot.

Do not infer network-size scaling from representative cases. Retain numerical
comparison, source/harness/input identities, commands, job/allocation facts,
modules/compiler/runtime, topology/binding, build/launcher, streams,
diagnostics, all emitted timers/counters, and checksum inventory. Host timers
are not asynchronous GPU kernel timings. Stop and report defects; never diverge
the source. Package records and a concise execution summary for return.
```
