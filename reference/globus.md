# Globus: moving real data

`expanse push` and `expanse pull` go through the login node. That is fine for code
and small inputs, and wrong for datasets: SDSC explicitly asks that login nodes not
be used as a primary data transfer host. Globus moves data server-to-server, keeps
going when your laptop sleeps, resumes after failures, and verifies checksums.

**Rule of thumb: over a few GB, or more than a few thousand files, use Globus.**

## Setup, once

```bash
# 1. the CLI (an agent can do this)
python3 -m venv ~/.local/globus-venv
~/.local/globus-venv/bin/pip install globus-cli
ln -sf ~/.local/globus-venv/bin/globus ~/.local/bin/globus

# 2. log in - HUMAN ONLY, opens a browser
globus login

# 3. find and cache the collection IDs
expanse globus-endpoints

# 4. grant per-collection consent - HUMAN ONLY, opens a browser
#    expanse globus-check prints the exact command, with the right IDs filled in
expanse globus-check
```

Steps 2 and 4 are browser OAuth flows tied to a human identity. An agent cannot do
them and should not try; it should print the command and wait, exactly as
`globus-check` does.

## The collections

| Name | What it reaches | Path prefix |
|---|---|---|
| `SDSC HPC - Expanse Lustre` | scratch and projects on Expanse | `/scratch/<user>/temp_project/...` |
| `SDSC HPC - Projects` | allocation project space | `/projects/<alloc>/<user>/...` |
| your own machine | whatever you share | needs Globus Connect Personal |

Note the paths Globus sees are **not** the paths the cluster sees:
`/expanse/lustre/scratch/...` appears as `/scratch/...`, and
`/expanse/lustre/projects/...` appears as `/projects/...`. The skill handles this;
if you drive `globus` directly, do not paste cluster paths.

Your laptop is only an endpoint if you install
[Globus Connect Personal](https://www.globus.org/globus-connect-personal). Without
it, laptop transfers are impossible and `globus-put`/`globus-get` will say so.
Endpoints are per machine: switching laptops means deleting the old endpoint
(`globus endpoint delete <id>`) and registering the new one.

## Commands

```bash
expanse globus-check                  # installed, logged in, consented?
expanse globus-endpoints              # discover and cache collection IDs
expanse globus-put ./dataset          # this machine -> Expanse scratch
expanse globus-get outputs ./results  # Expanse scratch -> this machine
expanse globus-archive outputs        # scratch -> project space
expanse globus-restore outputs        # project space -> scratch
expanse globus-status [task-id]       # recent transfers, or one task
expanse globus-wait <task-id>         # block until it finishes
```

Transfers are asynchronous. `globus-put` returns a task id immediately and the
data keeps moving after your shell exits; that is the point of Globus, not a bug.
Poll with `globus-status`, or block with `globus-wait` when a job depends on it.

## The one that saves your work

**Scratch is purged 90 days after creation and is not backed up.** Project space
lives until the allocation expires. When a run produces something you care about:

```bash
expanse globus-archive outputs
```

Do it as soon as results exist, not when you remember. A purge does not warn you.

## Transfers not involving your laptop

Any two Globus endpoints can talk directly, and neither has to be a machine you
own - another campus cluster, a lab server, cloud storage. Find the other side
with `globus endpoint search "<name>"` and use `globus transfer` with the two
collection IDs. Consent is per collection, so a new endpoint needs a new consent.
