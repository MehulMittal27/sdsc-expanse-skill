# SLURM on Expanse

Source: <https://www.sdsc.edu/systems/expanse/user_guide.html>. Where this file
says "verify", the number is a reasonable default rather than a quoted figure -
confirm it live before relying on it.

## Partitions

The **Notes** column reflects the SLURM QOS, which is authoritative. Where it
disagrees with SDSC's prose documentation, the QOS wins - see the table below.

| Partition | Nodes | Max walltime | Max nodes/job | Charge | Notes |
|---|---|---|---|---|---|
| `compute` | CPU | 48 h | 32 | 1x | Exclusive whole nodes |
| `shared` | CPU | 48 h | 1 | 1x | Slice of a node, under 128 cores |
| `large-shared` | CPU | 48 h | 1 | 1x | Large memory, 256 GB minimum |
| `gpu` | 4x V100 | 48 h | 4 | 1x | Exclusive whole nodes |
| `gpu-shared` | V100 | 48 h | 1 | 1x | **Max 3 GPUs** per job (QOS), not 4 |
| `nairr-gpu` | 4x H100 | 48 h | 4 | 1x | Expanse AI Resource, exclusive |
| `nairr-gpu-shared` | H100 | 48 h | 1 | 1x | Under 4 H100s on one node |
| `debug` | CPU | 30 min | 2 | 1x | Priority access for quick tests |
| `gpu-debug` | GPU | 30 min | 2 | 1x | Up to 8 GPUs (QOS), not 2 |
| `preempt` | CPU | 7 days | 32 | 0.8x | Can be killed by higher-priority work |
| `gpu-preempt` | GPU | 7 days | 1 | 0.8x | Same, discounted |

**The real limits come from SLURM QOS, and they differ from the user guide.**
Check them yourself with `sacctmgr show qos format=Name,MaxTRESPerJob%40,MaxWall,MaxJobsPU -P`:

| QOS | Per-job ceiling | Max wall | Jobs per user |
|---|---|---|---|
| `gpu-shared-normal` | **3 GPUs**, 37 CPUs, 353000M, 1 node | 48 h | 24 |
| `gpu-normal` | 16 GPUs, 4 nodes | 48 h | 4 |
| `gpu-debug-normal` | **8 GPUs**, 2 nodes | 30 min | 2 |
| `gpu-preempt-normal` | 8 GPUs, 2 nodes | 7 days | 12 |

Two of these contradict the prose documentation: `gpu-shared` takes **3** GPUs
per job, not 4, and asking for 4 fails with `QOSMaxCpuPerJobLimit` rather than a
message about GPUs. `gpu-debug` takes up to **8**, not 2. For 4 GPUs on one node
use `--partition gpu`, which allocates the whole node exclusively.

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

| | cores per GPU | memory per GPU | per-job ceiling |
|---|---|---|---|
| V100 `gpu-shared` | 10 | 92G | 37 cores, 344G, 3 GPUs |
| V100 `gpu` (whole node) | 10 | 92G | 40 cores, 368G, 4 GPUs |
| H100 | 18 | 240G (verify) | verify with `sacctmgr` |

### Measured scaling, V100, small model (August 2026)

| GPUs | Wall time | Throughput | Speedup |
|---|---|---|---|
| 1 | 6.1s | 98,431 samples/s | 1.0x |
| 2 | 3.8s | 157,361 samples/s | 1.6x |
| 4 | 2.8s | 210,837 samples/s | 2.1x |

Scaling is sub-linear because gradient synchronisation costs time; on a small
model that cost is a large share of each step. Larger models and batches scale
better, but **never assume linear** - measure before buying more GPUs.

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
