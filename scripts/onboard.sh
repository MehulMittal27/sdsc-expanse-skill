#!/usr/bin/env bash
# onboard.sh - guided first-time setup for SDSC Expanse.
#
# Run it as many times as you like. It checks every prerequisite, shows what is
# done and what is not, and prints the ONE next thing to do. Nothing is changed
# without asking, apart from installing the CLI helpers.
#
#   scripts/onboard.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/expanse/config.env"
EXP="$SCRIPT_DIR/expanse.sh"

b=$'\033[1m'; g=$'\033[32m'; y=$'\033[33m'; r=$'\033[31m'; n=$'\033[0m'
yes()  { printf '  %sdone%s   %s\n' "$g" "$n" "$1"; }
no()   { printf '  %stodo%s   %s\n' "$y" "$n" "$1"; }
bad()  { printf '  %smissing%s %s\n' "$r" "$n" "$1"; }
head_() { printf '\n%s%s%s\n' "$b" "$1" "$n"; }
NEXT=""
next() { [ -z "$NEXT" ] && NEXT="$1"; }

printf '%s\n' "${b}SDSC Expanse - setup check${n}"
printf 'skill: %s\n' "$REPO_DIR"

# ---------------------------------------------------------------- 1. tools
head_ "1. Tools on this machine"
for t in ssh rsync python3 git; do
  command -v "$t" >/dev/null 2>&1 && yes "$t" || { bad "$t - install it first"; next "install $t"; }
done
if [ -x "$HOME/.local/bin/expanse" ] || command -v expanse >/dev/null 2>&1; then
  yes "the 'expanse' command is installed"
else
  no "the 'expanse' command is not on your PATH"
  next "$SCRIPT_DIR/install.sh"
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) yes "~/.local/bin is on your PATH" ;;
  *) no "~/.local/bin is not on your PATH - add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# --------------------------------------------------- 2. account (needs a human)
head_ "2. Your SDSC account  ${n}(you cannot skip these; ask the project owner)"
cat <<'EOF'
  You need, from whoever runs the allocation:
    - to be added to the ACCESS allocation (they do this; it can take hours to
      days to reach Expanse, and logins fail until it lands)
    - the allocation/project code to charge jobs to, e.g. abc123
    - your Expanse username, if it differs from your ACCESS username
  And you need to do yourself:
    - enrol in two-factor auth at https://passive.sdsc.edu
      (sign in with Globus/ACCESS, "Manage 2FA", scan the QR into an
       authenticator app). Changes take up to 15 minutes to take effect.
EOF

# ------------------------------------------------------------- 3. skill config
head_ "3. Skill configuration"
if [ -f "$CONFIG" ]; then
  u=$(grep '^EXPANSE_USER=' "$CONFIG" | cut -d= -f2)
  a=$(grep '^EXPANSE_ACCOUNT=' "$CONFIG" | cut -d= -f2)
  p=$(grep '^EXPANSE_PROJECT=' "$CONFIG" | cut -d= -f2)
  [ -n "$u" ] && yes "username: $u" || { no "no username"; next "$SCRIPT_DIR/expanse-setup.sh"; }
  [ -n "$a" ] && yes "allocation: $a" || no "no allocation yet - 'expanse alloc' will show it after your first login"
  [ -n "$p" ] && yes "project label: $p"
else
  no "not configured"
  next "$SCRIPT_DIR/expanse-setup.sh --user <your-username> [--account <alloc>]"
fi

# ------------------------------------------------------------------ 4. session
head_ "4. Connection to Expanse"
if "$EXP" check >/dev/null 2>&1; then
  yes "session is live - jobs can run"
  if "$EXP" alloc >/dev/null 2>&1; then yes "allocation is readable"; else no "could not read your allocation"; fi
else
  no "no live session"
  next "expanse login   (asks for your password and 6-digit code; only you can do this)"
fi

# ------------------------------------------------------------------- 5. globus
head_ "5. Globus  ${n}(optional; needed only for datasets over a few GB)"
if command -v globus >/dev/null 2>&1; then
  yes "globus CLI installed"
  if globus whoami >/dev/null 2>&1; then
    yes "logged in as $(globus whoami 2>/dev/null)"
    if "$EXP" globus-check >/dev/null 2>&1; then
      yes "Expanse collections found and consented"
    else
      no "endpoints or consent missing - run: expanse globus-check  (it prints the exact command)"
    fi
    # Globus Connect Personal registers THIS MACHINE. Without it, transfers
    # to and from this laptop are impossible - only server-to-server works.
    GLOBUS_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/expanse/globus.env"
    if grep -q '^GLOBUS_LAPTOP=.' "$GLOBUS_CFG" 2>/dev/null; then
      yes "this machine is a Globus endpoint"
    else
      no "this machine is not a Globus endpoint yet"
      printf '         Needed only to move data between THIS laptop and Expanse.\n'
      printf '         Endpoints are per machine, so every laptop needs its own.\n\n'
      printf '           1. install Globus Connect Personal:\n'
      printf '              https://www.globus.org/globus-connect-personal\n'
      printf '           2. open it, sign in, and give the endpoint a name\n'
      printf '           3. run: expanse globus-endpoints\n\n'
      printf '         Note: it shares your HOME DIRECTORY and nothing else by\n'
      printf '         default. Files elsewhere (/tmp included) fail with\n'
      printf '         "Path not allowed" - keep transferable data under ~\n'
    fi
  else
    no "not logged in - run: globus login"
  fi
else
  no "globus CLI not installed (only needed for big data):"
  printf '         python3 -m venv ~/.local/globus-venv\n'
  printf '         ~/.local/globus-venv/bin/pip install globus-cli\n'
  printf '         ln -sf ~/.local/globus-venv/bin/globus ~/.local/bin/globus\n'
fi

# ------------------------------------------------------------------ 6. verdict
head_ "Next step"
if [ -n "$NEXT" ]; then
  printf '  %s\n' "$NEXT"
  printf '\nRun this script again afterwards.\n'
  exit 1
fi

cat <<'EOF'
  Everything is ready. Prove it with a real job (a few minutes, debug queue):

    expanse launch <skill>/examples/smoke_train.py \
        --partition gpu-debug --gpus 1 --time 00:10:00 --conda torch

  Then day to day:

    expanse launch ./train.py --gpus 1 --time 04:00:00 --conda myenv
    expanse status                 # what is queued or running
    expanse logs <jobid>           # output
    expanse globus-archive outputs # SAVE RESULTS - scratch is purged after 90 days
    expanse globus-get outputs ./results

  Read SKILL.md for the full workflow, reference/ for partitions, storage,
  software and Globus. If you use an AI agent, the skill is already installed
  for it - just ask for what you want in plain language.
EOF
