#!/usr/bin/env bash
# expanse.sh - agent-safe driver for SDSC Expanse.
#
# Every remote call is non-interactive (BatchMode). If the shared SSH session is
# not live, commands refuse immediately with an instruction for the human
# instead of hanging on a password/TOTP prompt.
#
# Usage: scripts/expanse.sh <command> [args]
#   login                          open the shared SSH session (HUMAN runs this; prompts for password + TOTP)
#   check                          report whether the shared session is live
#   logout                         close the shared SSH session
#   exec <cmd...>                  run a command on the login node
#   alloc                          show allocations and remaining SUs
#   partitions                     show partitions this account can use
#   push <local> [remote-subpath]  rsync into the remote run directory (Lustre scratch)
#   push-code <local> [subpath]    rsync into the remote code directory (home)
#   pull <remote-subpath> <local>  rsync back from the remote run directory
#   wrap <script> [opts]           turn a plain script (.py/.sh/.R/...) into an sbatch job
#   launch <script> [opts]         wrap + upload + submit + wait + logs, end to end
#   submit <script.sbatch> [--wait] submit an existing sbatch file; prints JOBID
#   status [jobid]                 squeue for the user, or one job (falls back to sacct)
#   wait <jobid> [timeout-sec]     block until the job leaves the queue
#   logs <jobid> [-f]              print (or follow) the job's stdout file
#   cancel <jobid>                 scancel
#   run <script.sbatch>            submit + wait + logs for an existing sbatch file
#   config                         print the resolved configuration
#
# Globus - for data too large to push through the login node:
#   globus-check                   installed, logged in and consented?
#   globus-endpoints               discover and cache the collection IDs
#   globus-put <local> [subpath]   this machine -> Expanse scratch
#   globus-get <subpath> <local>   Expanse scratch -> this machine
#   globus-archive <subpath>       scratch -> project space (survives the 90-day purge)
#   globus-restore <subpath>       project space -> scratch
#   globus-status [task-id]        recent transfers, or one task
#   globus-wait <task-id> [secs]   block until a transfer finishes
#
# wrap/launch options:
#   --name NAME              job name (default: the script's basename)
#   --partition NAME         gpu-shared (default) | gpu | nairr-gpu-shared | nairr-gpu
#                            | shared | compute | large-shared | gpu-debug | debug
#                            | preempt | gpu-preempt
#   --gpus N | h100:N        GPU count; the h100: prefix is added automatically on nairr-*
#   --cpus N  --mem 92G  --time HH:MM:SS  --nodes N  --ntasks-per-node N
#   --conda ENV              conda environment to activate
#   --conda-sh PATH          where that conda's profile.d/conda.sh lives; defaults to
#                            $EXPANSE_CONDA_SH, else <run-dir>/miniconda3/... A conda
#                            install bakes in its own path, so keep it OUTSIDE any
#                            project directory and set EXPANSE_CONDA_SH once
#   --sif IMAGE.sif          run inside a singularity image with --nv
#   --module NAME            extra module to load (repeatable)
#   --with PATH              extra local file/dir to upload alongside the script (repeatable)
#   --launcher NAME          auto (default) | torchrun | accelerate | srun | none
#                            auto uses torchrun when a python script gets >1 GPU
#   --master-port N          rendezvous port for multi-node runs (default 29500)
#   --force                  skip the single-process safety check (rarely correct)
#   --no-wait / --wait       return the job id immediately, or block until it ends.
#                            Default: block for jobs of 30 minutes or less, detach
#                            for longer ones - SLURM runs them either way
#   --interpreter CMD        override the interpreter (default inferred from extension)
#   --args "..."             arguments passed to the script
#   --out FILE               wrap only: write the sbatch here instead of stdout
set -euo pipefail

# Resolve through symlinks: this script is normally reached via a PATH shim
# (~/.local/bin/expanse), and the real repo is wherever the link points.
# readlink -f is not portable to macOS, so walk the chain by hand.
_resolve_dir() {
  local src="$1" dir
  while [ -L "$src" ]; do
    dir=$(cd -P -- "$(dirname -- "$src")" && pwd)
    src=$(readlink -- "$src")
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  (cd -P -- "$(dirname -- "$src")" && pwd)
}
SCRIPT_DIR=$(_resolve_dir "${BASH_SOURCE[0]}")
REPO_DIR=$(dirname -- "$SCRIPT_DIR")

# --- configuration -----------------------------------------------------------
# Precedence: environment > repo-local .expanse.env > ~/.config/expanse/config.env
CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/expanse/config.env"
CONFIG_REPO="$REPO_DIR/.expanse.env"
CONFIG_GLOBUS="${XDG_CONFIG_HOME:-$HOME/.config}/expanse/globus.env"

load_config() {
  # An explicit environment variable must win over the stored config, so
  # remember what the caller set before sourcing anything and put it back after.
  local _env_user="${EXPANSE_USER:-}" _env_acct="${EXPANSE_ACCOUNT:-}"
  local _env_proj="${EXPANSE_PROJECT:-}" _env_host="${EXPANSE_HOST:-}"
  local f
  for f in "$CONFIG_USER" "$CONFIG_REPO" "$CONFIG_GLOBUS"; do
    if [ -f "$f" ]; then
      # shellcheck disable=SC1090
      set -a; . "$f"; set +a
    fi
  done
  [ -n "$_env_user" ] && EXPANSE_USER="$_env_user"
  [ -n "$_env_acct" ] && EXPANSE_ACCOUNT="$_env_acct"
  [ -n "$_env_proj" ] && EXPANSE_PROJECT="$_env_proj"
  [ -n "$_env_host" ] && EXPANSE_HOST="$_env_host"
  EXPANSE_HOST="${EXPANSE_HOST:-login.expanse.sdsc.edu}"
  EXPANSE_ALIAS="${EXPANSE_ALIAS:-expanse}"
  EXPANSE_PROJECT="${EXPANSE_PROJECT:-default}"
  EXPANSE_CONTROL_PATH="${EXPANSE_CONTROL_PATH:-$HOME/.ssh/cm/%r@%h:%p}"
}
load_config

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

