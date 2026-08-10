# Manual Frontier GPU correctness qualification

This is the manually initiated Tier 4 qualification for issue #46. It checks
one exact, clean XNet commit on one Frontier MI250X GPU. It is not CI, a
performance benchmark, a scaling claim, or a permanent GPU endpoint baseline.

A human completes Frontier's interactive RSA authentication and starts the
submission. No credential, token, account name, reservation name, or private
path belongs in the repository. The submitter supplies allocation values on
the command line, and the runner records only that an account or reservation
was supplied. The raw artifact directory remains outside the checkout.

The package exercises three independent requirements:

- `gpu_linalg_probe.F90` maps two small nonsingular systems to the device and
  calls the public production `LinearSolveBatched` path. It requires a real
  OpenMP target device, successful HIP/rocBLAS handles and factor/solve status,
  and a relative residual no larger than `1e-12` for both systems.
- the ten-zone, `nzbatchmx=4` fixture from issue #45 runs once with the CPU
  executable and once with the GPU executable. The existing semantic runner
  requires zones 1-10 exactly once, correct filename/content association, and
  no output for inactive lanes 11-12.
- `heat_sn160` runs with both executables to reach the larger network,
  self-heating, screening, default Starkiller Helmholtz EOS, dense Jacobian,
  integrator, runtime preprocessing, and accelerator data paths.

Both XNet comparisons normalize diagnostic endpoints by global zone and use
the CPU result from the same source archive as the reference. The tracked
`comparison_policy.json` supplies bounded scalar, selected material-species,
complete-vector, normalization, and partial-fixture ASCII limits. It never
creates or updates a canonical GPU result. Its `status` must be updated with
the retained measured Frontier evidence and review disposition before issue
#46 is complete.

## Package contents

- `submit_frontier.py` verifies a clean commit, creates and hashes a `git
  archive`, stages it outside the checkout, submits one bounded Slurm job, and
  waits for the returned report.
- `frontier_job.sh` starts one GPU-bound Slurm step.
- `frontier_qualification.py` captures the environment, builds CPU and GPU
  configurations from the archive, runs the three checks, compares results,
  inventories every regular artifact, and writes
  `qualification_manifest.json`.
- `manifest.schema.json` defines the versioned evidence envelope. The runner's
  stricter standard-library validator requires the successful build, device,
  zone, comparison, hash, and inventory fields.
- `comparison_policy.json` is the reviewed numerical policy, not a reference
  result.

Generated artifacts are deliberately outside the repository. A completed
qualification retains a compact, path-neutral manifest under `evidence/`;
executables, object/module files, runtime histories, raw environment paths,
and account data remain in the external artifact directory.

## Human login and submission

Use the current Frontier defaults unless the qualification is intentionally
testing another recorded module set. OLCF's Frontier guide requires the
`craype-accel-amd-gfx90a` module for Cray OpenMP offload and documents hipfort
as an OLCF module. The checked configuration uses the Cray compiler wrappers,
ROCm, OpenMP target offload, and HIP/rocBLAS bindings.

After authenticating interactively on Frontier:

```bash
module purge
module load PrgEnv-cray
module load rocm
module load craype-accel-amd-gfx90a
module load hipfort

python3 test/qualification/frontier/submit_frontier.py \
  --account=<allocation> \
  --partition=batch \
  --artifact-root=<fresh-external-directory> \
  --expected-sha="$(git rev-parse HEAD)"
```

Use `--qos` or `--reservation` only when the facility requires it. The default
request is one node, one task, seven CPUs, one GPU, and 20 minutes. The script
uses `sbatch --wait`; queue wait is not part of the runtime limit. The artifact
root must be absent or empty and outside the repository.

The source worktree must be clean because `git archive HEAD` is the executable
source of record. The archive SHA-256 binds every build and test to that
commit. CPU and GPU builds are clean and sequential because `source/` uses
shared object and module names.

The explicit build selections are:

| Selection | CPU | GPU |
| --- | --- | --- |
| Compiler/mode | `PE_ENV=CRAY`, `CMODE=OPT` | same |
| Parallel modes | MPI/OpenMP off | MPI/host OpenMP off |
| Accelerator | off | `GPU_MODE=ON`, `GPU_BACKEND=HIP` |
| Directives | off | `OPENMP_OL_MODE=ON`, OpenACC off |
| GPU linear algebra | none | `GPU_LAPACK_VER=ROCM` |
| EOS/solver | Starkiller, dense, LibSci | same |

