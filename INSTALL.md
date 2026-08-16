# Install and first-time setup

Two separate things: giving *yourself* working access to Expanse, and telling
*your agent* about this skill.

---

## 1. Your Expanse access (once per machine)

You need an SDSC Expanse account with an active allocation, and you must have
enrolled in two-factor authentication at <https://passive.sdsc.edu> using your
Globus/ACCESS identity. Enrollment gives you a QR code to scan into an
authenticator app (Google Authenticator, Duo Mobile, 1Password, whatever you
already use). Changes take up to 15 minutes to take effect.

Then:

```bash
git clone https://github.com/MehulMittal27/sdsc-expanse-skill ~/expanse-agent-skill
cd ~/expanse-agent-skill
./scripts/install.sh          # expanse command on PATH + skill links
./scripts/expanse-setup.sh    # your username and allocation
```

It asks for:

- **Expanse username** - your SDSC login name.
- **SLURM account** - the allocation charged for jobs, something like `abc123`.
  Leave blank if you do not know it yet; after your first login run
  `expanse-client user -r expanse` and add it to
  `~/.config/expanse/config.env`.
- **Project name** - a label for this body of work. It namespaces your remote
  directories, so `protein-folding` and `llm-eval` never collide.

It writes `~/.config/expanse/config.env`, adds a `Host expanse` block to
`~/.ssh/config` with connection sharing enabled, and optionally installs your
SSH public key on the cluster.

Nothing secret is stored. No password, no authenticator seed.

### Every working session

```bash
expanse login     # you type your password and 6-digit code
expanse check     # should print: live
expanse alloc     # confirms the account and shows remaining SUs
```

`login` opens one background SSH connection that stays up for 8 hours by
default. Every later command - yours or your agent's - rides on it with no
prompt. This is the whole trick that lets an agent work unattended on a cluster
that demands a one-time code.

Adjust the duration with `EXPANSE_CONTROL_PERSIST` in the config
(`8h`, `12h`, or `yes` to keep it until you close it).

**Note:** an SSH key alone is not enough. Expanse asks for the authenticator code
even when the key authenticates you. The shared connection is what removes the
repeated prompt.

---

## 2. Install into your agent

`./scripts/install.sh` does this for every supported agent at once. It installs:

- an `expanse` command in `~/.local/bin`, so the driver works from **any**
  directory - your agent runs in your project, not in this repo, so a relative
  `scripts/expanse.sh` would not resolve
- `~/.claude/skills/sdsc-expanse` for Claude Code
- `~/.agents/skills/sdsc-expanse` for harnesses using that convention

Add `--project` to also link it into the current project's `.claude/` and
`.agents/`. Check what is installed with `./scripts/install.sh --check`.

### Claude Code

Covered by `install.sh` above. Claude Code reads the frontmatter in `SKILL.md`
and loads the skill automatically when a task mentions Expanse, SDSC, an
allocation or cluster jobs. Start a new session after installing, then confirm
with `/skills` or just ask it to check your Expanse allocation.

If `~/.local/bin` is not on your `PATH`, add this to your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Codex CLI, Cursor, opencode, Gemini CLI, Jules, Aider

These read `AGENTS.md` from the working directory upward. Either work inside a
clone of this repo, or from your project add a pointer to your own `AGENTS.md`:

```markdown
## Running jobs on SDSC Expanse
Read ~/expanse-agent-skill/AGENTS.md and follow it. All cluster access goes
through the `expanse` command installed by that repo's scripts/install.sh.
```

`.agents/skills/` also works for harnesses that support it:

```bash
mkdir -p .agents/skills && ln -s ~/expanse-agent-skill .agents/skills/sdsc-expanse
```

### Anything else

The skill is plain Markdown and POSIX-ish bash with no dependencies beyond
`ssh`, `rsync` and `bash`. Point any agent at `SKILL.md` and it will work.

---

## 3. Sharing with a collaborator

They do **not** copy your credentials. They clone the repo and run
`./scripts/expanse-setup.sh` with their own Expanse username and their own
allocation. The config lives outside the repo (`~/.config/expanse/config.env`),
so nothing personal is ever committed.

If you both work on the same data, use the shared project space
`/expanse/lustre/projects/<allocation>/` rather than each other's scratch
directories, which are private and purged 90 days after creation.

Per-repo overrides, if you want a checkout pinned to one project, go in
`.expanse.env` at the repo root - it is gitignored.

---

## 4. Verify the install

```bash
./scripts/install.sh --check     # command and skill links
./scripts/selftest.sh            # 72 offline checks, no account needed
expanse config                   # resolved settings and remote paths
expanse check                    # live
expanse alloc                    # allocations
expanse partitions               # partitions you can see
```

Then a real end-to-end smoke test on the debug queue, which costs minutes:

```bash
expanse launch ~/expanse-agent-skill/examples/smoke_train.py \
    --partition gpu-debug --gpus 1 --time 00:10:00
```

You should see a job id, a short wait, a V100 named in the output, and a falling
loss. Repeat with `--gpus 2` to prove the distributed path: two rank lines, and
still exactly one checkpoint written.