require_user() {
  [ -n "${EXPANSE_USER:-}" ] || die "EXPANSE_USER is not set. Run: $SCRIPT_DIR/expanse-setup.sh"
}
require_account() {
  [ -n "${EXPANSE_ACCOUNT:-}" ] || die "EXPANSE_ACCOUNT is not set (your SLURM project/allocation). Run: $SCRIPT_DIR/expanse-setup.sh"
}

# Remote paths. Home holds code only; jobs must run from Lustre scratch.
remote_code_dir()  { printf '/home/%s/expanse-agent/%s' "$EXPANSE_USER" "$EXPANSE_PROJECT"; }
remote_run_dir()   { printf '/expanse/lustre/scratch/%s/temp_project/%s' "$EXPANSE_USER" "$EXPANSE_PROJECT"; }

JOBS_FILE="$REPO_DIR/.expanse-jobs.tsv"

# --- ssh plumbing ------------------------------------------------------------
ssh_base_opts() {
  printf '%s\n' \
    -o "ControlPath=$EXPANSE_CONTROL_PATH" \
    -o ControlMaster=no \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new
}

master_live() {
  require_user
  ssh -o "ControlPath=$EXPANSE_CONTROL_PATH" -O check "$EXPANSE_USER@$EXPANSE_HOST" >/dev/null 2>&1
}

require_master() {
  if master_live; then return 0; fi
  cat >&2 <<EOF
error: no live Expanse session.

Expanse requires a one-time-password (TOTP) code on every login, so an agent
cannot open the connection on its own. A human must run this once:

    $SCRIPT_DIR/expanse.sh login

That opens a shared background session (valid for ${EXPANSE_CONTROL_PERSIST:-8h}).
Every later command reuses it with no prompt.
EOF
  exit 78
}

rsh_cmd() {
  # rsync -e string, quoted for the shell rsync spawns
  printf 'ssh -o ControlPath=%s -o ControlMaster=no -o BatchMode=yes -o StrictHostKeyChecking=accept-new' \
    "$EXPANSE_CONTROL_PATH"
}

# Run a command on the login node. Never interactive.
r() {
  require_master
  local opts=()
  while IFS= read -r line; do opts+=("$line"); done < <(ssh_base_opts)
  ssh "${opts[@]}" "$EXPANSE_USER@$EXPANSE_HOST" "$@"
}

# --- commands ----------------------------------------------------------------
cmd_login() {
  require_user
  mkdir -p "$HOME/.ssh/cm"; chmod 700 "$HOME/.ssh/cm"
  if master_live; then note "Session already live."; return 0; fi
  note "Opening shared Expanse session as $EXPANSE_USER@$EXPANSE_HOST."
  note "Enter your password, then your 6-digit authenticator code when prompted."
  ssh -o "ControlPath=$EXPANSE_CONTROL_PATH" \
      -o ControlMaster=yes \
      -o "ControlPersist=${EXPANSE_CONTROL_PERSIST:-8h}" \
      -o ServerAliveInterval=60 \
      -o StrictHostKeyChecking=accept-new \
      -f -N "$EXPANSE_USER@$EXPANSE_HOST"
  if master_live; then
    note "Session established. Agents can now run jobs without prompting."
  else
    die "Login did not establish a shared session."
  fi
}

cmd_check() {
  if master_live; then
    printf 'live\t%s@%s\n' "$EXPANSE_USER" "$EXPANSE_HOST"
  else
    printf 'dead\t%s@%s\n' "${EXPANSE_USER:-unset}" "$EXPANSE_HOST"
    return 1
  fi
}

cmd_logout() {
  require_user
  ssh -o "ControlPath=$EXPANSE_CONTROL_PATH" -O exit "$EXPANSE_USER@$EXPANSE_HOST" 2>/dev/null || true
  note "Session closed."
}

cmd_config() {
  printf 'EXPANSE_USER=%s\n'    "${EXPANSE_USER:-<unset>}"
  printf 'EXPANSE_ACCOUNT=%s\n' "${EXPANSE_ACCOUNT:-<unset>}"
  printf 'EXPANSE_HOST=%s\n'    "$EXPANSE_HOST"
  printf 'EXPANSE_PROJECT=%s\n' "$EXPANSE_PROJECT"
  if [ -n "${EXPANSE_USER:-}" ]; then
    printf 'remote_code_dir=%s\n' "$(remote_code_dir)"
    printf 'remote_run_dir=%s\n'  "$(remote_run_dir)"
  else
    printf 'remote_code_dir=<unset until EXPANSE_USER is set>\n'
    printf 'remote_run_dir=<unset until EXPANSE_USER is set>\n'
  fi
  printf 'config_files=%s %s\n' "$CONFIG_USER" "$CONFIG_REPO"
  if [ -z "${EXPANSE_USER:-}" ] || [ -z "${EXPANSE_ACCOUNT:-}" ]; then
    note "incomplete configuration - run $SCRIPT_DIR/expanse-setup.sh"
  fi
}

cmd_alloc() {
  # expanse-client is provided by the default-loaded sdsc module.
  r "expanse-client user -r expanse"
}

cmd_partitions() {
  r "sinfo -o '%20P %5a %10l %6D %10T %N' | head -40"
}

cmd_push() {
  local src="${1:?usage: push <local-path> [remote-subpath]}"; shift || true
  local sub="${1:-}"
  local dst; dst="$(remote_run_dir)${sub:+/$sub}"
  require_master
  r "mkdir -p '$dst'"
  rsync -az -v -e "$(rsh_cmd)" "$src" "$EXPANSE_USER@$EXPANSE_HOST:$dst/"
  printf '%s\n' "$dst"
}

cmd_push_code() {
  local src="${1:?usage: push-code <local-path> [remote-subpath]}"; shift || true
  local sub="${1:-}"
  local dst; dst="$(remote_code_dir)${sub:+/$sub}"
  require_master
  r "mkdir -p '$dst'"
  rsync -az -v -e "$(rsh_cmd)" "$src" "$EXPANSE_USER@$EXPANSE_HOST:$dst/"
  printf '%s\n' "$dst"
}

