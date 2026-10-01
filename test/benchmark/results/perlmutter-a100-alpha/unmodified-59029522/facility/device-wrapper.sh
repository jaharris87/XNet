#!/bin/bash
set -u

printf 'xnet_host=%s\n' "$(hostname)"
printf 'CUDA_VISIBLE_DEVICES=%s\n' "${CUDA_VISIBLE_DEVICES:-unset}"
printf 'SLURM_STEP_GPUS=%s\n' "${SLURM_STEP_GPUS:-unset}"
printf 'SLURM_LOCALID=%s\n' "${SLURM_LOCALID:-unset}"
printf 'cpu_affinity='
taskset -pc $$ 2>&1 || true
nvidia-smi -L 2>&1 || true

exec "$@"
