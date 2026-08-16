#!/bin/bash
# Expanse V100 job with exclusive whole nodes (4 GPUs each), for multi-GPU or
# multi-node distributed training.
#
# You are charged for the ENTIRE node whether or not you use all 4 GPUs, so only
# use this partition when you genuinely need the whole node.
# Max 4 nodes per job, max 48 hours.

#SBATCH --job-name=torch-ddp
#SBATCH --account={{ACCOUNT}}
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=4          # one task per GPU
#SBATCH --gpus=4
#SBATCH --cpus-per-task=10
#SBATCH --mem=377300M                # whole-node memory
#SBATCH --time=04:00:00
#SBATCH --output={{RUN_DIR}}/logs/%x.%j.out
#SBATCH --error={{RUN_DIR}}/logs/%x.%j.err
#SBATCH --no-requeue

set -euo pipefail

module purge
module load gpu
module load slurm

export RUN_DIR="{{RUN_DIR}}"
export LOCAL_SCRATCH="/scratch/$USER/job_$SLURM_JOB_ID"
export HF_HOME="$RUN_DIR/cache/huggingface"
export TORCH_HOME="$RUN_DIR/cache/torch"
export TMPDIR="$LOCAL_SCRATCH"
mkdir -p "$LOCAL_SCRATCH" "$HF_HOME" "$TORCH_HOME"
cd "$RUN_DIR"

# torchrun rendezvous across nodes
MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n1)
export MASTER_ADDR
export MASTER_PORT=29500
export NCCL_DEBUG=WARN

# source "$RUN_DIR/miniconda3/etc/profile.d/conda.sh" && conda activate myenv

srun --cpu-bind=cores torchrun \
  --nnodes="$SLURM_NNODES" \
  --nproc_per_node=4 \
  --rdzv_backend=c10d \
  --rdzv_endpoint="$MASTER_ADDR:$MASTER_PORT" \
  train.py