cmd_pull() {
  local sub="${1:?usage: pull <remote-subpath> <local-dest>}"
  local dest="${2:?usage: pull <remote-subpath> <local-dest>}"
  require_master
  mkdir -p "$dest"
  rsync -az -v -e "$(rsh_cmd)" \
    "$EXPANSE_USER@$EXPANSE_HOST:$(remote_run_dir)/$sub" "$dest/"
}

# Substitute {{ACCOUNT}} and {{RUN_DIR}} placeholders, then submit.
cmd_submit() {
  local script="${1:?usage: submit <script.sbatch> [--wait]}"; shift || true
  local do_wait=0
  [ "${1:-}" = "--wait" ] && do_wait=1
  [ -f "$script" ] || die "no such job script: $script"
  require_account
  require_user

  local base rundir remote_script tmp
  base=$(basename -- "$script")
  rundir="$(remote_run_dir)"
  remote_script="$rundir/$base"
  tmp=$(mktemp)
  sed -e "s|{{ACCOUNT}}|$EXPANSE_ACCOUNT|g" \
      -e "s|{{RUN_DIR}}|$rundir|g" \
      -e "s|{{USER}}|$EXPANSE_USER|g" \
      -e "s|{{PROJECT}}|$EXPANSE_PROJECT|g" "$script" > "$tmp"

  if grep -q '{{[A-Z_]*}}' "$tmp"; then
    local left; left=$(grep -o '{{[A-Z_]*}}' "$tmp" | sort -u | tr '\n' ' ')
    rm -f "$tmp"
    die "job script still has unfilled placeholders: $left"
  fi
  if ! grep -q '^#SBATCH --account=' "$tmp"; then
    rm -f "$tmp"; die "job script has no #SBATCH --account= line"
  fi

  # Script is valid; now the connection has to be live.
  require_master
  r "mkdir -p '$rundir/logs'"
  rsync -az -e "$(rsh_cmd)" "$tmp" "$EXPANSE_USER@$EXPANSE_HOST:$remote_script"
  rm -f "$tmp"

  local out jobid
  out=$(r "cd '$rundir' && sbatch --parsable '$remote_script'") || die "sbatch failed"
  jobid=${out%%;*}
  [ -n "$jobid" ] || die "could not parse job id from: $out"
  printf '%s\t%s\t%s\n' "$jobid" "$base" "$rundir" >> "$JOBS_FILE"
  printf '%s\n' "$jobid"
  [ "$do_wait" = 1 ] && cmd_wait "$jobid"
  return 0
}

cmd_status() {
  local jobid="${1:-}"
  if [ -z "$jobid" ]; then
    require_user
    r "squeue -u '$EXPANSE_USER' -o '%.10i %.14j %.12P %.9T %.10M %.10l %.6D %R'"
    return 0
  fi
  local s
  s=$(r "squeue -h -j '$jobid' -o '%T'" 2>/dev/null || true)
  if [ -n "$s" ]; then printf '%s\n' "$s"; return 0; fi
  # Left the queue: ask the accounting database for the final state.
  r "sacct -j '$jobid' --format=JobID,JobName%24,State,ExitCode,Elapsed,ReqTRES%40 -X -P"
}

cmd_wait() {
  local jobid="${1:?usage: wait <jobid> [timeout-sec]}"
  local timeout="${2:-86400}"
  local waited=0 interval=10 state
  while :; do
    state=$(r "squeue -h -j '$jobid' -o '%T'" 2>/dev/null || true)
    if [ -z "$state" ]; then break; fi
    printf 'job %s: %s (%ss)\n' "$jobid" "$state" "$waited" >&2
    [ "$waited" -ge "$timeout" ] && die "timed out waiting for job $jobid after ${timeout}s (still $state)"
    sleep "$interval"
    waited=$((waited + interval))
    [ "$interval" -lt 60 ] && interval=$((interval + 10))
  done
  r "sacct -j '$jobid' --format=JobID,State,ExitCode,Elapsed -X -P"
}

cmd_logs() {
  local jobid="${1:?usage: logs <jobid> [-f]}"
  local follow="${2:-}"
  local rundir; rundir="$(remote_run_dir)"
  local f
  f=$(r "ls -1t '$rundir'/logs/*${jobid}* 2>/dev/null | head -1" || true)
  [ -n "$f" ] || die "no log file for job $jobid under $rundir/logs (check the #SBATCH --output path)"
  if [ "$follow" = "-f" ]; then
    r "tail -f '$f'"
  else
    r "cat '$f'"
  fi
}

cmd_cancel() {
  local jobid="${1:?usage: cancel <jobid>}"
  r "scancel '$jobid'" && note "cancelled $jobid"
}

cmd_run() {
  local script="${1:?usage: run <script.sbatch>}"
  local jobid; jobid=$(cmd_submit "$script")
  printf 'submitted %s\n' "$jobid" >&2
  cmd_wait "$jobid" || true
  cmd_logs "$jobid"
}

# --- Globus: for data too large for the login node ----------------------------
# SDSC asks that login nodes not be used as a primary transfer host. Globus moves
# data server-to-server: it survives your laptop sleeping, resumes after failures,
# and verifies checksums. Use it for anything above a few GB.
globus_cli() {
  command -v globus >/dev/null 2>&1 || die "the globus CLI is not installed. Install it with:
    python3 -m venv ~/.local/globus-venv && ~/.local/globus-venv/bin/pip install globus-cli
    ln -sf ~/.local/globus-venv/bin/globus ~/.local/bin/globus"
  globus "$@"
}

globus_require_login() {
  globus_cli whoami >/dev/null 2>&1 && return 0
  die "not logged in to Globus. A human must run: globus login"
}

# Consent is per collection and needs a browser, so print the exact command.
globus_consent_hint() {
  local ids="" id
  for id in "$@"; do
    [ -n "$id" ] && ids="$ids *https://auth.globus.org/scopes/$id/data_access"
  done
  printf 'A human must grant Globus consent for these collections:\n\n' >&2
  printf "    globus session consent 'urn:globus:auth:scope:transfer.api.globus.org:all[%s]'\n\n" "${ids# }" >&2
}

