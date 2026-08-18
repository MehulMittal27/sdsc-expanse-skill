---
name: sdsc-expanse
description: Run compute jobs end to end on the SDSC Expanse supercomputer (V100 and H100 GPU nodes, CPU nodes, SLURM). Use whenever the task involves Expanse, SDSC, login.expanse.sdsc.edu, an ACCESS/NAIRR allocation, submitting or monitoring sbatch/srun/squeue jobs on a cluster, training or running a model on remote GPUs, or moving data to and from HPC scratch storage.
---

# SDSC Expanse

Drive the SDSC Expanse cluster: connect, move data, submit SLURM jobs, watch them,
retrieve results. Everything goes through one command, `expanse`, which never
blocks on an interactive prompt.

**Invocation.** Use the `expanse` command. It is installed on PATH by
`scripts/install.sh`, so it works from whatever directory you are in - you run in
the user's project, not in this skill's directory, so relative paths like
`scripts/expanse.sh` will not resolve. If `expanse` is not found, fall back to the
absolute path of this skill's `scripts/expanse.sh` and tell the user to run
`scripts/install.sh`.

Authoritative vendor documentation: <https://www.sdsc.edu/systems/expanse/user_guide.html>

## Before anything else

Run this. It is cheap and it tells you whether you can work at all:

```bash
expanse check && expanse config
```

- `live` means the shared SSH session is up. Proceed.
- `dead`, or exit code 78 from any command, means **stop and ask the human**.
  Expanse demands a one-time authenticator code on every login, so you cannot
  open the connection yourself. Tell them, verbatim:

  > Please run `expanse login` in your terminal and enter your
  > password and 6-digit code. I will continue once the session is up.

  Do not try `ssh` directly, do not try to script the code, do not retry in a
  loop. Wait for the human.
- If `config` shows `EXPANSE_USER=<unset>` or `EXPANSE_ACCOUNT=<unset>`, this
  person has never set the skill up. Do not guess at values or run the setup
  yourself - point them at the guided check, which reports what is done, what is
  missing, and the single next step:

  > Run `<skill>/scripts/onboard.sh`. It walks through setup and tells you what
  > you need from whoever runs your allocation.

  Run it again after they act; it is safe to repeat and changes nothing without
  asking.

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

## Standard workflow: an ordinary script, run on the cluster

This is the common case. The user hands you `train.py` (or `prep.sh`, or an R
script) and wants it run on Expanse. You do **not** hand-write a SLURM file:

```bash
expanse check                     # session live?
expanse alloc                     # remaining SUs

expanse launch ./train.py \
  --partition gpu-shared --gpus 1 --time 04:00:00 \
  --conda myenv --with ./data --with ./src --args "--epochs 10"

expanse pull outputs ./results    # bring results back
```

`launch` does the whole thing: generates a correct sbatch wrapper around your
script, uploads the script and everything named with `--with` into the Lustre run
directory, and submits it.

**It does not block on long jobs.** Jobs of 30 minutes or less are waited on and
their log printed. Anything longer returns the SLURM job id immediately, because
the job runs on the cluster whether or not anyone is watching. Report that id to
the user along with how to check on it:

```
expanse status <jobid>     queued, running, or the final state
expanse logs <jobid>       output so far
expanse logs <jobid> -f    follow it live
expanse cancel <jobid>     stop it
```

`--wait` and `--no-wait` override that choice. Never sit blocking on a multi-hour
job: submit it, give the user the id, and move on.

To see or tweak the generated job before running it:

```bash
expanse wrap ./train.py --partition gpu-shared --gpus 1 --out job.sbatch
# read it, edit anything, then:
expanse submit ./job.sbatch
```

`wrap` picks the interpreter from the file extension (`.py` to `python`, `.sh` to
`bash`, `.R` to `Rscript`, `.jl` to `julia`), loads the right base module, points
every cache away from `/home`, `cd`s into the run directory, and applies sensible
per-partition defaults for cores, memory and walltime. It also fixes the two
mistakes that silently kill jobs: it adds the `h100:` prefix on the AI-resource
partitions, and it never leaves you on the `gpu-shared` default of 1 core and 1 GB.

Options: `--name --partition --gpus --cpus --mem --time --nodes --ntasks-per-node
--conda --sif --module --with --interpreter --args --out`. Run
`expanse --help` for the full list.

### Multiple GPUs

Raise `--gpus`. Cores and memory scale with it, and a `torchrun` launcher is added
automatically so every GPU actually gets a worker:

```bash
expanse launch ./train.py --gpus 2 --time 06:00:00 --conda embed
# -> 2 GPUs, 20 cores, 184G, torchrun --nproc_per_node=2
```

**`gpu-shared` allows at most 3 GPUs** (QOS `gres/gpu=3, cpu=37, mem=353000M`),
whatever the vendor guide says. For 4 on one node use the exclusive partition:

```bash
expanse launch ./train.py --partition gpu --gpus 4 --time 06:00:00 --conda embed
# -> whole node: 4 GPUs, 40 cores, 368G, torchrun --nproc_per_node=4
```

Across nodes, for more than 4 GPUs:

```bash
expanse launch ./train.py --partition gpu --nodes 2 --gpus 4
# -> 8 GPUs; srun + torchrun with a c10d rendezvous on the first node
```

