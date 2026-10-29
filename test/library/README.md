# External library tests

## Serial CPU checks

Build the production archive and network preprocessor, then compile and run
the callers through the build's exported compiler/link settings:

```sh
make BUILD_NAME=library-test -j libxnet net_setup xnet
make -C test/library XNET_CONFIG=../../build/library-test/xnet-config.mk test
```

Use a different caller `BUILD_DIR` when checking another production
configuration, for example `BUILD_DIR=build-debug` for a debug archive.

Python 3 is required; there are no additional Python packages. The production
Starkiller EOS table must be present at its normal repository path. The tests
use the real dense serial CPU archive and selected EOS; they provide no
replacement solver, EOS, or provider routines. The first configuration is
GNU Fortran with `EOS=STARKILLER`, `MATRIX_SOLVER=dense`, and MPI, OpenMP, and
GPU disabled. Other configurations require their own evidence.

`api_consumer.F90` imports only `xnet_api`, standard intrinsic modules, and a
test fixture that contains no XNet imports. It links against `libxnet.a` and
the exported external libraries; no loose production objects are linked.
`legacy_reference.F90` is a separate process linked to the same archive. It
manually initializes the preexisting module state and calls `full_net`
directly. It does not use the public API or its setup/allocation helpers.
It starts the thermodynamic-history index at one, as the current
`t9rhofind`/`timestep` routines require for a two-point history. Starting at
zero would allow `timestep` to read element zero of a one-based history.
For fixed-temperature calls, both callers preserve the host's temperature
in kelvin rather than round-trip it through the internal GK representation.

The runner copies the public `Data_alpha` and `Data_SN160` inputs, preprocesses
those copies with `net_setup`, and stages an EOS-table symlink. All generated
data, diagnostics, and logs remain in a new directory under `build/runs/`.
Repeated runs preserve prior output. Tracked networks and references are not
modified.

The physical input is C/O at density `1e7 g/cm^3`, temperature `1.7` through
`1.85 GK`, and duration `0.1 s` per call. These conditions and integration
controls follow the maintained self-heating cases; the synthetic exact
composition avoids the rounding in historical molar-abundance files. The
first calls have `X(c12)=X(o16)=0.475` and a fixed auxiliary reservoir with
`X=0.05`, `A=56`, `Z=26`. Their input Ye includes that reservoir. A separate
call omits all auxiliary arguments and uses `X(c12)=X(o16)=0.5`, `Ye=0.5`.

Five cases exercise alpha BE with and without self-heating, alpha BDF without
self-heating, and SN160 BE/BDF with self-heating and weak-reaction neutrino
loss. Each runs a four-lane mask containing a hole, repeats the burn using
its outputs, calls a short three-lane batch, and calls an all-inactive batch.
It then omits optional auxiliaries and uses four-component diagnostic zone
IDs; the earlier calls use three-component IDs. Positive and zero restart
hints are supplied. The public caller finalizes twice, checks burns outside
the initialized lifetime, reinitializes, and repeats its first burn.

The comparison includes every species mass fraction, temperature in kelvin,
Ye, integrated neutrino loss in erg/g, the returned `tdel_old` in seconds, and
the five solver counters. The optional `max_steps_taken` result must equal
the direct `full_net` `kstep`, including zero for an all-inactive batch.
Selected rejected calls and all four numerical-failure cases must clear a
nonzero step-count sentinel. The reinitialized burn omits the new optional
argument to exercise an existing successful source call. A caller linked to
the unsupported API branch can use `--unsupported` to check its zero result.
The same serial archive and equivalent arithmetic
are expected to produce identical binary64 values; text output has enough
decimal digits for those values to round-trip. This compares wrapper
behavior with existing `full_net`; it is not an independent scientific
reference. No existing tolerances or reference values are changed. Timing
values are checked for finite nonnegative values, not compared across
processes. Inactive caller state must remain unchanged and its loss/counters
must be zero. Metadata names and order are compared with the staged `sunet`;
all A/Z and energy values are compared with the legacy nuclear-data arrays.

