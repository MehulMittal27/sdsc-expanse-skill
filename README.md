# sdsc-expanse: an agent skill for the SDSC Expanse supercomputer

A portable skill that lets a coding agent run work on
[SDSC Expanse](https://www.sdsc.edu/systems/expanse/user_guide.html) end to end:
connect, stage data, submit SLURM jobs to V100 or H100 GPU nodes, monitor them,
and bring the results back.

It is plain Markdown plus one bash driver, so it works with Claude Code, Codex
CLI, Cursor, opencode, Gemini CLI, Aider, or any agent that can read files and
run shell commands.

## The problem it solves

Expanse requires a one-time authenticator code on **every** login, which normally
makes unattended agent use impossible. This skill uses an SSH shared connection:
a human logs in once, and every subsequent command - for the next 8 hours,
from the human or the agent - reuses that connection with no prompt. Agent
commands run with `BatchMode`, so if the session is not live they fail instantly
with an instruction rather than hanging on a hidden password prompt.

## Quick start

```bash
git clone <this-repo> ~/expanse-agent-skill
cd ~/expanse-agent-skill && chmod +x scripts/*.sh
./scripts/expanse-setup.sh          # your username, allocation, ssh config
./scripts/expanse.sh login          # once per session: password + 6-digit code
./scripts/expanse.sh alloc          # confirm you can see your allocation
```

Then, in your agent:

> Train the model in `./src` on one V100 on Expanse for two hours and bring back
> the checkpoints.

Under the hood that is one command. You hand it an ordinary script; it writes the
SLURM wrapper, uploads it, runs it, and shows you the log:

```bash
./scripts/expanse.sh launch ./train.py \
    --partition gpu-shared --gpus 1 --time 02:00:00 \
    --conda myenv --with ./data --args "--epochs 10"
```

`wrap` does the generation alone (`--out job.sbatch`) if you want to read or edit
the job script before it runs.

Multi-GPU is one flag. Cores and memory scale with the GPU count, and a `torchrun`
launcher is added so every GPU gets a worker:

```bash
./scripts/expanse.sh launch ./train.py --gpus 4                       # 4 V100s, one node
./scripts/expanse.sh launch ./train.py --partition gpu --nodes 2 --gpus 4   # 8 across two nodes
```

Your training script has to be distribution-aware for that (DDP, HuggingFace
`Trainer`, `accelerate` or Lightning), and the generator refuses the job if it
cannot find any of them in the script rather than letting you pay N times over
for N redundant copies of the same run. `reference/distributed.md` covers the
conversion, and when a bigger batch on one GPU is the better answer.

## What is in here

```
SKILL.md                     the procedure (Claude Code skill frontmatter)
AGENTS.md                    same essentials for AGENTS.md-reading agents
INSTALL.md                   setup, per-agent installation, sharing with collaborators
scripts/expanse-setup.sh     one-time config: username, account, ssh sharing, keys
scripts/expanse.sh           the driver: login, push, submit, status, wait, logs, pull
templates/
  gpu-shared-v100.sbatch     1-3 V100 GPUs on one node (the usual choice)
  gpu-full-node-v100.sbatch  whole 4-GPU nodes, multi-node DDP
  gpu-h100-nairr.sbatch      Expanse AI Resource H100 nodes
  cpu-shared.sbatch          CPU-only work
  interactive.sh             srun recipes for interactive sessions
examples/
  smoke_train.py             tiny distribution-aware trainer; proves the pipeline end to end
  smoke_single.py            ordinary single-process trainer; demonstrates the multi-GPU guard
scripts/selftest.sh          72 offline checks: generation, scaling, launchers, every guard
reference/
  slurm.md                   partitions, limits, hardware, charging, directives
  filesystems.md             paths, quotas, purge policy, data transfer, Globus
  software.md                modules, conda, singularity, PyTorch, HuggingFace
  distributed.md             single-GPU to multi-GPU conversion, and when not to
  troubleshooting.md         failure modes and fixes
```

## Driver commands

```
expanse.sh login                       open the shared session (human, once per session)
expanse.sh check                       is it live? (agents call this first)
expanse.sh config                      resolved settings and remote paths
expanse.sh alloc                       allocations and remaining service units
expanse.sh partitions                  what this account can see
expanse.sh wrap <script> [opts]        turn a plain script into a SLURM job script
expanse.sh launch <script> [opts]      wrap + upload + submit + wait + logs
expanse.sh push <local> [subpath]      stage data into Lustre scratch
expanse.sh push-code <local> [subpath] stage code into home
expanse.sh pull <subpath> <local>      bring results back
expanse.sh submit <job.sbatch>         submit an existing sbatch, prints the job id
expanse.sh status [jobid]              queue state, or the final state via sacct
expanse.sh wait <jobid> [timeout]      block until it leaves the queue
expanse.sh logs <jobid> [-f]           job stdout
expanse.sh cancel <jobid>              scancel
expanse.sh run <job.sbatch>            submit + wait + logs
expanse.sh exec <cmd...>               run a command on the login node
```

Templates carry `{{ACCOUNT}}` and `{{RUN_DIR}}` placeholders that `submit` fills
in from your config, so nobody's username or allocation is ever hard-coded.

## Verifying it works

```bash
./scripts/selftest.sh          # no cluster, no account, no network needed
```

72 checks covering job generation, resource scaling, launcher selection, every
safety guard, and that each generated job script is valid bash. Then, with an
account, the real end-to-end proof on the debug queue:

```bash
./scripts/expanse.sh launch examples/smoke_train.py \
    --partition gpu-debug --gpus 1 --time 00:10:00
./scripts/expanse.sh launch examples/smoke_train.py \
    --partition gpu-debug --gpus 2 --time 00:10:00
```

The first should name a V100 and show a falling loss; the second should print two
rank lines and still write exactly one checkpoint.

## Safety properties

- No credentials in the repo. Config lives in `~/.config/expanse/config.env`;
  no password and no authenticator seed are ever stored.
- Agent commands are non-interactive by construction and cannot silently hang
  waiting for a password.
- `submit` refuses a job script with unfilled placeholders or a missing
  `--account`, so you cannot accidentally charge the wrong allocation.
- Templates keep the working directory and all caches off `/home`, which the
  vendor guide explicitly forbids running jobs from.
- The skill instructs agents to get human agreement before long or wide jobs,
  because allocations are finite and exclusive partitions charge for what you
  request rather than what you use.

## Collaborators

Each person runs `./scripts/expanse-setup.sh` with their own Expanse username and
allocation. Nothing personal is committed. Share data through
`/expanse/lustre/projects/<allocation>/`, not through each other's scratch
directories.
