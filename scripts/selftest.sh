#!/usr/bin/env bash
# selftest.sh - verify everything about this skill that does not need a cluster.
#
# Checks job generation, resource scaling, launcher selection, every safety
# guard, and that each generated job script is valid bash. Needs no Expanse
# account, no network, and no live session.
#
#   scripts/selftest.sh
#
# For the parts that DO need the cluster, see the end of the output.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
EXP="$SCRIPT_DIR/expanse.sh"
EX="$REPO_DIR/examples"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Run generation in a sandbox so a real config cannot change the results.
gen() { env XDG_CONFIG_HOME="$WORK/cfg" EXPANSE_USER=testuser EXPANSE_ACCOUNT=abc123 \
             EXPANSE_PROJECT=selftest "$EXP" "$@"; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
have() { # have <description> <pattern> <file>
  if grep -qE "$2" "$3"; then ok "$1"; else bad "$1 (expected /$2/)"; fi
}
lacks() {
  if grep -qE "$2" "$3"; then bad "$1 (unexpected /$2/)"; else ok "$1"; fi
}
refuses() { # refuses <description> <args...>
  local desc="$1"; shift
  if gen wrap "$@" >/dev/null 2>&1; then bad "$desc (should have refused)"; else ok "$desc"; fi
}
accepts() {
  local desc="$1"; shift
  if gen wrap "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc (should have been accepted)"; fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

printf '\033[1mExpanse skill self-test\033[0m\n'

section "Files present"
for f in SKILL.md AGENTS.md README.md INSTALL.md \
         scripts/expanse.sh scripts/expanse-setup.sh \
         reference/slurm.md reference/filesystems.md reference/software.md \
         reference/distributed.md reference/troubleshooting.md \
         examples/smoke_train.py examples/smoke_single.py; do
  [ -f "$REPO_DIR/$f" ] && ok "$f" || bad "$f missing"
done

section "Scripts are syntactically valid"
for f in "$EXP" "$SCRIPT_DIR/expanse-setup.sh" "$REPO_DIR"/templates/*.sbatch; do
  bash -n "$f" 2>/dev/null && ok "$(basename -- "$f")" || bad "$(basename -- "$f") has a syntax error"
done
if command -v python3 >/dev/null 2>&1; then
  for f in "$EX"/*.py; do
    python3 -m py_compile "$f" 2>/dev/null && ok "$(basename -- "$f")" || bad "$(basename -- "$f") has a syntax error"
  done
fi

section "Single GPU job"
gen wrap "$EX/smoke_train.py" --gpus 1 > "$WORK/g1.sbatch" 2>/dev/null
have  "requests 1 GPU"                  '^#SBATCH --gpus=1$'            "$WORK/g1.sbatch"
have  "10 cores"                        '^#SBATCH --cpus-per-task=10$'  "$WORK/g1.sbatch"
have  "92G memory"                      '^#SBATCH --mem=92G$'           "$WORK/g1.sbatch"
have  "loads the gpu module"            '^module load gpu$'             "$WORK/g1.sbatch"
have  "runs the script directly"        '^python smoke_train.py'        "$WORK/g1.sbatch"
lacks "no launcher for one GPU"         'torchrun|accelerate'           "$WORK/g1.sbatch"
have  "caches off /home"                'HF_HOME="\$RUN_DIR'            "$WORK/g1.sbatch"
have  "works from the run directory"    '^cd "\$RUN_DIR"$'              "$WORK/g1.sbatch"
have  "account placeholder present"     '^#SBATCH --account=\{\{ACCOUNT\}\}$' "$WORK/g1.sbatch"

section "Multi-GPU job, one node"
gen wrap "$EX/smoke_train.py" --partition gpu --gpus 4 > "$WORK/g4.sbatch" 2>/dev/null
have  "requests 4 GPUs"                 '^#SBATCH --gpus=4$'            "$WORK/g4.sbatch"
have  "cores scaled to 40"              '^#SBATCH --cpus-per-task=40$'  "$WORK/g4.sbatch"
have  "memory scaled to 368G"           '^#SBATCH --mem=368G$'          "$WORK/g4.sbatch"
have  "one task per node under torchrun" '^#SBATCH --ntasks-per-node=1$' "$WORK/g4.sbatch"
have  "torchrun with 4 workers"         'torchrun --standalone --nnodes=1 --nproc_per_node=4' "$WORK/g4.sbatch"
have  "threads divided per rank"        '^export OMP_NUM_THREADS=10$'   "$WORK/g4.sbatch"

gen wrap "$EX/smoke_train.py" --partition gpu-shared --gpus 3 > "$WORK/gs3.sbatch" 2>/dev/null
have  "gpu-shared 3 GPUs stays under the QOS cpu cap" '^#SBATCH --cpus-per-task=30$' "$WORK/gs3.sbatch"
have  "gpu-shared 3 GPUs stays under the QOS mem cap" '^#SBATCH --mem=276G$'          "$WORK/gs3.sbatch"

section "Multi-node job"
gen wrap "$EX/smoke_train.py" --partition gpu --nodes 2 --gpus 4 > "$WORK/g8.sbatch" 2>/dev/null
have  "two nodes"                       '^#SBATCH --nodes=2$'           "$WORK/g8.sbatch"
have  "one launcher per node"           '^#SBATCH --ntasks-per-node=1$' "$WORK/g8.sbatch"
have  "rendezvous host from SLURM"      'scontrol show hostnames'       "$WORK/g8.sbatch"
have  "srun drives torchrun"            'srun --cpu-bind=cores torchrun' "$WORK/g8.sbatch"
have  "c10d rendezvous"                 'rdzv_backend=c10d'             "$WORK/g8.sbatch"

section "H100 (Expanse AI Resource)"
gen wrap "$EX/smoke_train.py" --partition nairr-gpu-shared --gpus 2 > "$WORK/h100.sbatch" 2>/dev/null
have  "GPU type named, as required"     '^#SBATCH --gpus=h100:2$'       "$WORK/h100.sbatch"
have  "H100 core ratio"                 '^#SBATCH --cpus-per-task=36$'  "$WORK/h100.sbatch"
have  "H100 memory ratio"               '^#SBATCH --mem=480G$'          "$WORK/h100.sbatch"

section "CPU job"
gen wrap "$REPO_DIR/templates/interactive.sh" --partition shared > "$WORK/cpu.sbatch" 2>/dev/null
have  "loads the cpu module"            '^module load cpu$'             "$WORK/cpu.sbatch"
lacks "no GPU request"                  '^#SBATCH --gpus'               "$WORK/cpu.sbatch"
lacks "no distributed setup"            'NCCL|torchrun'                 "$WORK/cpu.sbatch"

section "Safety guards"
refuses "single-process script on 4 GPUs" "$EX/smoke_single.py" --gpus 4
accepts "single-process script on 1 GPU"  "$EX/smoke_single.py" --gpus 1
accepts "single-process script with --launcher none" "$EX/smoke_single.py" --partition gpu --gpus 4 --launcher none
accepts "distributed script on 4 GPUs"    "$EX/smoke_train.py" --partition gpu --gpus 4
refuses "more than 4 GPUs on one node"    "$EX/smoke_train.py" --gpus 8
refuses "multi-node on a shared partition" "$EX/smoke_train.py" --nodes 2 --gpus 4
refuses "more than 3 GPUs on gpu-shared"  "$EX/smoke_train.py" --partition gpu-shared --gpus 4
accepts "3 GPUs on gpu-shared (the QOS ceiling)" "$EX/smoke_train.py" --partition gpu-shared --gpus 3
accepts "4 GPUs on gpu-debug (QOS allows 8)" "$EX/smoke_train.py" --partition gpu-debug --gpus 4
refuses "over the 30 minute debug cap"    "$EX/smoke_train.py" --partition gpu-debug --time 04:00:00
refuses "unknown launcher"                "$EX/smoke_train.py" --gpus 2 --launcher nonsense
refuses "multi-node with accelerate"      "$EX/smoke_train.py" --partition gpu --nodes 2 --gpus 4 --launcher accelerate
refuses "non-numeric GPU count"           "$EX/smoke_train.py" --gpus two
refuses "missing script"                  "$WORK/does-not-exist.py" --gpus 1

# These commands are SUPPOSED to exit non-zero, so capture their output first
# rather than piping - pipefail would report the intended refusal as a failure.
says() { # says <description> <pattern> <command...>
  local desc="$1" pat="$2"; shift 2
  local out; out=$("$@" 2>&1)
  case "$out" in *"$pat"*) ok "$desc" ;; *) bad "$desc (got: ${out%%$'\n'*})" ;; esac
}

section "Submission guards"
printf '#!/bin/bash\n#SBATCH --nodes={{NODES}}\n#SBATCH --account={{ACCOUNT}}\n' > "$WORK/ph.sbatch"
says "refuses unfilled placeholders" "unfilled placeholders" \
     env XDG_CONFIG_HOME="$WORK/cfg" EXPANSE_USER=testuser EXPANSE_ACCOUNT=abc123 "$EXP" submit "$WORK/ph.sbatch"
printf '#!/bin/bash\n#SBATCH --nodes=1\n' > "$WORK/noacct.sbatch"
says "refuses a job with no allocation" "no #SBATCH --account" \
     env XDG_CONFIG_HOME="$WORK/cfg" EXPANSE_USER=testuser EXPANSE_ACCOUNT=abc123 "$EXP" submit "$WORK/noacct.sbatch"

section "Symlink resolution (the PATH shim is a symlink)"
SHIM="$WORK/bin/expanse"
mkdir -p "$WORK/bin"; ln -sf "$EXP" "$SHIM"
out=$(env XDG_CONFIG_HOME="$WORK/cfg" "$SHIM" config 2>&1)
case "$out" in
  *"$REPO_DIR/.expanse.env"*) ok "finds the real repo through the symlink" ;;
  *) bad "resolves to the symlink's directory instead of the repo" ;;
esac
case "$out" in
  *"$REPO_DIR/scripts/expanse-setup.sh"*) ok "names a setup path that exists" ;;
  *) bad "names a setup path that does not exist" ;;
esac

section "Setup works without a terminal"
SB="$WORK/sandbox"; mkdir -p "$SB"
says "refuses with guidance when given no username" "not interactive" \
     env HOME="$SB" XDG_CONFIG_HOME="$SB/cfg" "$SCRIPT_DIR/expanse-setup.sh"
if env HOME="$SB" XDG_CONFIG_HOME="$SB/cfg" "$SCRIPT_DIR/expanse-setup.sh" \
     --user testuser --account abc123 --project selftest >/dev/null 2>&1; then
  ok "configures non-interactively from flags"
else
  bad "configures non-interactively from flags"
fi
if grep -q '^EXPANSE_ACCOUNT=abc123$' "$SB/cfg/expanse/config.env" 2>/dev/null; then
  ok "writes the allocation to the config"; else bad "writes the allocation to the config"; fi
if grep -q 'ControlMaster auto' "$SB/.ssh/config" 2>/dev/null; then
  ok "adds the connection-sharing ssh block"; else bad "adds the connection-sharing ssh block"; fi
env HOME="$SB" XDG_CONFIG_HOME="$SB/cfg" "$SCRIPT_DIR/expanse-setup.sh" --user testuser >/dev/null 2>&1
if [ "$(grep -c 'Host expanse' "$SB/.ssh/config")" = 1 ]; then
  ok "re-running does not duplicate the ssh block"; else bad "re-running duplicates the ssh block"; fi

section "Onboarding"
[ -x "$SCRIPT_DIR/onboard.sh" ] && ok "onboard.sh is executable" || bad "onboard.sh missing or not executable"
bash -n "$SCRIPT_DIR/onboard.sh" 2>/dev/null && ok "onboard.sh is valid bash" || bad "onboard.sh has a syntax error"
OUT=$(HOME="$WORK/fresh" XDG_CONFIG_HOME="$WORK/fresh/cfg" "$SCRIPT_DIR/onboard.sh" 2>&1)
case "$OUT" in *"Next step"*) ok "always prints a single next step" ;; *) bad "no next step printed" ;; esac
case "$OUT" in *passive.sdsc.edu*) ok "tells a new user how to enrol in 2FA" ;; *) bad "2FA enrolment not explained" ;; esac
case "$OUT" in *"ACCESS allocation"*) ok "lists what the project owner must provide" ;; *) bad "allocation prerequisites missing" ;; esac
if HOME="$WORK/fresh" XDG_CONFIG_HOME="$WORK/fresh/cfg" "$SCRIPT_DIR/onboard.sh" >/dev/null 2>&1; then
  bad "should exit non-zero while setup is incomplete"
else
  ok "exits non-zero while setup is incomplete"
fi

section "Globus"
says "globus-check refuses cleanly when not configured" "globus" \
     env HOME="$WORK/sandbox" XDG_CONFIG_HOME="$WORK/nocfg" "$EXP" globus-check
for c in globus-put globus-get globus-archive globus-restore globus-endpoints globus-status; do
  if grep -q "    $c)" "$EXP"; then ok "$c is dispatched"; else bad "$c is not dispatched"; fi
done
if grep -q 'globus_need_laptop' "$EXP"; then
  ok "laptop transfers check for a personal endpoint"; else bad "no personal-endpoint check"; fi
if grep -q 'A human must grant Globus consent' "$EXP"; then
  ok "consent is handed to a human, never attempted"; else bad "consent handling missing"; fi

section "Connection safety"
says "remote command refuses without a session" "no live Expanse session" \
     env XDG_CONFIG_HOME="$WORK/cfg" EXPANSE_USER=testuser "$EXP" alloc
says "the refusal names the human step" "expanse.sh login" \
     env XDG_CONFIG_HOME="$WORK/cfg" EXPANSE_USER=testuser "$EXP" alloc
says "check reports a dead session" "dead" \
     env XDG_CONFIG_HOME="$WORK/cfg" EXPANSE_USER=testuser "$EXP" check
out=$(env XDG_CONFIG_HOME="$WORK/cfg" EXPANSE_USER=testuser "$EXP" alloc >/dev/null 2>&1; echo $?)
[ "$out" = 78 ] && ok "refusal uses the documented exit code 78" || bad "expected exit 78, got $out"

section "Generated jobs are valid bash"
for f in "$WORK"/*.sbatch; do
  [ -s "$f" ] || continue
  sed -e 's|{{ACCOUNT}}|abc123|g' -e 's|{{RUN_DIR}}|/lustre/x|g' -e 's|{{NODES}}|1|g' "$f" > "$f.filled"
  bash -n "$f.filled" 2>/dev/null && ok "$(basename -- "$f")" || bad "$(basename -- "$f") is not valid bash"
done

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  cat <<'EOF'

Everything testable without a cluster passes. What still needs a real account:

  1. scripts/expanse-setup.sh          your username and allocation
  2. scripts/expanse.sh login          password + authenticator code
  3. scripts/expanse.sh alloc          proves the account and allocation resolve
  4. scripts/expanse.sh launch examples/smoke_train.py \
         --partition gpu-debug --gpus 1 --time 00:10:00
  5. same with --gpus 2                proves the distributed path

Step 4 should print a V100 name and a falling loss. Step 5 should print two rank
lines and still write exactly one checkpoint.
EOF
  exit 0
fi
exit 1