globus_find_id() { # globus_find_id <display-name>
  globus_cli endpoint search "$1" --filter-scope all --limit 5 --format json 2>/dev/null \
    | python3 -c 'import json,sys
target = sys.argv[1]
for e in json.load(sys.stdin).get("DATA", []):
    if e.get("display_name") == target:
        print(e["id"]); break' "$1"
}

cmd_globus_endpoints() {
  globus_require_login
  require_user
  local lustre projects mine
  lustre=$(globus_find_id "SDSC HPC - Expanse Lustre")
  projects=$(globus_find_id "SDSC HPC - Projects")
  mine=$(globus_cli endpoint search --filter-scope my-endpoints --limit 5 --format json 2>/dev/null \
    | python3 -c 'import json,sys
d = json.load(sys.stdin).get("DATA", [])
print(d[0]["id"] if d else "")')

  mkdir -p "$(dirname -- "$CONFIG_GLOBUS")"
  {
    printf '# Globus endpoints - discovered by expanse.sh globus-endpoints\n'
    printf 'GLOBUS_EXPANSE_LUSTRE=%s\n' "$lustre"
    printf 'GLOBUS_SDSC_PROJECTS=%s\n' "$projects"
    [ -n "$mine" ] && printf 'GLOBUS_LAPTOP=%s\n' "$mine"
    printf 'GLOBUS_SCRATCH_PREFIX=/scratch/%s/temp_project\n' "$EXPANSE_USER"
    printf 'GLOBUS_PROJECTS_PREFIX=/projects/%s/%s\n' "${EXPANSE_ACCOUNT:-UNKNOWN}" "$EXPANSE_USER"
  } > "$CONFIG_GLOBUS"
  chmod 600 "$CONFIG_GLOBUS"
  printf '  %-26s %s\n' "Expanse Lustre" "${lustre:-NOT FOUND}"
  printf '  %-26s %s\n' "SDSC Projects" "${projects:-NOT FOUND}"
  printf '  %-26s %s\n' "this machine" "${mine:-none - install Globus Connect Personal}"
  note "wrote $CONFIG_GLOBUS"
}

cmd_globus_check() {
  command -v globus >/dev/null 2>&1 || { printf 'globus CLI:   NOT INSTALLED\n'; return 1; }
  printf 'globus CLI:   installed\n'
  local who
  if who=$(globus_cli whoami 2>/dev/null); then
    printf 'logged in:    %s\n' "$who"
  else
    printf 'logged in:    NO - a human must run: globus login\n'; return 1
  fi
  printf 'lustre:       %s\n' "${GLOBUS_EXPANSE_LUSTRE:-<unset, run: expanse globus-endpoints>}"
  printf 'projects:     %s\n' "${GLOBUS_SDSC_PROJECTS:-<unset>}"
  printf 'this machine: %s\n' "${GLOBUS_LAPTOP:-<none - install Globus Connect Personal>}"
  if [ -n "${GLOBUS_EXPANSE_LUSTRE:-}" ]; then
    if globus_cli ls "$GLOBUS_EXPANSE_LUSTRE:${GLOBUS_SCRATCH_PREFIX:-/}/" >/dev/null 2>&1; then
      printf 'consent:      granted\n'
    else
      printf 'consent:      MISSING\n'
      globus_consent_hint "$GLOBUS_EXPANSE_LUSTRE" "${GLOBUS_SDSC_PROJECTS:-}" "${GLOBUS_LAPTOP:-}"
      return 1
    fi
  fi
}

globus_need() {
  [ -n "${GLOBUS_EXPANSE_LUSTRE:-}" ] || die "Globus endpoints unknown. Run: expanse globus-endpoints"
}
globus_need_laptop() {
  [ -n "${GLOBUS_LAPTOP:-}" ] || die "this machine is not a Globus endpoint. Install Globus Connect Personal from https://www.globus.org/globus-connect-personal, then run: expanse globus-endpoints"
}

globus_submit() { # globus_submit <label> <src> <dst>
  local label="$1" src="$2" dst="$3" out task
  globus_require_login
  out=$(globus_cli transfer --recursive --sync-level checksum --label "$label" \
        --notify off "$src" "$dst" --format json 2>&1) \
    || { printf '%s\n' "$out" >&2; die "transfer failed to start"; }
  task=$(printf '%s' "$out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("task_id",""))
except Exception: print("")')
  [ -n "$task" ] || { printf '%s\n' "$out" >&2; die "could not read the task id"; }
  printf '%s\n' "$task"
  note "transfer $task started"
  note "watch it with: expanse globus-status $task"
}

cmd_globus_put() {
  local src="${1:?usage: globus-put <local-path> [remote-subpath]}" sub="${2:-}"
  globus_need; globus_need_laptop
  local abs; abs=$(cd -P -- "$(dirname -- "$src")" && printf '%s/%s' "$(pwd)" "$(basename -- "$src")")
  globus_submit "expanse-put-$EXPANSE_PROJECT" "$GLOBUS_LAPTOP:$abs" \
    "$GLOBUS_EXPANSE_LUSTRE:$GLOBUS_SCRATCH_PREFIX/$EXPANSE_PROJECT/${sub:-$(basename -- "$src")}"
}

cmd_globus_get() {
  local sub="${1:?usage: globus-get <remote-subpath> <local-dest>}"
  local dest="${2:?usage: globus-get <remote-subpath> <local-dest>}"
  globus_need; globus_need_laptop
  mkdir -p "$dest"
  local abs; abs=$(cd -P -- "$dest" && pwd)
  globus_submit "expanse-get-$EXPANSE_PROJECT" \
    "$GLOBUS_EXPANSE_LUSTRE:$GLOBUS_SCRATCH_PREFIX/$EXPANSE_PROJECT/$sub" "$GLOBUS_LAPTOP:$abs"
}

# Scratch is purged 90 days after creation; project space is not.
cmd_globus_archive() {
  local sub="${1:?usage: globus-archive <subpath-under-the-run-dir>}"
  globus_need
  require_account
  # Both live on the Expanse Lustre collection: it exposes /scratch and
  # /projects side by side. The separate "SDSC HPC - Projects" collection is
  # unrelated storage and does NOT hold Expanse allocation directories.
  globus_submit "expanse-archive-$EXPANSE_PROJECT" \
    "$GLOBUS_EXPANSE_LUSTRE:$GLOBUS_SCRATCH_PREFIX/$EXPANSE_PROJECT/$sub" \
    "$GLOBUS_EXPANSE_LUSTRE:$GLOBUS_PROJECTS_PREFIX/$EXPANSE_PROJECT/$sub"
}

cmd_globus_restore() {
  local sub="${1:?usage: globus-restore <subpath>}"
  globus_need
  require_account
  globus_submit "expanse-restore-$EXPANSE_PROJECT" \
    "$GLOBUS_EXPANSE_LUSTRE:$GLOBUS_PROJECTS_PREFIX/$EXPANSE_PROJECT/$sub" \
    "$GLOBUS_EXPANSE_LUSTRE:$GLOBUS_SCRATCH_PREFIX/$EXPANSE_PROJECT/$sub"
}

cmd_globus_status() {
  local task="${1:-}"
  [ -z "$task" ] && { globus_cli task list --limit 10; return 0; }
  globus_cli task show "$task"
}

cmd_globus_wait() {
  local task="${1:?usage: globus-wait <task-id> [timeout-seconds]}"
  globus_cli task wait "$task" --timeout "${2:-3600}" --polling-interval 15
  globus_cli task show "$task"
}

# --- turning a plain script into a SLURM job ---------------------------------
W_NAME=""; W_PART=""; W_GPUS=""; W_CPUS=""; W_MEM=""; W_TIME=""
W_NODES=""; W_NTASKS=""; W_CONDA=""; W_SIF=""; W_ARGS=""; W_INTERP=""; W_OUT=""
W_LAUNCH=""; W_PORT=""; W_GPUN=0; W_SRC=""; W_FORCE=0; W_CONDA_SH=""; W_WAIT=auto
W_MODULES=(); W_WITH=()

wrap_reset() {
  W_NAME=""; W_PART=""; W_GPUS=""; W_CPUS=""; W_MEM=""; W_TIME=""
  W_NODES=""; W_NTASKS=""; W_CONDA=""; W_SIF=""; W_ARGS=""; W_INTERP=""; W_OUT=""
  W_LAUNCH=""; W_PORT=""; W_GPUN=0; W_SRC=""; W_FORCE=0; W_CONDA_SH=""; W_WAIT=auto; W_CONDA_SH=""
  W_MODULES=(); W_WITH=()
}

imin() { [ "$1" -le "$2" ] && printf '%s' "$1" || printf '%s' "$2"; }

wrap_parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)             W_NAME="${2:?--name needs a value}"; shift 2 ;;
      --partition|-p)     W_PART="${2:?--partition needs a value}"; shift 2 ;;
      --gpus)             W_GPUS="${2:?--gpus needs a value}"; shift 2 ;;
      --cpus)             W_CPUS="${2:?--cpus needs a value}"; shift 2 ;;
      --mem)              W_MEM="${2:?--mem needs a value}"; shift 2 ;;
      --time|-t)          W_TIME="${2:?--time needs a value}"; shift 2 ;;
      --nodes)            W_NODES="${2:?--nodes needs a value}"; shift 2 ;;
      --ntasks-per-node)  W_NTASKS="${2:?--ntasks-per-node needs a value}"; shift 2 ;;
      --conda)            W_CONDA="${2:?--conda needs a value}"; shift 2 ;;
      --conda-sh)         W_CONDA_SH="${2:?--conda-sh needs a value}"; shift 2 ;;
      --sif)              W_SIF="${2:?--sif needs a value}"; shift 2 ;;
      --module)           W_MODULES+=("${2:?--module needs a value}"); shift 2 ;;
      --with)             W_WITH+=("${2:?--with needs a value}"); shift 2 ;;
      --interpreter)      W_INTERP="${2:?--interpreter needs a value}"; shift 2 ;;
      --launcher)         W_LAUNCH="${2:?--launcher needs a value}"; shift 2 ;;
      --force)            W_FORCE=1; shift ;;
      --no-wait)          W_WAIT=no; shift ;;
      --wait)             W_WAIT=yes; shift ;;
      --master-port)      W_PORT="${2:?--master-port needs a value}"; shift 2 ;;
      --args)             W_ARGS="${2:?--args needs a value}"; shift 2 ;;
      --out|-o)           W_OUT="${2:?--out needs a value}"; shift 2 ;;
      --)                 shift; W_ARGS="$*"; break ;;
      -*)                 die "unknown option: $1 (see: expanse.sh --help)" ;;
      *)                  die "unexpected argument: $1" ;;
    esac
  done
}

