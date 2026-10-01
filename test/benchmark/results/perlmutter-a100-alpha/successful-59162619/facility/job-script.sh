#!/bin/bash -l

set -u -o pipefail

work=/pscratch/sd/j/jaharris/xnet_issue152
source_root="$work/isolate-t9-only"
source_revision=097433d7d627600e2799b070a9fba7240fee32d5
base_revision=86e867c2a64267a674ce4fbf6a3064af39e2f4e0
reference_fix=3ef3cc82e46d53d7d9ee553d8e66b6246999d557
runner="$work/runner-24c7d8a-155"
runner_revision=24c7d8a924035c3bd181c220dc68b35bfe5cdb4d
wrapper="$work/xnet-152-adjusted-device-wrapper.sh"
build="$work/build-root-fix-$SLURM_JOB_ID"
record="$work/record-root-fix-$SLURM_JOB_ID"
details="$work/details-root-fix-$SLURM_JOB_ID"
benchmark_dir="$details/benchmark"

mkdir -p "$details"
cp "$work/xnet-final-root-benchmark.sh" "$details/job-script.sh"
cp "$wrapper" "$details/device-wrapper.sh"
cp -R "$runner/test/benchmark" "$benchmark_dir"
sed -i "s/\"historical_source_revision\": \"[^\"]*\"/\"historical_source_revision\": \"$source_revision\"/" "$benchmark_dir/cases.json"

module load python/3.12-25.3.0
module load PrgEnv-nvidia

hostname > "$details/hostname.txt"
module list > "$details/modules.txt" 2>&1
nvfortran --version > "$details/nvfortran-version.txt" 2>&1
nvidia-smi -L > "$details/nvidia-smi-L.txt" 2>&1
nvidia-smi topo -m > "$details/nvidia-smi-topo.txt" 2>&1
scontrol show job "$SLURM_JOB_ID" --oneliner > "$details/slurm-job.txt"
sha256sum "$details/job-script.sh" "$details/device-wrapper.sh" > "$details/scripts.sha256"

git -C "$source_root" log -2 --format='%H %T %P %s' > "$details/source-log-before.txt"
git -C "$source_root" status --porcelain=v1 --untracked-files=all > "$details/source-status-before.txt"
git -C "$source_root" diff "$base_revision" HEAD -- source/xnet_conditions.F90 > "$details/applied-root-fix.diff"
git -C "$source_root" show --format= "$reference_fix" -- source/xnet_conditions.F90 > "$details/reference-root-fix.diff"
git -C "$runner" log -1 --format='%H %T %s' > "$details/runner-before.txt"
git -C "$runner" status --porcelain=v1 --untracked-files=all > "$details/runner-status-before.txt"
sha256sum "$benchmark_dir/run.py" "$benchmark_dir/cases.json" > "$details/benchmark-files-before.sha256"

validation_status=0
test "$(git -C "$source_root" rev-parse HEAD)" = "$source_revision" || validation_status=1
test "$(git -C "$source_root" rev-parse HEAD^)" = "$base_revision" || validation_status=1
test ! -s "$details/source-status-before.txt" || validation_status=1
test "$(git -C "$source_root" diff --name-only "$base_revision" HEAD)" = source/xnet_conditions.F90 || validation_status=1
cmp -s "$details/applied-root-fix.diff" "$details/reference-root-fix.diff" || validation_status=1
test "$(git -C "$runner" rev-parse HEAD)" = "$runner_revision" || validation_status=1
git -C "$runner" diff --quiet HEAD -- test/benchmark/run.py || validation_status=1
test "$validation_status" -eq 0 || {
  printf 'pre-run source or runner validation failed\n' > "$details/failure.txt"
  exit 1
}

unset NVCOMPILER_ACC_NOTIFY
unset NVCOMPILER_ACC_TIME

python3 "$benchmark_dir/run.py" \
  --source "$source_root" \
  --source-revision "$source_revision" \
  --input-root "$runner" \
  --case alpha --zones 4 --batch-size 4 \
  --build-dir "$build" \
  --output "$record" \
  --make-option PE_ENV=NVIDIA --make-option CMODE=OPT \
  --make-option MACHINE=perlmutter \
  --make-option MPI_MODE=OFF --make-option OPENMP_MODE=OFF \
  --make-option GPU_MODE=ON --make-option GPU_BACKEND=CUDA \
  --make-option GPU_LAPACK_VER=CUBLAS --make-option OPENACC_MODE=ON \
  --make-option OPENMP_OL_MODE=OFF --make-option MATRIX_SOLVER=dense \
  --make-option LAPACK_VER=LIBSCI \
  --launcher "srun --nodes=1 --ntasks=1 --cpus-per-task=32 --gpus-per-task=1 --cpu-bind=cores --gpu-bind=per_task:1 $wrapper" \
  --ranks 1 --threads 1 --repetitions 3 --jobs 8 --timeout-seconds 600
runner_status=$?

printf '%s\n' "$runner_status" > "$details/runner-status-code.txt"
git -C "$source_root" log -2 --format='%H %T %P %s' > "$details/source-log-after.txt"
git -C "$source_root" status --porcelain=v1 --untracked-files=all > "$details/source-status-after.txt"
sha256sum "$benchmark_dir/run.py" "$benchmark_dir/cases.json" > "$details/benchmark-files-after.sha256"

post_status=0
test ! -s "$details/source-status-after.txt" || post_status=1
cmp -s "$details/source-log-before.txt" "$details/source-log-after.txt" || post_status=1
cmp -s "$details/benchmark-files-before.sha256" "$details/benchmark-files-after.sha256" || post_status=1
if test -f "$record/result.json"; then
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["status"], [(x["process_status"], x["execution"], x["numerical"], x["wall_seconds"]) for x in r.get("repetitions", [])]); raise SystemExit(0 if r["status"] == "PASS" else 1)' "$record/result.json" || post_status=1
else
  post_status=1
fi
printf '%s\n' "$post_status" > "$details/post-run-status.txt"
printf 'record=%s\ndetails=%s\n' "$record" "$details"

test "$runner_status" -eq 0
test "$post_status" -eq 0
