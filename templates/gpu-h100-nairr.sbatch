#!/bin/bash
# Expanse AI Resource: NVIDIA H100 nodes (4 x H100, 72 cores, 1 TB RAM,
# 6.4 TB local NVMe). Use this for large models and long-context LLM work.
#
# Two differences from the V100 partitions that will silently reject your job if
# you get them wrong:
#   1. the partition is nairr-gpu-shared (or nairr-gpu for whole nodes)
#   2. the GPU type MUST be named:  --gpus=h100:N   not  --gpus=N
#
# This resource needs an allocation that covers it. Confirm with:
#   expanse-client user -r expanse
#   sinfo -p nairr-gpu-shared

#SBATCH --job-name=llm-h100
#SBATCH --account={{ACCOUNT}}
#SBATCH --partition=nairr-gpu-shared
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gpus=h100:1
#SBATCH --cpus-per-task=18           # ~1/4 of the 72 cores
#SBATCH --mem=240G                   # ~1/4 of 1 TB; verify with: scontrol show node <n>
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
mkdir -p "$LOCAL_SCRATCH"

# Model weights are large. Keep every cache on Lustre or node-local NVMe.
export HF_HOME="$RUN_DIR/cache/huggingface"
export HF_HUB_ENABLE_HF_TRANSFER=1
export TRANSFORMERS_CACHE="$HF_HOME/hub"
export TMPDIR="$LOCAL_SCRATCH"
mkdir -p "$HF_HOME"
cd "$RUN_DIR"

# Compute nodes have no outbound internet on some SDSC configurations. If a
# model download hangs, pre-fetch it on the LOGIN node into $HF_HOME first, then
# run offline:
# export HF_HUB_OFFLINE=1

# SDSC ships PyTorch/TensorFlow singularity images for this resource; sample
# batch scripts live at /cm/shared/examples/sdsc/ExpanseAIR/pytorch
# singularity exec --nv <image.sif> python infer.py

nvidia-smi --query-gpu=index,name,memory.total --format=csv
python infer.py