The loaded accelerator target module makes `ftn -fopenmp` target the MI250X
`gfx90a` device. GPU runs set `OMP_TARGET_OFFLOAD=MANDATORY`, so host fallback
is a failure rather than a misleading pass.

Cray's native Fortran preprocessor requires a fixed argument count for
function-like macros, while XNet's shared accelerator-directive layer uses
variadic macros. For Cray GPU builds, `source/crayftn_cpp.sh` therefore runs
the system `cpp -P -C -nostdinc` first and passes the resulting Fortran
source to `ftn`. Comment preservation retains Fortran `//` concatenation;
disabling standard include directories avoids injecting C system-header text.
The qualification records both compiler and preprocessor versions.

## Evidence and result review

On return, inspect and validate the manifest:

```bash
python3 test/qualification/frontier/frontier_qualification.py validate \
  <artifact-root>/qualification_manifest.json
```

The manifest records:

- full source SHA, clean-worktree assertion, and source-archive hash;
- exact loaded modules, compiler evidence, ROCm and hipfort versions, GPU model,
  and hashes of the raw environment reports;
- Slurm job ID and account-neutral resource parameters;
- every build variable, build status/runtime, executable size/hash, and dynamic
  link evidence;
- hashes of every control, trajectory, abundance, network, and EOS input;
- direct status, timeout behavior, observed residual, zone list, numerical
  differences, policy fractions, and runtime output inventories; and
- a complete relative-path, size, and SHA-256 inventory of qualification
  artifacts except the self-referential manifest and the separately hashed
  source archive/build tree.

Review the observed scalar differences, selected-species fraction of allowed,
and complete-vector `L1`/`L-infinity` values before accepting the policy. A
policy change requires a numerical explanation, a controlled perturbation
that the new bound still rejects, and a final rerun from the exact candidate
commit. Do not derive limits automatically from the current output.

To retain a successful run, copy only the validated, path-neutral manifest and
concise review note into a dated directory below `evidence/`. Do not copy raw
histories, binaries, build products, absolute link paths, source archives, or
allocation identifiers other than the required Slurm job ID.

## Focused local checks

These checks need no Frontier access:

```bash
python3 -m pytest -q \
  test/qualification/test_frontier_qualification.py \
  test/qualification/test_parallel_zones.py
```

They prove rejection of missing/duplicate/off-by-one zones, filename/result
misassociation, endpoint state leakage, material CPU/GPU perturbation, host
fallback, absent device evidence, handle/factor status failure, a large solve
residual, incomplete manifests, and queue/allocation/facility
misclassification.

## Failure categories and troubleshooting

Every job-side failure manifest names a category and phase:

- `source`: dirty checkout, wrong SHA, missing input, invalid policy, or archive
  mismatch;
- `environment`: missing/wrong module, compiler wrapper, ROCm, or hipfort;
- `submission`: malformed `sbatch` request or unavailable command;
- `queue`: cancellation, deadline, time-limit, or node failure before useful
  test evidence;
- `allocation`: invalid account/partition/QOS, failed `srun`, no MI250X, no HIP
  device, or OpenMP host fallback;
- `facility`: scheduler/controller communication failure;
- `build`: clean, compile, link, resolved-variable, or `ldd` failure;
- `test`: nonzero/timeout, device/handle/factor failure, residual failure,
  missing/wrong output association, or incomplete diagnostic; and
- `comparison`: a CPU/GPU endpoint exceeds the reviewed bounded policy.

Inspect `sbatch.stderr.txt` and `slurm.stderr.txt` first for submission,
queue, allocation, and facility failures. For builds, inspect the relevant
`build/*/build.stderr.txt` and resolved-variable evidence. For runtime checks,
use the per-run command, stdout, stderr, status, and complete output inventory.
Do not widen a comparison limit to hide a device, initialization, convergence,
or output-association defect.

## Required reruns

Repeat this manual qualification after changes to accelerator memory mapping or
lifetimes, `xnet_macros.fh` directive expansion, OpenMP target/compiler/module
selection, HIP/ROCm bindings or handles, batched GPU linear algebra, zone
batching or active masks, the BE/BDF integrators, GPU EOS/self-heating paths,
or the CPU/GPU endpoint policy. Also rerun before a release claims the
HIP/ROCm Frontier path is qualified. A new Frontier compiler, ROCm, hipfort,
GPU runtime, or materially changed facility module stack is qualification
drift and requires a new recorded run; it does not silently inherit an older
result.

OLCF platform guidance: [Frontier User Guide](https://docs.olcf.ornl.gov/systems/frontier_user_guide.html).
