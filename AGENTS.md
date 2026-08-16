# Agent instructions: SDSC Expanse

This repository is a portable skill for running work on the SDSC Expanse
supercomputer. **Read `SKILL.md` before doing anything with Expanse** - it is the
full procedure. This file exists so agents that read `AGENTS.md` (Codex, Cursor,
opencode, Gemini CLI, Jules, Aider and others) get the essentials without
depending on skill discovery.

## Entry point

All cluster interaction goes through `scripts/expanse.sh`. Do not hand-write raw
`ssh` commands to `login.expanse.sdsc.edu`.

```bash
scripts/expanse.sh check          # is the session live?
scripts/expanse.sh alloc          # allocation balance

# Run an ordinary script on the cluster. This generates the SLURM wrapper,
# uploads everything, submits, waits, and prints the log:
scripts/expanse.sh launch ./train.py --partition gpu-shared --gpus 1 \
    --time 04:00:00 --conda myenv --with ./data --args "--epochs 10"

scripts/expanse.sh pull outputs ./results
```

Do not hand-write a SLURM file for a plain script. Use `wrap` to generate one
(`--out job.sbatch` to inspect or edit it first) or `launch` to do everything.
Reach for `templates/` only when you need something the generator does not cover:
multi-node DDP, MPI, job arrays, dependency chains.

```bash
scripts/expanse.sh wrap ./train.py --gpus 1 --out job.sbatch   # generate only
scripts/expanse.sh submit job.sbatch                            # existing sbatch
scripts/expanse.sh status <jobid>
scripts/expanse.sh logs <jobid>
```

## Non-negotiables

1. **You cannot log in by yourself.** Expanse requires a one-time authenticator
   code on every login. If any command exits 78 or `check` prints `dead`, stop and
   ask the human to run `scripts/expanse.sh login`. Do not retry in a loop, do not
   try to obtain the code.
2. **Never run compute on a login node.** Submit a job with `sbatch`.
3. **Never run jobs from `/home`.** Working directory is Lustre scratch. Point
   `HF_HOME`, `TORCH_HOME`, `PIP_CACHE_DIR` and `TMPDIR` away from home.
4. **Ask before spending.** Jobs consume a finite allocation, and exclusive
   partitions charge for what you request, not what you use. Get agreement before
   anything over roughly 4 hours or wider than one node.
5. **On `gpu-shared`, request `--cpus-per-task` and `--mem` explicitly.** The
   default is 1 core and 1 GB per GPU. `wrap`/`launch` handle this for you and
   scale both with the GPU count.
6. **More than one GPU needs a launcher and a distribution-aware script.**
   `--gpus N` adds `torchrun` automatically. That starts one process per GPU, each
   running the script in full, so single-process training code would run N
   redundant copies at N times the cost. Confirm the script uses DDP, HuggingFace
   `Trainer`, `accelerate` or Lightning; if it manages GPUs itself, pass
   `--launcher none`. Over 4 GPUs means `--nodes` on an exclusive partition.
7. **On the H100 partitions, GPUs are `--gpus=h100:N`.** Plain `--gpus=N` is
   rejected.
8. **Report the true outcome.** Quote the SLURM state and exit code from `sacct`,
   and read the log. `TIMEOUT` and `FAILED` are not successes.
9. **Do not `scancel` jobs you did not submit**, and do not delete anything under
   `/expanse/lustre/projects/` - that space is shared with the project team.

## Where things are

- `SKILL.md` - the workflow, start here
- `templates/` - ready sbatch scripts for V100, H100 and CPU jobs
- `reference/slurm.md` - partitions, limits, hardware, charging
- `reference/filesystems.md` - paths, quotas, purge policy, data transfer
- `reference/software.md` - modules, conda, singularity, PyTorch, HuggingFace
- `reference/troubleshooting.md` - failure modes and fixes
- `INSTALL.md` - one-time setup and per-agent installation
