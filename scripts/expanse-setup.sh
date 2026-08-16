#!/usr/bin/env bash
# expanse-setup.sh - one-time setup for SDSC Expanse access.
#
# Writes a per-user config, an ~/.ssh/config block with connection sharing, and
# optionally installs your SSH public key on Expanse.
#
# Interactive (asks for anything missing):
#   scripts/expanse-setup.sh
#
# Non-interactive (for a non-tty shell, an agent, or scripted setup):
#   scripts/expanse-setup.sh --user <username> --account <alloc> --project <label>
#
# Options:
#   --user NAME        your SDSC Expanse login name        (required)
#   --account ALLOC    SLURM allocation charged for jobs   (optional; add later)
#   --project LABEL    namespaces your remote directories  (default: default)
#   --persist DUR      how long a login stays shared       (default: 8h)
#   --install-key      also copy your SSH public key to Expanse (needs a terminal)
#   --print-config     show the current config and exit
#
# Nothing secret is stored: no password and no authenticator seed.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/expanse"
CONFIG_FILE="$CONFIG_DIR/config.env"
HOST=login.expanse.sdsc.edu
CONTROL_DIR="$HOME/.ssh/cm"
CONTROL_PATH="$CONTROL_DIR/%r@%h:%p"
BEGIN="# >>> expanse-agent-skill >>>"
END="# <<< expanse-agent-skill <<<"

IN_USER=""; IN_ACCT=""; IN_PROJ=""; IN_PERSIST=""; INSTALL_KEY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user)         IN_USER="${2:?--user needs a value}"; shift 2 ;;
    --account)      IN_ACCT="${2:?--account needs a value}"; shift 2 ;;
    --project)      IN_PROJ="${2:?--project needs a value}"; shift 2 ;;
    --persist)      IN_PERSIST="${2:?--persist needs a value}"; shift 2 ;;
    --install-key)  INSTALL_KEY=1; shift ;;
    --print-config)
      [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || echo "no config at $CONFIG_FILE"
      exit 0 ;;
    -h|--help)
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

# Carry forward anything already configured.
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

interactive=0
[ -t 0 ] && [ -t 1 ] && interactive=1

ask() { # ask <prompt> <current> -> echoes the answer
  local prompt="$1" current="${2:-}" reply=""
  if [ "$interactive" = 1 ]; then
    read -r -p "$prompt [${current}]: " reply </dev/tty || true
  fi
  printf '%s' "${reply:-$current}"
}

if [ "$interactive" = 1 ]; then
  echo "SDSC Expanse setup"
  echo "=================="
  echo
fi

EXPANSE_USER="${IN_USER:-$(ask "Expanse username" "${EXPANSE_USER:-}")}"
if [ -z "$EXPANSE_USER" ]; then
  cat >&2 <<EOF
error: no Expanse username.

This shell is not interactive, so nothing could be asked. Pass the values
directly instead:

    $SCRIPT_DIR/expanse-setup.sh --user <your-username> [--account <alloc>] [--project <label>]

Your username is your SDSC login name. The account is the allocation charged for
jobs (something like abc123); leave it out if you do not know it yet and run
'expanse alloc' after your first login.
EOF
  exit 1
fi

if [ "$interactive" = 1 ] && [ -z "$IN_ACCT" ]; then
  echo
  echo "Your SLURM account is the allocation charged for jobs (for example abc123)."
  echo "If you do not know it, leave this blank; after logging in run:"
  echo "    expanse-client user -r expanse"
fi
EXPANSE_ACCOUNT="${IN_ACCT:-$(ask "SLURM account" "${EXPANSE_ACCOUNT:-}")}"
EXPANSE_PROJECT="${IN_PROJ:-$(ask "Project name for remote directories" "${EXPANSE_PROJECT:-default}")}"
EXPANSE_CONTROL_PERSIST="${IN_PERSIST:-$(ask "Keep the shared session open for" "${EXPANSE_CONTROL_PERSIST:-8h}")}"
EXPANSE_PROJECT="${EXPANSE_PROJECT:-default}"
EXPANSE_CONTROL_PERSIST="${EXPANSE_CONTROL_PERSIST:-8h}"

mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
# SDSC Expanse - written by expanse-setup.sh
EXPANSE_USER=$EXPANSE_USER
EXPANSE_ACCOUNT=$EXPANSE_ACCOUNT
EXPANSE_PROJECT=$EXPANSE_PROJECT
EXPANSE_HOST=$HOST
EXPANSE_CONTROL_PERSIST=$EXPANSE_CONTROL_PERSIST
EXPANSE_CONTROL_PATH=$CONTROL_PATH
EOF
chmod 600 "$CONFIG_FILE"
echo "wrote $CONFIG_FILE"

mkdir -p "$CONTROL_DIR"; chmod 700 "$CONTROL_DIR"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"

# Idempotent ssh config block.
tmp=$(mktemp)
awk -v b="$BEGIN" -v e="$END" '
  $0 == b {skip=1} !skip {print} $0 == e {skip=0}
' "$HOME/.ssh/config" > "$tmp"
cat >> "$tmp" <<EOF
$BEGIN
Host expanse
    HostName $HOST
    User $EXPANSE_USER
    ControlMaster auto
    ControlPath $CONTROL_PATH
    ControlPersist $EXPANSE_CONTROL_PERSIST
    ServerAliveInterval 60
    ServerAliveCountMax 5
$END
EOF
mv "$tmp" "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
echo "updated ~/.ssh/config (Host expanse)"

want_key=0
if [ "$INSTALL_KEY" = 1 ]; then
  want_key=1
elif [ "$interactive" = 1 ]; then
  echo
  read -r -p "Install your SSH public key on Expanse now? [y/N]: " reply </dev/tty || true
  case "${reply:-N}" in y|Y) want_key=1 ;; esac
fi

if [ "$want_key" = 1 ]; then
  key=""
  for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [ -f "$cand" ] && { key="$cand"; break; }
  done
  if [ -z "$key" ]; then
    echo "no public key found; generating an ed25519 key"
    ssh-keygen -t ed25519 -C "expanse-$EXPANSE_USER" -f "$HOME/.ssh/id_ed25519" -N ""
    key="$HOME/.ssh/id_ed25519.pub"
  fi
  echo "Copying $key to Expanse. You will be asked for your password and code."
  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -i "$key" "$EXPANSE_USER@$HOST"
  else
    # shellcheck disable=SC2029
    ssh "$EXPANSE_USER@$HOST" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
      < "$key"
  fi
  echo
  echo "Note: Expanse still requires a 6-digit code even with a key installed."
  echo "The key removes the password step, not the second factor."
fi

cat <<EOF

Configured for user '$EXPANSE_USER'${EXPANSE_ACCOUNT:+, account '$EXPANSE_ACCOUNT'}.

Next, in a real terminal (this step needs your password and 6-digit code):

    expanse login

Then verify:

    expanse check
    expanse alloc
EOF