# Fill in whatever the caller did not specify, using the shape of the partition.
# Resources scale with the GPU count: asking for 4 GPUs and leaving the cores and
# memory at a one-GPU share is the classic way to pay 4x and go no faster.
wrap_defaults() {
  W_PART="${W_PART:-gpu-shared}"
  W_NODES="${W_NODES:-1}"

  local per_core=0 per_mem=0 max_core=0 max_mem=0 exclusive=0
  case "$W_PART" in
    gpu-shared|gpu-preempt)
      W_GPUS="${W_GPUS:-1}"; per_core=10; per_mem=92;  max_core=37; max_mem=344 ;;
    gpu-debug)
      W_GPUS="${W_GPUS:-1}"; per_core=10; per_mem=92;  max_core=40; max_mem=368
      W_TIME="${W_TIME:-00:30:00}" ;;
    nairr-gpu-shared)
      W_GPUS="${W_GPUS:-1}"; per_core=18; per_mem=240; max_core=72; max_mem=950 ;;
    gpu)
      W_GPUS="${W_GPUS:-4}"; per_core=10; per_mem=92;  max_core=40; max_mem=368; exclusive=1 ;;
    nairr-gpu)
      W_GPUS="${W_GPUS:-4}"; per_core=18; per_mem=240; max_core=72; max_mem=950; exclusive=1 ;;
    shared|preempt)
      W_CPUS="${W_CPUS:-16}"; W_MEM="${W_MEM:-32G}" ;;
    compute)
      W_CPUS="${W_CPUS:-128}"; W_MEM="${W_MEM:-249325M}"; exclusive=1 ;;
    large-shared)
      W_CPUS="${W_CPUS:-16}"; W_MEM="${W_MEM:-256G}" ;;
    debug)
      W_CPUS="${W_CPUS:-4}"; W_MEM="${W_MEM:-8G}"; W_TIME="${W_TIME:-00:30:00}" ;;
    *)
      note "warning: unrecognised partition '$W_PART'; specify --cpus, --mem and --time yourself" ;;
  esac

  # GPU count as a plain integer, whatever prefix the caller used.
  W_GPUN=0
  if [ -n "$W_GPUS" ]; then
    W_GPUN="${W_GPUS#*:}"
    case "$W_GPUN" in
      ''|*[!0-9]*) die "--gpus must be a number, or h100:<number>; got '$W_GPUS'" ;;
    esac
  fi
  [ "$W_GPUN" -gt 4 ] && die "a node has at most 4 GPUs; for $W_GPUN use --nodes $(( (W_GPUN + 3) / 4 )) with 4 GPUs each"
  # Queue limits come from SLURM QOS, not from the user guide, and they differ.
  case "$W_PART" in
    gpu-shared)
      [ "$W_GPUN" -gt 3 ] && die "gpu-shared allows at most 3 GPUs per job (QOS gpu-shared-normal: gres/gpu=3, cpu=37, mem=353000M). For 4 GPUs use --partition gpu, which gives a whole exclusive node." ;;
  esac

  # Scale cores and memory to the GPUs actually requested.
  if [ "$per_core" -gt 0 ] && [ "$W_GPUN" -gt 0 ]; then
    if [ "$exclusive" = 1 ]; then
      W_CPUS="${W_CPUS:-$max_core}"; W_MEM="${W_MEM:-${max_mem}G}"
    else
      W_CPUS="${W_CPUS:-$(imin $((per_core * W_GPUN)) "$max_core")}"
      W_MEM="${W_MEM:-$(imin $((per_mem * W_GPUN)) "$max_mem")G}"
    fi
  fi
  W_TIME="${W_TIME:-02:00:00}"

  # The AI resource rejects a bare GPU count: the type must be named.
  case "$W_PART" in
    nairr-*) [ -n "$W_GPUS" ] && W_GPUS="h100:${W_GPUS#*:}" ;;
    *)       W_GPUS="${W_GPUS#h100:}" ;;
  esac

  wrap_resolve_launcher

  # torchrun and accelerate spawn one worker per GPU themselves, so SLURM must
  # start exactly one task per node. Getting this wrong launches N launchers
  # each spawning N workers, and the job deadlocks on the rendezvous.
  case "$W_LAUNCH" in
    torchrun|accelerate) W_NTASKS=1 ;;
    srun)                W_NTASKS="${W_NTASKS:-$W_GPUN}" ;;
    *)                   W_NTASKS="${W_NTASKS:-1}" ;;
  esac
  W_PORT="${W_PORT:-29500}"

  # Only the exclusive partitions can span nodes.
  if [ "$W_NODES" -gt 1 ]; then
    case "$W_PART" in
      gpu|nairr-gpu|compute|preempt) : ;;
      *) die "partition $W_PART is limited to 1 node; use --partition gpu (or nairr-gpu) for multi-node" ;;
    esac
    [ "$W_LAUNCH" = accelerate ] && die "multi-node with accelerate is not generated here; use --launcher torchrun"
  fi

  # Debug partitions are capped at 30 minutes; refuse rather than let SLURM reject it.
  case "$W_PART" in
    debug|gpu-debug)
      case "$W_TIME" in
        00:0*|00:1*|00:2*|00:30:00) : ;;
        *) die "partition $W_PART allows at most 00:30:00, got --time $W_TIME" ;;
      esac ;;
  esac
}

