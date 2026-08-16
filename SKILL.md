---
name: sdsc-expanse
description: Run compute jobs end to end on the SDSC Expanse supercomputer (V100 and H100 GPU nodes, CPU nodes, SLURM). Use whenever the task involves Expanse, SDSC, login.expanse.sdsc.edu, an ACCESS/NAIRR allocation, submitting or monitoring sbatch/srun/squeue jobs on a cluster, training or running a model on remote GPUs, or moving data to and from HPC scratch storage.
---

# SDSC Expanse

Drive the SDSC Expanse cluster: connect, move data, submit SLURM jobs, watch them,
retrieve results. Everything goes through `scripts/expanse.sh`, which never blocks
on an interactive prompt.

Authoritative vendor documentation: <https://www.sdsc.edu/systems/expanse/user_guide.html>

## Before anything else

Run this. It is cheap and it tells you whether you can work at all:

```bash
scripts/expanse.sh check && scripts/expanse.sh config
```

- `live` means the shared SSH session is up. Proceed.
- `dead`, or exit code 78 from any command, means **stop and ask the human**.
  Expanse demands a one-time authenticator code on every login, so you cannot
  open the connection yourself. Tell them, verbatim:

  > Please run `scripts/expanse.sh login` in your terminal and enter your
  > password and 6-digit code. I will continue once the session is up.

  Do not try `ssh` directly, do not try to script the code, do not retry in a
  loop. Wait for the human.
- If `config` shows `EXPANSE_USER=<unset>` or `EXPANSE_ACCOUNT=<unset>`, the
  human must run `scripts/expanse-setup.sh` once. See `INSTALL.md`.

## The five rules that matter

1. **Never run compute on the login node.** No training, no long data
   processing, no large downloads-in-a-loop. Login nodes are for editing files
   and submitting jobs. Everything real goes through `sbatch`.
2. **Never run jobs out of `/home`.** It is 100 GB and not built for throughput.
   Code lives in `/home/$USER/expanse-agent/<project>`; data, outputs, caches and
   the working directory live in
   `/expanse/lustre/scratch/$USER/temp_project/<project>`.
3. **Prefer `gpu-shared` over `gpu`.** The `gpu` partition charges you for a whole
   4-GPU node even if you use one GPU. Only take whole nodes for real multi-GPU work.
4. **On `gpu-shared` you must request CPUs and memory explicitly.** The default is
   1 core and 1 GB per GPU, which will make a job look mysteriously slow or get it
   OOM-killed.
5. **Lustre is not backed up and is purged.** Scratch files disappear 90 days
   after creation. Pull anything you care about back with `expanse.sh pull`.

## Standard workflow

```bash
# 0. confirm the session and the allocation
scripts/expanse.sh check
scripts/expanse.sh alloc                     # remaining SUs per project

# 1. stage code and data (code -> home, data -> Lustre scratch)
scripts/expanse.sh push-code ./src
scripts/expanse.sh push ./data

# 2. pick a template, edit it, submit
cp templates/gpu-shared-v100.sbatch ./train.sbatch
#   ... edit resources and the command ...
JOB=$(scripts/expanse.sh submit ./train.sbatch)

# 3. watch
scripts/expanse.sh status "$JOB"             # PENDING / RUNNING / final state
scripts/expanse.sh wait "$JOB"               # block until it leaves the queue
scripts/expanse.sh logs "$JOB"               # stdout

# 4. bring results home
scripts/expanse.sh pull outputs ./results
```

`scripts/expanse.sh run ./train.sbatch` does submit + wait + logs in one call.

`{{ACCOUNT}}` and `{{RUN_DIR}}` in a template are filled in automatically at
submit time from the configured account and project. Leave them as placeholders.

## Choosing a partition

| Need | Partition | Template | Notes |
|---|---|---|---|
| 1-3 V100 GPUs, one node | `gpu-shared` | `templates/gpu-shared-v100.sbatch` | Default choice. 48 h max |
| 4+ V100 GPUs, DDP | `gpu` | `templates/gpu-full-node-v100.sbatch` | Whole nodes, up to 4. 48 h max |
| H100, large models | `nairr-gpu-shared` | `templates/gpu-h100-nairr.sbatch` | **Must** write `--gpus=h100:N` |
| CPU only | `shared` | `templates/cpu-shared.sbatch` | `compute` for whole nodes |
| Quick test | `gpu-debug` / `debug` | `templates/interactive.sh` | 30 min cap, schedules fast |
| Cheap and restartable | `preempt` / `gpu-preempt` | - | 0.8x charge, can be killed |

Hardware: V100 nodes are 4x V100 SXM2, 40 cores, 384 GB. H100 nodes are 4x H100,
72 cores, 1 TB, 6.4 TB local NVMe. Full table in `reference/slurm.md`.

## When a job fails

Read `reference/troubleshooting.md`. The short version:

- **`Invalid account`** - `EXPANSE_ACCOUNT` is wrong. Run `scripts/expanse.sh alloc`.
- **Job never starts** - check `scripts/expanse.sh status`; the reason column says
  why. `QOSMaxJobsPerUserLimit` and `Priority` mean wait; `PartitionConfig` means
  the request is impossible for that partition.
- **OOM or very slow on `gpu-shared`** - you forgot `--cpus-per-task` and `--mem`.
- **`Invalid generic resource`** on the AI resource - you wrote `--gpus=1` where
  `--gpus=h100:1` is required.
- **Download hangs on a compute node** - pre-fetch on the login node, then set
  `HF_HUB_OFFLINE=1`.
- **Disk quota exceeded** - something is writing to `/home`. Point caches at
  `$RUN_DIR` as the templates do.

Always report the real outcome, including the SLURM state and the exit code from
`sacct`. A job that ended `FAILED` or `TIMEOUT` is not a success.

## Cost and courtesy

Jobs burn a finite allocation. On exclusive partitions you are charged for what
you **request**, not what you use. Before submitting anything long or wide
(over ~4 hours, or more than one node), say what it will cost and get the human's
agreement. Check the balance with `scripts/expanse.sh alloc`.

Never `scancel` another job you did not submit. Never delete anything under
`/expanse/lustre/projects/` without explicit instruction: it is shared with the
whole project team.

## Reference

- `reference/slurm.md` - partitions, limits, hardware, charging, sbatch directives
- `reference/filesystems.md` - paths, quotas, purge policy, data transfer, Globus
- `reference/software.md` - modules, conda, singularity, PyTorch and HuggingFace setup
- `reference/troubleshooting.md` - failure modes and fixes
- `INSTALL.md` - first-time setup, and installing this skill into other agents
