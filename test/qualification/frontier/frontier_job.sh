#!/bin/bash

set -u -o pipefail

artifact_root=$1
source_sha=$2
archive_sha256=$3
build_jobs=$4
time_limit=$5
source_root="${artifact_root}/source"
runner="${source_root}/test/qualification/frontier/frontier_qualification.py"
launcher_status="${artifact_root}/srun.status.txt"

srun \
  --nodes=1 \
  --ntasks=1 \
  --cpus-per-task="${SLURM_CPUS_PER_TASK:-7}" \
  --gpus-per-task=1 \
  --gpu-bind=closest \
  python3 "${runner}" run \
    --source-root="${source_root}" \
    --artifact-root="${artifact_root}" \
    --source-sha="${source_sha}" \
    --archive-sha256="${archive_sha256}" \
    --build-jobs="${build_jobs}" \
    --time-limit="${time_limit}"
status=$?
printf '%s\n' "${status}" > "${launcher_status}"

if [[ ${status} -ne 0 && ! -f "${artifact_root}/qualification_manifest.json" ]]; then
  python3 "${runner}" failure \
    --artifact-root="${artifact_root}" \
    --source-sha="${source_sha}" \
    --archive-sha256="${archive_sha256}" \
    --time-limit="${time_limit}" \
    --category=allocation \
    --phase=slurm-step \
    --message="srun could not start or complete the qualification step"
fi

exit "${status}"
