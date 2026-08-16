# SLURM on Expanse

Source: <https://www.sdsc.edu/systems/expanse/user_guide.html>. Where this file
says "verify", the number is a reasonable default rather than a quoted figure -
confirm it live before relying on it.

## Partitions

| Partition | Nodes | Max walltime | Max nodes/job | Charge | Notes |
|---|---|---|---|---|---|
| `compute` | CPU | 48 h | 32 | 1x | Exclusive whole nodes |
| `shared` | CPU | 48 h | 1 | 1x | Slice of a node, under 128 cores |
| `large-shared` | CPU | 48 h | 1 | 1x | Large memory, 256 GB minimum |
| `gpu` | 4x V100 | 48 h | 4 | 1x | Exclusive whole nodes |
| `gpu-shared` | V100 | 48 h | 1 | 1x | Under 4 GPUs on one node |
| `nairr-gpu` | 4x H100 | 48 h | 4 | 1x | Expanse AI Resource, exclusive |
| `nairr-gpu-shared` | H100 | 48 h | 1 | 1x | Under 4 H100s on one node |
| `debug` | CPU | 30 min | 2 | 1x | Priority access for quick tests |
| `gpu-debug` | GPU | 30 min | 2 | 1x | Max 2 GPUs |
| `preempt` | CPU | 7 days | 32 | 0.8x | Can be killed by higher-priority work |
| `gpu-preempt` | GPU | 7 days | 1 | 0.8x | Same, discounted |

`gpu-shared` queue limits: max 4 GPUs per job, max 24 running jobs, max 24
running plus queued.

## Hardware

**Standard GPU node (52 of them)**
- 4x NVIDIA V100 SXM2
- 2x Xeon Gold 6248, 20 cores each, 40 cores total, 2.5 GHz
- 384 GB DDR4, `--mem` maximum `377300M`
- 1.6 TB NVMe local scratch

**Expanse AI Resource, H100 (34 nodes)**
- 4x NVIDIA H100
- 2x 36-core Intel Sapphire Rapids, 72 cores total
- 1 TB RAM
- 6.4 TB NVMe local scratch

**CPU compute node**
- 128 cores, 256 GB (verify usable `--mem` with `sinfo -p shared -o '%c %m'`)
- 1 TB NVMe local scratch

Per-GPU sizing that leaves a node evenly divisible:

| | cores per GPU | memory per GPU |
|---|---|---|
| V100 | 10 | 92G |
| H100 | 18 | 240G (verify) |

## Required directives

```bash
#SBATCH --account=<project>     # mandatory; without it the job is rejected
#SBATCH --partition=<name>
#SBATCH --nodes=1
#SBATCH --time=HH:MM:SS
#SBATCH --output=<path>/%x.%j.out
```

GPUs:

```bash
#SBATCH --gpus=2                # V100 partitions
#SBATCH --gpus=h100:2           # AI resource - the type prefix is REQUIRED
```

On `gpu-shared`, the default per GPU is 1 CPU and 1 GB of memory. Always add:

```bash
#SBATCH --cpus-per-task=10
#SBATCH --mem=92G
```

Other useful directives:

```bash
#SBATCH --no-requeue                  # do not silently restart on node failure
#SBATCH --constraint=exclusive        # exclusive GPU access
#SBATCH --constraint=persistenceoff   # disable GPU persistence mode
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=you@example.edu
```

A job that is requeued more than 5 times enters `REQUEUE_HOLD`.

## Commands

```bash
sbatch job.sbatch                        # submit
sbatch --parsable job.sbatch             # submit, print bare job id
sbatch --dependency=afterok:<id> next.sbatch
squeue -u $USER                          # my queue
squeue -j <id> -o '%T %R'                # state and reason
scancel <id>
sacct -j <id> --format=JobID,State,ExitCode,Elapsed,MaxRSS -X -P
seff <id>                                # efficiency report, if available
sinfo -p gpu-shared -o '%P %a %D %T'     # partition availability
scontrol show job <id>                   # everything about a queued job
expanse-client user -r expanse           # allocations and remaining SUs
expanse-client project <project> -p      # project spending detail
```

## Interactive sessions

```bash
srun --partition=gpu-debug --pty --account=<project> \
     --nodes=1 --ntasks-per-node=10 --gpus=1 --mem=96G \
     -t 00:30:00 --wait=0 --export=ALL /bin/bash
```

Compile inside an interactive session rather than on a login node, because the
login nodes are a different architecture from the batch nodes.

## MPI

```bash
srun --mpi=pmi2 -n 256 ./hello_mpi                      # MVAPICH2
mpirun -genv I_MPI_PIN_DOMAIN=omp:compact ./hello_hybrid # Intel MPI, hybrid
```

## Charging

On exclusive partitions (`compute`, `gpu`, `nairr-gpu`) you are charged for the
whole node for the whole requested walltime, used or not. On shared partitions
you are charged for the resources you requested. Preempt partitions bill at 0.8x
but your job can be killed at any time, so checkpoint.
