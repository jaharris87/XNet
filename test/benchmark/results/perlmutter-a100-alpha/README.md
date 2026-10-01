# Perlmutter A100 controlled-alpha run

This directory records the bounded Perlmutter GPU work from issue #152. It
contains the first failed run of the unmodified pre-v9 source and the completed
run after the one-line portability correction merged in PR #155.

These are four-zone smoke-test measurements. They demonstrate that the runner
can build, execute, time, and compare XNet on a Perlmutter A100. They are not a
network-size, batch-size, MPI, or multi-GPU performance study.

## Source revisions

The historical pre-v9 source is:

```text
86e867c2a64267a674ce4fbf6a3064af39e2f4e0
```

Job `59029522` used that source without modification. It reached the A100 but
exited with status 139 before a numerical comparison could run.

The successful run used the historical source plus the `t9rhofind_scalar`
explicit-shape correction from PR #155:

```text
adjusted commit  097433d7d627600e2799b070a9fba7240fee32d5
adjusted tree    3328fe4eb4a46d757e4f3faf90998efc95e9b0a5
parent           86e867c2a64267a674ce4fbf6a3064af39e2f4e0
PR #155 commit   25b4e1e8a107d4c873bc606a25a912d78c4f5e83
patch SHA-256    05081a7015819695eddc2e97dc6cf57eff7009aa36754bc56ee3fd38d30a6777
```

The patch changes one declaration in `source/xnet_conditions.F90`, replacing
the assumed-shape trajectory arguments with their existing `ns` extent. The
applied diff is in
`successful-59162619/facility/applied-root-fix.diff`. The source checkout was
clean before and after capture. PR #155 also established that the earlier
`inr` and proposed `its` changes were unnecessary; the successful source uses
the original pre-v9 mappings.

This successful run is a compatibility-adjusted pre-v9 measurement. It is not
an execution of the byte-for-byte unmodified historical source and does not
replace an exact pre-v9 result where one is available.

## Workload and GPU configuration

Both runs used the controlled alpha case:

- `T9 = 1.7`;
- density `1.0e8 g cm^-3`;
- `Ye = 0.5`;
- equal C12/O16 mass fractions;
- self-heating off;
- weak reactions and screening on;
- 10-second bounded early-burn interval;
- four zones with GPU batch size four.

The successful job used NVHPC 26.5, CUDA 13.2, OpenACC, cuBLAS, the dense
solver, one rank, and one A100-SXM4-40GB on node `nid001445`. MPI and host
OpenMP were off. The application command was:

```text
srun --nodes=1 --ntasks=1 --cpus-per-task=32 --gpus-per-task=1 \
  --cpu-bind=cores --gpu-bind=per_task:1 \
  <device-report-wrapper> <xnet>
```

The wrapper reported `CUDA_VISIBLE_DEVICES=0`, `SLURM_STEP_GPUS=0`, and CPU
affinity `48-63,112-127` from the compute node.

## Results

Job `59162619` built XNet successfully and completed three repetitions:

| Repetition | Process status | Numerical status | Wall time | XNet Total | XNet Setup |
| --- | ---: | --- | ---: | ---: | ---: |
| 1 | 0 | PASS | 17.683 s | 0.1586 s | 13.85 s |
| 2 | 0 | PASS | 2.409 s | 0.1420 s | 1.194 s |
| 3 | 0 | PASS | 2.465 s | 0.1431 s | 1.112 s |

All four zones matched the accepted alpha reference exactly at parsed
precision in every repetition. Each zone reported 231 timesteps and Newton
iterations, 231 Jacobian evaluations, and 232 derivative and cross-section
evaluations. Raw XNet component timers and counters are retained in each
`net_diag01` file and summarized in `result.json`.

The first wall time includes substantially larger CUDA/OpenACC setup time. The
three values are retained as observed; this small smoke test does not define a
steady-state performance statistic.

## Unmodified-source failure

Job `59029522` built the exact historical source with the same main build
selectors and reached A100 execution on node `nid001709`. The XNet process
exited 139 after 2.711 seconds, so its numerical status is `NOT-RUN`.

Later diagnostics found that NVHPC-generated descriptors for assumed-shape
trajectory arguments were copied asynchronously after their host stack storage
had expired. The resulting stack corruption surfaced at later OpenACC data
operations. PR #155 corrected the trajectory interface; it did not change a
physics expression, solver tolerance, reference result, or comparison limit.

The failed run is retained under `unmodified-59029522/`. The successful
compatibility-adjusted run is under `successful-59162619/`.

## Retained files

Each run contains the original `result.json`, build log and resolved build
configuration, compiler output, generated control/trajectory/abundance files,
and raw repetition stdout, stderr, process status, and XNet diagnostics.
`facility/` contains the relevant module, Slurm, device, source, runner, job
script, and launcher-wrapper records available for that run.

The runner's complete `input-snapshot/` directory is intentionally omitted
from this compact repository copy because it duplicates about 59 MB of
already-tracked XNet inputs. `result.json` retains the authoritative input
revision and SHA-256 digest for every required input. The generated inputs are
included here. `SHA256SUMS` covers the other 67 retained files in this
directory.

The successful capture used benchmark runner commit
`24c7d8a924035c3bd181c220dc68b35bfe5cdb4d`. `run.py` was unchanged. The
capture copy of `cases.json`, retained as `facility/capture-cases.json`, changed
only the expected source revision so the runner could record the explicitly
approved compatibility-adjusted source.

Absolute `/pscratch` paths in the raw files record where the jobs ran; they are
not instructions or portable paths.