# Decide how the payload is started across GPUs.
wrap_resolve_launcher() {
  local total=$(( W_GPUN * W_NODES ))
  case "${W_LAUNCH:-auto}" in
    none|torchrun|accelerate|srun) return 0 ;;
    auto) : ;;
    *) die "--launcher must be one of: auto, torchrun, accelerate, srun, none" ;;
  esac
  if [ "$total" -gt 1 ] && [ "$(wrap_interpreter "${W_SRC:-x.py}")" = python ]; then
    W_LAUNCH=torchrun
    note "multi-GPU: using torchrun with $W_GPUN process(es) per node across $W_NODES node(s) = $total total."
    note "Your script must be distribution-aware (torch DDP, Lightning, HF Trainer or accelerate)."
    note "Override with --launcher none if it handles multiple GPUs by itself."
  else
    W_LAUNCH=none
  fi
}

wrap_interpreter() {
  local f="$1"
  [ -n "$W_INTERP" ] && { printf '%s' "$W_INTERP"; return; }
  case "$f" in
    *.py)        printf 'python' ;;
    *.sh|*.bash) printf 'bash' ;;
    *.R|*.r)     printf 'Rscript' ;;
    *.jl)        printf 'julia' ;;
    *.pl)        printf 'perl' ;;
    *)           printf 'bash' ;;
  esac
}

