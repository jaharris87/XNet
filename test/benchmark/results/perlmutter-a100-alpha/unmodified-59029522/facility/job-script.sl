#!/bin/bash -l
#SBATCH --account=m1373_g
#SBATCH --qos=shared
#SBATCH --constraint=gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --gpus-per-task=1
#SBATCH --time=00:30:00
#SBATCH --job-name=xnet-152-pm-gpu
#SBATCH --output=/pscratch/sd/j/jaharris/xnet_issue152/slurm-%j.out

set -u -o pipefail

WORK=/pscratch/sd/j/jaharris/xnet_issue152
RUNNER=$WORK/runner
SOURCE=/pscratch/sd/j/jaharris/xnet_work/source-86e867c2
BUILD=$WORK/build-$SLURM_JOB_ID
RECORD=$WORK/record-$SLURM_JOB_ID
DETAILS=$WORK/details-$SLURM_JOB_ID

mkdir -p "$DETAILS"

module load python/3.12-25.3.0
module load PrgEnv-nvidia

hostname > "$DETAILS/hostname.txt"
module list 2> "$DETAILS/modules.txt"
nvfortran --version > "$DETAILS/nvfortran-version.txt" 2>&1
nvidia-smi -L > "$DETAILS/nvidia-smi-L.txt" 2>&1
scontrol show job "$SLURM_JOB_ID" --oneliner > "$DETAILS/slurm-job.txt"
git -C "$SOURCE" rev-parse HEAD > "$DETAILS/source-head-before.txt"
git -C "$SOURCE" status --porcelain --untracked-files=no > "$DETAILS/source-status-before.txt"
git -C "$RUNNER" rev-parse HEAD > "$DETAILS/runner-head.txt"
git -C "$RUNNER" status --porcelain --untracked-files=no > "$DETAILS/runner-status.txt"

export NVCOMPILER_ACC_NOTIFY=1

python3 "$RUNNER/test/benchmark/run.py" \
  --source "$SOURCE" \
  --source-revision 86e867c2a64267a674ce4fbf6a3064af39e2f4e0 \
  --input-root "$RUNNER" \
  --case alpha --zones 4 --batch-size 4 \
  --build-dir "$BUILD" \
  --output "$RECORD" \
  --make-option PE_ENV=NVIDIA --make-option CMODE=OPT \
  --make-option MACHINE=perlmutter \
  --make-option MPI_MODE=OFF --make-option OPENMP_MODE=OFF \
  --make-option GPU_MODE=ON --make-option GPU_BACKEND=CUDA \
  --make-option GPU_LAPACK_VER=CUBLAS --make-option OPENACC_MODE=ON \
  --make-option OPENMP_OL_MODE=OFF --make-option MATRIX_SOLVER=dense \
  --make-option LAPACK_VER=LIBSCI \
  --launcher "srun --nodes=1 --ntasks=1 --cpus-per-task=32 --gpus-per-task=1 --cpu-bind=cores --gpu-bind=per_task:1 $WORK/xnet-152-device-wrapper.sh" \
  --ranks 1 --threads 1 --repetitions 1 --jobs 8 --timeout-seconds 600
status=$?

printf '%s\n' "$status" > "$DETAILS/runner-status-code.txt"
git -C "$SOURCE" rev-parse HEAD > "$DETAILS/source-head-after.txt"
git -C "$SOURCE" status --porcelain --untracked-files=no > "$DETAILS/source-status-after.txt"
exit "$status"
