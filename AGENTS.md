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
scripts/expanse.sh submit job.sbatch
scripts/expanse.sh status <jobid>
scripts/expanse.sh logs <jobid>
scripts/expanse.sh pull outputs ./results
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
   default is 1 core and 1 GB per GPU.
6. **On the H100 partitions, GPUs are `--gpus=h100:N`.** Plain `--gpus=N` is
   rejected.
7. **Report the true outcome.** Quote the SLURM state and exit code from `sacct`,
   and read the log. `TIMEOUT` and `FAILED` are not successes.
8. **Do not `scancel` jobs you did not submit**, and do not delete anything under
   `/expanse/lustre/projects/` - that space is shared with the project team.

## Where things are

- `SKILL.md` - the workflow, start here
- `templates/` - ready sbatch scripts for V100, H100 and CPU jobs
- `reference/slurm.md` - partitions, limits, hardware, charging
- `reference/filesystems.md` - paths, quotas, purge policy, data transfer
- `reference/software.md` - modules, conda, singularity, PyTorch, HuggingFace
- `reference/troubleshooting.md` - failure modes and fixes
- `INSTALL.md` - one-time setup and per-agent installation
