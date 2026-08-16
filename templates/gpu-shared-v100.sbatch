#!/bin/bash
# Expanse V100 GPU job on the shared partition (1-3 GPUs on one node).
# Use this for most single-node PyTorch / HuggingFace work: you are charged for
# what you request instead of for a whole 4-GPU node.
#
# Placeholders {{ACCOUNT}} and {{RUN_DIR}} are filled in by scripts/expanse.sh.
#
# Sizing rule: gpu-shared gives you 1 CPU and 1 GB per GPU BY DEFAULT, which is
# far too little. Always request explicitly. A V100 node has 40 cores and
# 377300M usable, so one quarter of a node is about 10 cores and 92G.

#SBATCH --job-name=torch-v100
#SBATCH --account={{ACCOUNT}}
#SBATCH --partition=gpu-shared
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gpus=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=92G
#SBATCH --time=02:00:00
#SBATCH --output={{RUN_DIR}}/logs/%x.%j.out
#SBATCH --error={{RUN_DIR}}/logs/%x.%j.err
#SBATCH --no-requeue

set -euo pipefail

module purge
module load gpu
module load slurm

# Node-local NVMe: fastest scratch, wiped when the job ends.
export LOCAL_SCRATCH="/scratch/$USER/job_$SLURM_JOB_ID"
mkdir -p "$LOCAL_SCRATCH"

# Keep package and model caches OFF /home (100 GB quota, not built for throughput).
export RUN_DIR="{{RUN_DIR}}"
export HF_HOME="$RUN_DIR/cache/huggingface"
export TORCH_HOME="$RUN_DIR/cache/torch"
export PIP_CACHE_DIR="$RUN_DIR/cache/pip"
export TMPDIR="$LOCAL_SCRATCH"
mkdir -p "$HF_HOME" "$TORCH_HOME" "$PIP_CACHE_DIR"

cd "$RUN_DIR"

# --- environment: pick ONE of the following -------------------------------
# (a) conda environment installed under Lustre, not /home:
# source "$RUN_DIR/miniconda3/etc/profile.d/conda.sh"
# conda activate myenv
#
# (b) SDSC-provided singularity image:
# singularity exec --nv /cm/shared/apps/containers/singularity/pytorch/pytorch-latest.sif \
#     python train.py
# --------------------------------------------------------------------------

echo "host=$(hostname) job=$SLURM_JOB_ID gpus=${CUDA_VISIBLE_DEVICES:-none}"
nvidia-smi --query-gpu=index,name,memory.total --format=csv

python train.py

echo "exit=$? finished=$(date -Is)"