# Emit an sbatch script to stdout. {{ACCOUNT}}/{{RUN_DIR}} stay as placeholders so
# the output is portable and `submit` fills them in from the caller's config.
wrap_emit() {
  local src="$1" base interp gpu_line ntasks_line
  base=$(basename -- "$src")
  interp=$(wrap_interpreter "$base")
  local name="${W_NAME:-${base%.*}}"

  gpu_line=""
  [ -n "$W_GPUS" ] && gpu_line="#SBATCH --gpus=$W_GPUS"
  ntasks_line="#SBATCH --ntasks-per-node=$W_NTASKS"

  local is_gpu=cpu
  case "$W_PART" in gpu*|nairr-*) is_gpu=gpu ;; esac

  printf '%s\n' "#!/bin/bash"
  printf '%s\n' "# Generated by expanse.sh wrap from: $base"
  printf '%s\n' "# Edit freely, or regenerate with different options."
  printf '%s\n' ""
  printf '%s\n' "#SBATCH --job-name=$name"
  printf '%s\n' "#SBATCH --account={{ACCOUNT}}"
  printf '%s\n' "#SBATCH --partition=$W_PART"
  printf '%s\n' "#SBATCH --nodes=$W_NODES"
  printf '%s\n' "$ntasks_line"
  [ -n "$gpu_line" ] && printf '%s\n' "$gpu_line"
  printf '%s\n' "#SBATCH --cpus-per-task=$W_CPUS"
  printf '%s\n' "#SBATCH --mem=$W_MEM"
  printf '%s\n' "#SBATCH --time=$W_TIME"
  printf '%s\n' "#SBATCH --output={{RUN_DIR}}/logs/%x.%j.out"
  printf '%s\n' "#SBATCH --error={{RUN_DIR}}/logs/%x.%j.err"
  printf '%s\n' "#SBATCH --no-requeue"
  printf '%s\n' ""
  printf '%s\n' "set -euo pipefail"
  printf '%s\n' ""
  printf '%s\n' "module purge"
  printf '%s\n' "module load $is_gpu"
  printf '%s\n' "module load slurm"
  local m
  # A container image is useless without its runtime; load it unless the caller
  # already named a singularity/apptainer module themselves.
  if [ -n "$W_SIF" ]; then
    local has_container=0
    for m in ${W_MODULES[@]+"${W_MODULES[@]}"}; do
      case "$m" in singularity*|apptainer*) has_container=1 ;; esac
    done
    [ "$has_container" = 0 ] && printf '%s\n' "module load singularitypro"
  fi
  for m in ${W_MODULES[@]+"${W_MODULES[@]}"}; do printf '%s\n' "module load $m"; done
  printf '%s\n' ""
  printf '%s\n' 'export RUN_DIR="{{RUN_DIR}}"'
  printf '%s\n' 'export LOCAL_SCRATCH="/scratch/$USER/job_$SLURM_JOB_ID"'
  printf '%s\n' 'export TMPDIR="$LOCAL_SCRATCH"'
  printf '%s\n' '# Keep every cache off /home: 100 GB quota, and not built for throughput.'
  printf '%s\n' 'export HF_HOME="$RUN_DIR/cache/huggingface"'
  printf '%s\n' 'export TORCH_HOME="$RUN_DIR/cache/torch"'
  printf '%s\n' 'export PIP_CACHE_DIR="$RUN_DIR/cache/pip"'
  printf '%s\n' 'export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"'
  printf '%s\n' 'mkdir -p "$LOCAL_SCRATCH" "$HF_HOME" "$TORCH_HOME" "$PIP_CACHE_DIR" "$RUN_DIR/outputs"'
  printf '%s\n' 'cd "$RUN_DIR"'
  printf '%s\n' ""
  if [ -n "$W_CONDA" ]; then
    local conda_sh="${W_CONDA_SH:-${EXPANSE_CONDA_SH:-\$RUN_DIR/miniconda3/etc/profile.d/conda.sh}}"
    printf '%s\n' "source \"$conda_sh\""
    printf '%s\n' "conda activate $W_CONDA"
    printf '%s\n' ""
  fi
  # Distributed setup, only when more than one worker is involved.
  case "$W_LAUNCH" in
    torchrun|accelerate|srun)
      printf '%s\n' "# Distributed run: $W_GPUN process(es) per node across $W_NODES node(s)."
      printf '%s\n' 'export NCCL_DEBUG=WARN'
      # Each worker gets its share of the cores; leaving this at the job total
      # makes every rank spawn N threads and thrash the node.
      printf '%s\n' "export OMP_NUM_THREADS=$(( W_CPUS / (W_GPUN > 0 ? W_GPUN : 1) ))"
      if [ "$W_NODES" -gt 1 ]; then
        printf '%s\n' 'MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n1)'
        printf '%s\n' "export MASTER_ADDR MASTER_PORT=$W_PORT"
        printf '%s\n' 'echo "rendezvous: $MASTER_ADDR:$MASTER_PORT nodes=$SLURM_NNODES"'
      fi
      printf '%s\n' ""
      ;;
  esac
  printf '%s\n' 'echo "host=$(hostname) job=$SLURM_JOB_ID started=$(date -Is)"'
  if [ "$is_gpu" = gpu ]; then
    printf '%s\n' 'nvidia-smi --query-gpu=index,name,memory.total --format=csv'
  fi
  printf '%s\n' ""
  # How the payload is started across the GPUs.
  local payload
  case "$W_LAUNCH" in
    torchrun)
      if [ "$W_NODES" -gt 1 ]; then
        payload="srun --cpu-bind=cores torchrun \\
  --nnodes=\"\$SLURM_NNODES\" \\
  --nproc_per_node=$W_GPUN \\
  --rdzv_id=\"\$SLURM_JOB_ID\" \\
  --rdzv_backend=c10d \\
  --rdzv_endpoint=\"\$MASTER_ADDR:\$MASTER_PORT\" \\
  $base${W_ARGS:+ $W_ARGS}"
      else
        payload="torchrun --standalone --nnodes=1 --nproc_per_node=$W_GPUN \\
  $base${W_ARGS:+ $W_ARGS}"
      fi ;;
    accelerate)
      payload="accelerate launch --num_machines=1 --num_processes=$W_GPUN \\
  $base${W_ARGS:+ $W_ARGS}" ;;
    srun)
      payload="srun --cpu-bind=cores $interp $base${W_ARGS:+ $W_ARGS}" ;;
    *)
      payload="$interp $base${W_ARGS:+ $W_ARGS}" ;;
  esac

  if [ -n "$W_SIF" ]; then
    # --nv is what exposes the GPUs; without it CUDA is invisible inside the image.
    printf '%s\n' "singularity exec --nv --bind \"\$RUN_DIR\":\"\$RUN_DIR\" $W_SIF $payload"
  else
    printf '%s\n' "$payload"
  fi
  printf '%s\n' ""
  printf '%s\n' 'echo "finished=$(date -Is)"'
}

