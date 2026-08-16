#!/usr/bin/env bash
# expanse-setup.sh - one-time, human-run setup for SDSC Expanse access.
#
# Writes a per-user config, an ~/.ssh/config block with connection sharing, and
# optionally installs your SSH public key on Expanse.
#
#   scripts/expanse-setup.sh                 interactive
#   scripts/expanse-setup.sh --print-config  show what is configured now
#
# Nothing here is secret beyond your own username: the config holds no password
# and no TOTP seed.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/expanse"
CONFIG_FILE="$CONFIG_DIR/config.env"
HOST=login.expanse.sdsc.edu
CONTROL_DIR="$HOME/.ssh/cm"
CONTROL_PATH="$CONTROL_DIR/%r@%h:%p"
BEGIN="# >>> expanse-agent-skill >>>"
END="# <<< expanse-agent-skill <<<"

if [ "${1:-}" = "--print-config" ]; then
  [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || echo "no config at $CONFIG_FILE"
  exit 0
fi

echo "SDSC Expanse setup"
echo "=================="
echo

# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

read -r -p "Expanse username [${EXPANSE_USER:-}]: " in_user
EXPANSE_USER="${in_user:-${EXPANSE_USER:-}}"
[ -n "$EXPANSE_USER" ] || { echo "username is required" >&2; exit 1; }

echo
echo "Your SLURM account is the allocation/project charged for jobs (for example abc123)."
echo "If you do not know it, leave this blank; after logging in run:"
echo "    expanse-client user -r expanse"
read -r -p "SLURM account [${EXPANSE_ACCOUNT:-}]: " in_acct
EXPANSE_ACCOUNT="${in_acct:-${EXPANSE_ACCOUNT:-}}"

read -r -p "Project name used for remote directories [${EXPANSE_PROJECT:-default}]: " in_proj
EXPANSE_PROJECT="${in_proj:-${EXPANSE_PROJECT:-default}}"

read -r -p "Keep the shared session open for how long [${EXPANSE_CONTROL_PERSIST:-8h}]: " in_persist
EXPANSE_CONTROL_PERSIST="${in_persist:-${EXPANSE_CONTROL_PERSIST:-8h}}"

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

echo
read -r -p "Install your SSH public key on Expanse now? [y/N]: " want_key
if [ "${want_key:-N}" = "y" ] || [ "${want_key:-N}" = "Y" ]; then
  key=""
  for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [ -f "$cand" ] && { key="$cand"; break; }
  done
  if [ -z "$key" ]; then
    echo "no public key found; generating an ed25519 key"
    ssh-keygen -t ed25519 -C "expanse-$EXPANSE_USER" -f "$HOME/.ssh/id_ed25519"
    key="$HOME/.ssh/id_ed25519.pub"
  fi
  echo "Copying $key to Expanse. You will be asked for your password and TOTP code."
  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -i "$key" "$EXPANSE_USER@$HOST"
  else
    # shellcheck disable=SC2029
    ssh "$EXPANSE_USER@$HOST" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
      < "$key"
  fi
  echo
  echo "Note: Expanse still requires a TOTP code even with a key installed."
  echo "The key removes the password step, not the second factor."
fi

echo
echo "Setup complete. Next step, run this yourself once per working session:"
echo
echo "    $SCRIPT_DIR/expanse.sh login"
echo
echo "That opens the shared session your agent reuses. Verify with:"
echo "    $SCRIPT_DIR/expanse.sh check"
echo "    $SCRIPT_DIR/expanse.sh alloc"
