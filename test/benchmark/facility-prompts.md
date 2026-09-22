# Draft facility local-session prompts

Current status: PR #133 implements only the issue #127 serial-dense capture.
Do not run the nonserial slices below until reviewed execution-profile and input
PRs land. Do not modify source; stop and report harness defects rather than
making site-specific repairs.

## Frontier

```text
Use Frontier account/project <ACCOUNT_PROJECT>. Discover the current scheduler,
modules, compiler, CPU/GPU topology, launcher and filesystem guidance locally;
do not assume a module name. Check out exact source
86e867c2a64267a674ce4fbf6a3064af39e2f4e0 and the reviewed #133 harness/input
registry revision <HARNESS_REVISION>. First request a smoke allocation
<SMOKE_NODES>/<SMOKE_WALLTIME>, run implemented serial-dense batch_alpha and
heat_sn160 capture/validation, and package portable records. Then, only after
the required nonserial PRs land, use finite assigned slices <NODES>/<WALLTIME>
for the #127 network ladder, CPU/GPU same-workload comparisons, and applicable
batch/ranks-per-GPU/component points. For every point retain numerical result,
source/harness identity, modules, job ID, topology, launcher, build config,
stdout/stderr/diagnostics and checksum inventory. Report status or defects.
```

## Perlmutter

```text
Use Perlmutter account/project <ACCOUNT_PROJECT>. Discover the current
scheduler, modules, compiler, CPU/GPU topology, launcher and filesystem
guidance locally. Check out exact source 86e867c2a64267a674ce4fbf6a3064af39e2f4e0
and reviewed #133 harness/input registry revision <HARNESS_REVISION>. First
request smoke allocation <SMOKE_NODES>/<SMOKE_WALLTIME>, run implemented
serial-dense batch_alpha and heat_sn160 capture/validation, and package
portable records. Only after required nonserial PRs land, use finite assigned
slices <NODES>/<WALLTIME> for the #127 network ladder, CPU/GPU same-workload
comparisons, and applicable batch/ranks-per-GPU/component points. Retain
numerical, topology, module, job, launcher, build, artifact and checksum
evidence; report defects without site-specific source changes.
```