# A launcher runs the script once per GPU. If the script is not written for that,
# every GPU trains its own redundant copy and they overwrite each other's output:
# N times the cost, no speedup, corrupted checkpoints. Refuse rather than spend
# an allocation discovering it.
wrap_check_distributed() {
  case "$W_LAUNCH" in torchrun|accelerate|srun) : ;; *) return 0 ;; esac
  [ "$W_FORCE" = 1 ] && return 0
  [ -f "$W_SRC" ] || return 0
  case "$W_SRC" in *.py) : ;; *) return 0 ;; esac
  if grep -Eq 'DistributedDataParallel|torch\.distributed|init_process_group|LOCAL_RANK|[Aa]ccelerator\(|accelerate|Trainer\(|SentenceTransformerTrainer|pytorch_lightning|lightning|deepspeed|Fabric\(|FSDP|fully_sharded' "$W_SRC"; then
    return 0
  fi
  cat >&2 <<EOF
error: $(basename -- "$W_SRC") looks like single-process training code, but this job
would start $W_GPUN process(es) per node with $W_LAUNCH.

Each process runs the script top to bottom on its own GPU. Nothing coordinates
them, so you would get $W_GPUN redundant copies of the same training run, all
writing to the same output path. That costs $W_GPUN times as much and finishes no
sooner.

Found no sign of DDP, HuggingFace Trainer, accelerate, Lightning or DeepSpeed.

Pick one:
  - run on a single GPU:            --gpus 1
  - the script already spreads work itself (e.g. nn.DataParallel):
                                    --launcher none
  - make the script distribution-aware: see reference/distributed.md
  - you are certain this is wrong:  --force
EOF
  exit 1
}

cmd_wrap() {
  local src="${1:?usage: wrap <script> [options]}"; shift || true
  [ -f "$src" ] || die "no such script: $src"
  wrap_reset
  wrap_parse_opts "$@"
  W_SRC="$src"
  wrap_defaults
  wrap_check_distributed
  if [ -n "$W_OUT" ]; then
    wrap_emit "$src" > "$W_OUT"
    note "wrote $W_OUT"
  else
    wrap_emit "$src"
  fi
}

cmd_launch() {
  local src="${1:?usage: launch <script> [options]}"; shift || true
  [ -f "$src" ] || die "no such script: $src"
  wrap_reset
  wrap_parse_opts "$@"
  W_SRC="$src"
  wrap_defaults
  wrap_check_distributed
  require_account
  require_user
  require_master

  local base rundir sbatch_file
  base=$(basename -- "$src")
  rundir="$(remote_run_dir)"
  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/expanse-XXXXXX")
  sbatch_file="$tmpdir/${W_NAME:-${base%.*}}.sbatch"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  wrap_emit "$src" > "$sbatch_file"

  note "staging $base and its inputs into $rundir"
  r "mkdir -p '$rundir/logs' '$rundir/outputs'"
  rsync -az -e "$(rsh_cmd)" "$src" "$EXPANSE_USER@$EXPANSE_HOST:$rundir/$base"
  local extra
  for extra in ${W_WITH[@]+"${W_WITH[@]}"}; do
    [ -e "$extra" ] || die "no such --with path: $extra"
    rsync -az -e "$(rsh_cmd)" "$extra" "$EXPANSE_USER@$EXPANSE_HOST:$rundir/"
  done

  local jobid
  jobid=$(cmd_submit "$sbatch_file")
  note "submitted job $jobid on $W_PART (${W_GPUS:-no} gpu, $W_CPUS cpu, $W_MEM, $W_TIME)"
  # The job id is always the FIRST line of stdout, whether or not we wait, so
  # callers can read it the same way in both cases.
  printf '%s\n' "$jobid"

  # Blocking on a multi-hour job is wrong: SLURM keeps running whether anyone
  # watches or not. Wait only for short jobs, unless told otherwise.
  local wait_for="$W_WAIT"
  if [ "$wait_for" = auto ]; then
    case "$W_TIME" in
      00:0*|00:1*|00:2*|00:30:00) wait_for=yes ;;
      *)                          wait_for=no ;;
    esac
  fi

  if [ "$wait_for" = no ]; then
    cat >&2 <<EOF

Job $jobid is queued. It runs on the cluster whether or not you stay connected,
so nothing is lost by closing your laptop.

  expanse status $jobid      what state it is in
  expanse logs $jobid        output so far
  expanse logs $jobid -f     follow it live
  expanse wait $jobid        block until it finishes
  expanse cancel $jobid      stop it

When it finishes, save the results - scratch is purged after 90 days:
  expanse globus-archive outputs
EOF
    return 0
  fi

  cmd_wait "$jobid" || true
  cmd_logs "$jobid"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    login)      cmd_login "$@" ;;
    check)      cmd_check "$@" ;;
    logout)     cmd_logout "$@" ;;
    config)     cmd_config "$@" ;;
    exec)       r "$@" ;;
    alloc)      cmd_alloc "$@" ;;
    partitions) cmd_partitions "$@" ;;
    push)       cmd_push "$@" ;;
    push-code)  cmd_push_code "$@" ;;
    pull)       cmd_pull "$@" ;;
    globus-check)     cmd_globus_check "$@" ;;
    globus-endpoints) cmd_globus_endpoints "$@" ;;
    globus-put)       cmd_globus_put "$@" ;;
    globus-get)       cmd_globus_get "$@" ;;
    globus-archive)   cmd_globus_archive "$@" ;;
    globus-restore)   cmd_globus_restore "$@" ;;
    globus-status)    cmd_globus_status "$@" ;;
    globus-wait)      cmd_globus_wait "$@" ;;
    wrap)       cmd_wrap "$@" ;;
    launch)     cmd_launch "$@" ;;
    submit)     cmd_submit "$@" ;;
    status)     cmd_status "$@" ;;
    wait)       cmd_wait "$@" ;;
    logs)       cmd_logs "$@" ;;
    cancel)     cmd_cancel "$@" ;;
    run)        cmd_run "$@" ;;
    ""|-h|--help|help)
      awk 'NR>1 && /^set -euo/ {exit} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}" ;;
    *)          die "unknown command: $cmd (try --help)" ;;
  esac
}
main "$@"