Validation checks cover invalid controls, duplicate initialization, unsupported
time-series output/preprocessing, invalid extents, incomplete auxiliary
arguments, NaN/Inf input, negative fractions/restart hints, invalid Ye, and an
auxiliary reservoir with invalid A.

The SN160 callers also interleave scalar NSE queries with the burns. The
public caller supplies temperature in K; the direct caller uses the existing
solver's GK input. Conditions are `(rho,T9,Ye) = (1e6,8,.45), (1e7,9,.49),
(1e8,11,.55)`, following the maintained standalone NSE input. Every species
in the returned `A*ynse` vector must agree exactly with the direct call;
normalization and scientific reference results are not part of this check.
Repeated queries and reinitialization reproduce the first composition, its
saved copy remains unchanged, and subsequent burns still match the direct
path. Invalid scalar inputs, result extents and lifecycle order return the
specified status and zero the submitted output vector. NSE solver failures
retain their existing fatal behavior; this change adds no recovery claim.

`failure_consumer.F90` also imports only the public API. Four alpha cases
exercise BE/BDF integrator-reported failure and the outer `kstmx` limit. The
integrator cases use valid but deliberately stringent test controls: BE has
one Newton iteration with `iconvc=1`, `tolc=1e-30`; BDF uses `tolc=1e-100` and
absolute tolerance `yacc=1e-100`. Normal tests and production defaults are not
changed. The step-limit cases use `kstmx=1`. These use the real integrators,
not injected failure flags or replacement solvers.

Each failure call uses a short batch with inactive holes, checks the returned
reason and original three/four-component IDs for active zone two, and requires
attempted counters and finite completed timing. The process ends after the
host receives the fatal error, without inspecting physical results or making
another library call. The runner requires no successful final output or
standalone failure files from the API. Separate standalone processes exercise
the same failure-control choices, must exit nonzero on the evolution-failure
path (not initialization/input failure), and must retain the existing
`ab_fail_001_001_001` / `th_fail_001_001_001` filenames. Logs record direct exit
status. The integrator-failure cases must show failed internal retries, while
the step-limit cases must not report integrator failure.

Checked validation and host-reported fatal burns do not provide application
retry, rollback, failed-instance reuse, or successful-lane continuation.
Reader/provider/allocation failures, singular solves, arbitrary nonfinite
arithmetic, concurrent instances, MPI, OpenMP, GPU and performance remain
outside these tests' claims.

## GPU consumer

`gpu_consumer.F90` is an opt-in hardware caller for the CUDA/cuBLAS and
HIP/ROCm dense archives. GPU execution of this consumer is pending; successful
CPU tests and preprocessing or compiler checks do not establish a GPU result.
The normal `test` target above remains the serial CPU suite. The
`gpu_consumer` target compiles and links the GPU caller without running it.

For example, with an installed NVHPC/CUDA environment, build from the
repository root:

```sh
make BUILD_NAME=library-gpu PE_ENV=NVHPC EOS=STARKILLER LAPACK_VER=NETLIB \
  MATRIX_SOLVER=dense MPI_MODE=OFF OPENMP_MODE=OFF GPU_MODE=ON \
  GPU_BACKEND=CUDA GPU_LAPACK_VER=CUBLAS OPENACC_MODE=ON OPENMP_OL_MODE=OFF \
  -j libxnet net_setup
make -C test/library XNET_CONFIG=../../build/library-gpu/xnet-config.mk \
  BUILD_DIR=build-gpu gpu_consumer
