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
#   submit <script.sbatch> [--wait] submit a job; prints JOBID
#   status [jobid]                 squeue for the user, or one job (falls back to sacct)
#   wait <jobid> [timeout-sec]     block until the job leaves the queue
#   logs <jobid> [-f]              print (or follow) the job's stdout file
#   cancel <jobid>                 scancel
#   run <script.sbatch>            push + submit + wait + logs, end to end
#   config                         print the resolved configuration
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")

# --- configuration -----------------------------------------------------------
# Precedence: environment > repo-local .expanse.env > ~/.config/expanse/config.env
CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/expanse/config.env"
CONFIG_REPO="$REPO_DIR/.expanse.env"

load_config() {
  local f
  for f in "$CONFIG_USER" "$CONFIG_REPO"; do
    if [ -f "$f" ]; then
      # shellcheck disable=SC1090
      set -a; . "$f"; set +a
    fi
  done
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
  rsync -az --info=stats1 -e "$(rsh_cmd)" "$src" "$EXPANSE_USER@$EXPANSE_HOST:$dst/"
  printf '%s\n' "$dst"
}

cmd_push_code() {
  local src="${1:?usage: push-code <local-path> [remote-subpath]}"; shift || true
  local sub="${1:-}"
  local dst; dst="$(remote_code_dir)${sub:+/$sub}"
  require_master
  r "mkdir -p '$dst'"
  rsync -az --info=stats1 -e "$(rsh_cmd)" "$src" "$EXPANSE_USER@$EXPANSE_HOST:$dst/"
  printf '%s\n' "$dst"
}

cmd_pull() {
  local sub="${1:?usage: pull <remote-subpath> <local-dest>}"
  local dest="${2:?usage: pull <remote-subpath> <local-dest>}"
  require_master
  mkdir -p "$dest"
  rsync -az --info=stats1 -e "$(rsh_cmd)" \
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
    submit)     cmd_submit "$@" ;;
    status)     cmd_status "$@" ;;
    wait)       cmd_wait "$@" ;;
    logs)       cmd_logs "$@" ;;
    cancel)     cmd_cancel "$@" ;;
    run)        cmd_run "$@" ;;
    ""|-h|--help|help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *)          die "unknown command: $cmd (try --help)" ;;
  esac
}
main "$@"
