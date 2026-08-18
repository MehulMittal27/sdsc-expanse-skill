# Troubleshooting Expanse

## Connection

**`error: no live Expanse session` (exit 78)**
Expected, not a bug. A human must run `scripts/expanse.sh login` and enter their
password and authenticator code. Ask them and wait. Never attempt to automate
the one-time code.

**Session dies mid-run**
`ControlPersist` expired or the network dropped. The job on the cluster keeps
running - SLURM does not care that you disconnected. Ask for a new login, then
`scripts/expanse.sh status <jobid>` to pick up where you were.

**`Too many authentication failures` or a temporary block**
Expanse blocks hosts connecting more than about 10 times a minute. Stop
retrying, wait a few minutes. Connection sharing exists precisely so that a
hundred agent commands are one connection.

**Key installed but still asked for a code**
Correct behavior. The key removes the password step; the second factor remains.

## Submission

| Message | Cause | Fix |
|---|---|---|
| `Invalid account or account/partition combination` | Wrong or missing `--account`, or the account has no access to that partition | `scripts/expanse.sh alloc`; set `EXPANSE_ACCOUNT` |
| `Invalid generic resource (gres) specification` | `--gpus=N` on the H100 partitions | Use `--gpus=h100:N` |
| `Requested node configuration is not available` | More cores, memory or GPUs than a node has | Check `reference/slurm.md` hardware table |
| `Requested time limit exceeds partition limit` | Over 48 h (30 min on debug) | Shorten, or split with `--dependency=afterok:` |
| `job script has no #SBATCH --account= line` | From this skill's own check | Use a template, keep `{{ACCOUNT}}` |
| Job vanishes instantly | Bad shebang or CRLF line endings | `head -1 job.sbatch`, `dos2unix job.sbatch` |

## Pending forever

`squeue -j <id> -o '%T %R'` prints the reason:

- `Priority` / `Resources` - normal queueing, just wait. Try `gpu-debug` for a
  quick test, or `gpu-preempt` for cheaper and sooner.
- `QOSMaxJobsPerUserLimit` - you already have 24 jobs on `gpu-shared`.
- `AssocGrpBillingMinutes` - the allocation is out of SUs. Escalate to the human.
- `PartitionConfig` / `PartitionTimeLimit` - the request cannot ever be satisfied
  by that partition. Fix the script, do not wait.
- `ReqNodeNotAvail` - reserved for maintenance. Check the SDSC status page.

## Running but wrong

**`torch.cuda.is_available()` is False**
Missing `module load gpu`; or missing `--nv` on `singularity exec`; or the job
landed on a CPU partition; or a CPU-only torch wheel is installed.

**Job is far slower than expected on `gpu-shared`**
Almost always the default 1 core and 1 GB per GPU. Add `--cpus-per-task` and
`--mem`. Data loading starves the GPU long before compute does.

**Multi-GPU job runs but is no faster, and the log repeats itself N times**
The script is not distribution-aware, so `torchrun` started N independent copies
of a single-process program. Each one trains the full dataset on its own GPU and
they overwrite each other's checkpoints. Either adopt DDP / HuggingFace `Trainer`
/ `accelerate` / Lightning, or drop to one GPU. `--launcher none` is only correct
if the script itself spreads work across GPUs, for example `nn.DataParallel`.

**Distributed job hangs at startup with no output**
The rendezvous never completed. Usual causes: `--ntasks-per-node` is not 1 under
`torchrun` (N launchers each spawning N workers), `MASTER_PORT` collides with
another job on a shared node (`--master-port`), or one rank crashed before
joining and the rest are still waiting. `NCCL_DEBUG=INFO` in place of the
generated `WARN` shows the handshake.

**`Killed` with no traceback**
Out of memory at the OS level. Raise `--mem`, or lower batch size or workers.
`sacct -j <id> --format=JobID,MaxRSS,ReqMem -X -P` shows what it actually used.

**`CUDA out of memory`**
GPU memory, distinct from the above. Lower batch size, enable gradient
checkpointing, or move to H100 nodes with more memory per GPU.

**`Disk quota exceeded`**
Something is writing to `/home`. Check `du -sh /home/$USER/*`, then redirect
caches as in `reference/filesystems.md`.

**Download hangs with no output**
Compute nodes may lack outbound internet. Pre-fetch on the login node, then set
`HF_HUB_OFFLINE=1`.

**Job hit the walltime (`TIMEOUT`)**
Checkpoint and resume. Write checkpoints to `$RUN_DIR`, not node-local scratch,
and use `--dependency=afterany:<id>` to chain the continuation.

## Globus transfers

**Task stays `ACTIVE` at 0 bytes**
Run `globus task event-list <task-id> --limit 3`. Usually
`PERMISSION_DENIED ... Path not allowed`, meaning the source path is outside what
Globus Connect Personal shares - by default only your home directory. Move the
data under `~` or add the path in GCP preferences.

**`The collection ... requires you to grant consent`**
Per-collection consent, and it needs a browser. Run `expanse globus-check`; it
prints the exact `globus session consent` command with the right IDs. A human runs
it. An agent must not attempt this.

**`this machine is not a Globus endpoint`**
Globus Connect Personal is not installed or not registered. Install it from
https://www.globus.org/globus-connect-personal, then `expanse globus-endpoints`.
Endpoints are per machine: a new laptop needs a new endpoint, and the old one
should be deleted with `globus endpoint delete <id>`.

## After the fact

```bash
sacct -j <id> --format=JobID,JobName%24,State,ExitCode,Elapsed,MaxRSS,ReqTRES%40 -X -P
seff <id>
```

`State=COMPLETED` with `ExitCode=0:0` is the only clean success. `COMPLETED` on
the job step while your program wrote a Python traceback into the log is still a
failure - read the log, do not trust the state alone.