```

Supply `CUDA_DIR` when the build cannot locate the installed toolkit. For a
HIP/ROCm OpenMP target build, use the facility compiler and numerical
libraries, `GPU_BACKEND=HIP`, `GPU_LAPACK_VER=ROCM`, `OPENACC_MODE=OFF`, and
`OPENMP_OL_MODE=ON`, with the installed `HIPFORT_DIR` and `ROCM_DIR`. These
are build selections, not a claim that every compiler/library combination
works. Consult the current facility instructions for modules and placement.

The exported `XNET_CPPFLAGS` supplies `xnet_macros.fh`'s include directory and
the archive's actual accelerator definitions. The caller Makefile uses those
flags directly; no separate `GPU_DEFINES` setting is needed. The caller uses
the same compiler, modules and external libraries as the archive.

The input directories must contain the prepared `sunet`, `netwinv`, `nets3`,
`nets4`, and `match_data` files. The serial runner's `Data_alpha` and
`Data_SN160` copies can be reused on the same platform. Alternatively, prepare
fresh copies of those public fixtures with the selected build's `net_setup`:

```sh
xnet_root=$PWD
gpu_run=$(mktemp -d "${TMPDIR:-/tmp}/xnet-library-gpu.XXXXXX")
cp -R test/Data_alpha "$gpu_run/Data_alpha"
cp -R test/Data_SN160 "$gpu_run/Data_SN160"
for network in Data_alpha Data_SN160; do
  (
    cd "$gpu_run/$network"
    printf '%s\n' 'Public GPU embedding-library tests' | \
      "$xnet_root/build/library-gpu/bin/net_setup" > "$gpu_run/net_setup_$network.log" 2>&1
  )
done
ln -s "$xnet_root/tools/starkiller-helmholtz/helm_table.dat" "$gpu_run/helm_table.dat"
```

On a managed facility, run inside an approved compute allocation using its
launcher and GPU placement. The following are the executable arguments for
the five existing network/integrator/heating combinations; they do not
submit a job. The final integer chooses the application device, defaulting
to zero when omitted:

```sh
(
  set -e
  cd "$gpu_run"
  export OMP_NUM_THREADS=1
  export OMP_TARGET_OFFLOAD=MANDATORY
  "$xnet_root/test/library/build-gpu/gpu_consumer" Data_alpha 1 0 0 > alpha-be-heat0.log 2>&1
  "$xnet_root/test/library/build-gpu/gpu_consumer" Data_alpha 1 1 0 > alpha-be-heat1.log 2>&1
  "$xnet_root/test/library/build-gpu/gpu_consumer" Data_alpha 3 0 0 > alpha-bdf-heat0.log 2>&1
  "$xnet_root/test/library/build-gpu/gpu_consumer" Data_SN160 1 1 0 > SN160-be-heat1.log 2>&1
  "$xnet_root/test/library/build-gpu/gpu_consumer" Data_SN160 3 1 0 > SN160-bdf-heat1.log 2>&1
)
```

Each process requires a real device region and checks that XNet preserves
the application's selected device. It initializes once with XNet-owned
resources, then again with an application-owned nonblocking stream and BLAS handle.
After borrowed-resource finalization, a vendor GEMM checks that the handle
and stream still work. The OpenACC case also checks the caller's queue
association.

For each resource lifetime, the caller runs host-array and mapped-device
burns through first, repeated, short, inactive-hole, and all-inactive batches.
It deliberately makes the unused host or device mirrors disagree, compares
scientific results, counters and accepted step counts across the four paths
using the same archive, and checks inactive state preservation. After each
host-array call, a device region checks that all scientific device mirrors
still contain the original poison, returning only a logical result. Device
results are read immediately after the API returns without another stream
wait. Timings must be finite and nonnegative; they are not compared across
calls.

Each lifetime also requires mapped quiet-NaN and positive-infinity densities
to return the finite-input diagnostic with zero counters, accepted steps, and timing.

Two additional borrowed-resource calls queue four 256-by-256 GEMMs followed
by a GEMM that replaces poisoned device density with the fixture density.
The first call synchronizes the stream before entering the API; the second
enters with the producer work queued and keeps all producer mappings alive
through the burn. Both compare with the normal first burn. Submission is
asynchronous, but overlap with API entry depends on device scheduling. A
successful run alone does not demonstrate that removing the entry wait is
detected; record a missing-wait comparison separately when hardware permits it.

Logs contain raw metadata, states, counters, accepted step counts and timings,
plus `GPU_CONSUMER_CHECKS_COMPLETED` on completion. Keep these files outside
the checkout with the command, source revision, compiler/runtime versions,
and direct process status. The checks compare API paths on one backend;
they do not supply an independent scientific reference, CPU/GPU tolerance
policy, performance result, or validation of GPU numerical-failure reporting.
Existing CPU comparisons and failure policy are unchanged.
