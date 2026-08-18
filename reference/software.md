# Software environment on Expanse

## Modules

Expanse uses Lmod. You will see almost nothing from `module avail` until you load
a base module first - this surprises people constantly.

```bash
module purge
module load cpu          # for CPU nodes and CPU builds
module load gpu          # for GPU nodes and CUDA builds
module load slurm
module avail             # now shows the real list
module spider pytorch    # search everything, including hidden dependencies
module list
module display <name>    # what it changes
```

Always `module purge` at the top of a batch script so the job does not inherit a
half-configured login environment.

## Python environments

### conda / mamba, installed on Lustre

Do **not** install a conda environment into `/home`: 100 GB goes fast and Lustre
is the right place for it.

**This is the route that works today.** Verified end to end on Expanse: torch
2.5.1+cu121 in a conda env on Lustre, GPU visible, jobs running on V100s.

```bash
# once, on a login node
cd /expanse/lustre/scratch/$USER/temp_project/<project>
curl -LO https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
bash Miniforge3-Linux-x86_64.sh -b -p "$PWD/miniconda3"
source "$PWD/miniconda3/etc/profile.d/conda.sh"
export CONDA_PKGS_DIRS="$PWD/cache/conda"
conda create -y -n myenv python=3.11
conda activate myenv
pip install torch --index-url https://download.pytorch.org/whl/cu121
```

In every batch script:

```bash
source "$RUN_DIR/miniconda3/etc/profile.d/conda.sh"
conda activate myenv
```

Do not run `conda init`: it edits your shell profile and makes login behavior
depend on invisible state.

### Singularity / Apptainer containers

**Verified August 2026: SDSC's provided PyTorch image does not work on the GPU
nodes.** `/cm/shared/apps/containers/singularity/pytorch/pytorch-latest.sif` is
from April 2024, and against the current node driver (580.82.07) it fails with:

```
Failed to initialize NVML: Driver/library version mismatch
torch ... cuda_build 12.1 avail False count 0
```

The job runs to completion on the CPU and reports success, so this is easy to
miss - always print `torch.cuda.is_available()` at the top of a run. Every image
under `/expanse/projects/qstore/installs/containers/singularity/pytorch/` is of
the same vintage and fails the same way. Use a conda environment instead (below)
until SDSC refreshes them.

If you do use a container, `--sif` needs the runtime module. `wrap` loads
`singularitypro` automatically; by hand it is `module load singularitypro` before
`singularity exec --nv`.

Sample batch scripts for the AI resource live at
`/cm/shared/examples/sdsc/ExpanseAIR/pytorch`.

```bash
singularity exec --nv \
  --bind /expanse/lustre/scratch/$USER:/data \
  <image>.sif python train.py
```

`--nv` is what exposes the GPUs. Without it, `torch.cuda.is_available()` is False
inside the container and the job silently runs on CPU.

Locate available images with `ls /cm/shared/apps/containers/singularity/` and
`module spider singularity` - the exact set changes, so look rather than guess.

## PyTorch checklist

Put this at the top of a training script so failures are loud and immediate:

```python
import torch, os
assert torch.cuda.is_available(), "no GPU visible - check --gpus and module load gpu"
print(torch.__version__, torch.version.cuda, torch.cuda.device_count())
print("visible:", os.environ.get("CUDA_VISIBLE_DEVICES"))
```

SLURM sets `CUDA_VISIBLE_DEVICES` for you. Never set it yourself in a batch job:
you will either hide the GPU you were allocated or reach for one you were not.

Multi-GPU on one node uses `torchrun --nproc_per_node=<gpus>`. Multi-node adds
`--nnodes` and a rendezvous endpoint derived from `SLURM_JOB_NODELIST`; see
`templates/gpu-full-node-v100.sbatch`.

## HuggingFace

```bash
export HF_HOME="$RUN_DIR/cache/huggingface"
export HF_HUB_ENABLE_HF_TRANSFER=1     # much faster large downloads
export HF_TOKEN=...                    # only if you need gated models
```

Compute nodes may have no outbound internet. The reliable pattern is to download
on the **login node** (this is light I/O, which login nodes are for) and then run
the job offline:

```bash
# login node
python -c "from huggingface_hub import snapshot_download; snapshot_download('org/model')"
# batch script
export HF_HUB_OFFLINE=1
```

A model download that hangs with no error on a compute node is nearly always this.

## GPU sanity checks inside a job

```bash
nvidia-smi --query-gpu=index,name,memory.total,memory.used --format=csv
nvidia-smi --query-compute-apps=pid,used_memory --format=csv
```

To watch utilization during a run, log it in the background:

```bash
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv -l 60 > "$RUN_DIR/logs/gpu.$SLURM_JOB_ID.csv" &
```
