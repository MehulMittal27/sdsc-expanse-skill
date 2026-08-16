#!/bin/bash
# Expanse CPU job on the shared partition: data preprocessing, feature
# extraction, anything that does not need a GPU.
#
# A compute node has 128 cores and roughly 256 GB; confirm the exact usable
# figure with: sinfo -p shared -o '%c %m'. The shared partition lets you take a
# slice of one node; the compute partition gives whole exclusive nodes (and
# charges for all 128 cores). Use large-shared for jobs needing over 256 GB.

#SBATCH --job-name=cpu-prep
#SBATCH --account={{ACCOUNT}}
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --output={{RUN_DIR}}/logs/%x.%j.out
#SBATCH --error={{RUN_DIR}}/logs/%x.%j.err
#SBATCH --no-requeue

set -euo pipefail

module purge
module load cpu
module load slurm

export RUN_DIR="{{RUN_DIR}}"
export LOCAL_SCRATCH="/scratch/$USER/job_$SLURM_JOB_ID"
export TMPDIR="$LOCAL_SCRATCH"
export OMP_NUM_THREADS="$SLURM_CPUS_PER_TASK"
mkdir -p "$LOCAL_SCRATCH"
cd "$RUN_DIR"

python prepare_data.py