Expect sub-linear scaling. Measured on V100s: 2 GPUs 1.6x, 4 GPUs 2.1x. Gradient
synchronisation costs time, so measure before buying more GPUs.

**The script must be distribution-aware.** `torchrun` starts one process per GPU,
each of which runs your script top to bottom. Plain single-process training code
will run N independent copies of itself on N GPUs: N times the cost, no speedup,
and N sets of clobbered checkpoints. It is safe as-is if you use PyTorch DDP,
HuggingFace `Trainer`, `accelerate`, or Lightning, since all of them read
`RANK`/`WORLD_SIZE`/`LOCAL_RANK` from the environment that `torchrun` sets.

`wrap` and `launch` scan the script and **refuse** to generate a multi-process job
when they find no sign of any of those. Do not reach for `--force` to get past it:
either drop to `--gpus 1`, or convert the script first using
`reference/distributed.md`. This skill does not rewrite training code
automatically - distributed training changes what the model learns, not just how
fast it runs.

Controls:

- `--launcher torchrun` (auto-selected for a python script with more than one GPU)
- `--launcher accelerate` if you use `accelerate launch`, single node only
- `--launcher srun` for one task per GPU without torchrun
- `--launcher none` if your script handles its own GPUs, for example `DataParallel`
- `--master-port N` if 29500 collides on a shared node

Guards that fire before you queue: more than 3 GPUs on `gpu-shared` (with the
exclusive partition named as the fix), more than 4 GPUs on one node, multi-node on
a single-node partition, over the 30-minute debug cap, and multi-node with
`accelerate`.

### When you need full control

For anything the generator does not cover - multi-node DDP, job arrays, MPI,
dependency chains - start from a template instead:

```bash
cp templates/gpu-full-node-v100.sbatch ./train.sbatch
#   ... edit ...
JOB=$(expanse submit ./train.sbatch)
expanse status "$JOB"
expanse wait "$JOB"
expanse logs "$JOB"
```

`{{ACCOUNT}}` and `{{RUN_DIR}}` are filled in automatically at submit time from
the configured account and project. Leave them as placeholders. `submit` refuses
a script with any placeholder left unfilled or with no `--account` line.

Other staging commands, when you need them separately: `push` (into Lustre scratch),
`push-code` (into home), `pull` (back to your machine).

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

- **`Invalid account`** - `EXPANSE_ACCOUNT` is wrong. Run `expanse alloc`.
- **Job never starts** - check `expanse status`; the reason column says
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
agreement. Check the balance with `expanse alloc`.

Never `scancel` another job you did not submit. Never delete anything under
`/expanse/lustre/projects/` without explicit instruction: it is shared with the
whole project team.

## Moving real data: Globus

`push`/`pull` go through the login node - fine for code, wrong for datasets. Over
a few GB, or more than a few thousand files, use Globus: it transfers
server-to-server, survives your laptop sleeping, and resumes after failures.

```bash
expanse globus-check                  # installed, logged in, consented?
expanse globus-put ./dataset          # this machine -> Expanse scratch
expanse globus-get outputs ./results  # back again
expanse globus-archive outputs        # scratch -> project space
expanse globus-status                 # recent transfers
```

`globus login` and `globus session consent` are browser flows tied to a human
identity. **You cannot do them.** `globus-check` prints the exact command to hand
over; print it and wait, exactly as with `expanse login`.

**Archive anything worth keeping.** Scratch is purged 90 days after creation with
no warning and no backup; project space lasts until the allocation expires. Run
`expanse globus-archive <subpath>` as soon as results exist. Full detail in
`reference/globus.md`.

## Environment on the cluster: what actually works

Verified August 2026: **SDSC's provided PyTorch container is broken on the GPU
nodes.** The image is from April 2024 and hits `Failed to initialize NVML:
Driver/library version mismatch` against the current driver, after which
`torch.cuda.is_available()` is False and the job silently trains on CPU while
reporting success.

Use a conda environment on Lustre instead - `reference/software.md` has the exact
recipe, verified working with torch 2.5.1+cu121 on V100s. Always print
`torch.cuda.is_available()` at the start of a run so a CPU fallback is loud.

## Proving it works

`scripts/selftest.sh` checks generation, scaling, launchers and every guard with
no cluster involved. `examples/smoke_train.py` is a tiny distribution-aware
trainer for a real end-to-end run; `examples/smoke_single.py` is the
single-process counterpart that the multi-GPU guard rejects. Before any long job,
prove the path cheaply:

```bash
expanse launch examples/smoke_train.py \
    --partition gpu-debug --gpus 2 --time 00:10:00
```

## Reference

- `reference/slurm.md` - partitions, limits, hardware, charging, sbatch directives
- `reference/filesystems.md` - paths, quotas, purge policy, data transfer, Globus
- `reference/software.md` - modules, conda, singularity, PyTorch and HuggingFace setup
- `reference/globus.md` - moving datasets, archiving results off purge-prone scratch
- `reference/distributed.md` - converting single-GPU training to multi-GPU, and when not to
- `reference/troubleshooting.md` - failure modes and fixes
- `examples/` - smoke trainers, single-process and distributed
- `INSTALL.md` - first-time setup, and installing this skill into other agents
