#!/usr/bin/env bash
# install.sh - make this skill available to your agent, from any directory.
#
#   scripts/install.sh            install for the current user
#   scripts/install.sh --project  also install into ./.claude and ./.agents here
#   scripts/install.sh --check    report what is installed, change nothing
#
# Two things get installed:
#   1. an `expanse` command on your PATH, so the driver works from any working
#      directory - agents run in your project, not in this repo
#   2. skill symlinks so Claude Code (and AGENTS.md-reading agents) discover it
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
BIN_DIR="${EXPANSE_BIN_DIR:-$HOME/.local/bin}"
CLAUDE_SKILLS="$HOME/.claude/skills"
AGENT_SKILLS="$HOME/.agents/skills"
NAME=sdsc-expanse

say() { printf '%s\n' "$*"; }
link() { # link <target> <linkname>
  local target="$1" name="$2"
  mkdir -p "$(dirname -- "$name")"
  if [ -L "$name" ]; then
    if [ "$(readlink "$name")" = "$target" ]; then say "  already linked: $name"; return; fi
    rm -f "$name"
  elif [ -e "$name" ]; then
    say "  SKIPPED (exists and is not a symlink): $name"; return
  fi
  ln -s "$target" "$name"; say "  linked: $name -> $target"
}

if [ "${1:-}" = "--check" ]; then
  say "repo:          $REPO_DIR"
  say "expanse on PATH: $(command -v expanse || echo 'NO')"
  for p in "$CLAUDE_SKILLS/$NAME" "$AGENT_SKILLS/$NAME"; do
    [ -e "$p" ] && say "skill link:    $p -> $(readlink "$p" 2>/dev/null || echo '(not a link)')" \
                || say "skill link:    $p MISSING"
  done
  exit 0
fi

chmod +x "$SCRIPT_DIR"/*.sh "$REPO_DIR"/examples/*.py 2>/dev/null || true

say "Installing the expanse command"
link "$SCRIPT_DIR/expanse.sh" "$BIN_DIR/expanse"

case ":$PATH:" in
  *":$BIN_DIR:"*) say "  $BIN_DIR is on your PATH" ;;
  *)
    say ""
    say "  WARNING: $BIN_DIR is not on your PATH. Add this to your shell profile:"
    say ""
    say "      export PATH=\"\$HOME/.local/bin:\$PATH\""
    say ""
    say "  Until then, agents must use the full path: $SCRIPT_DIR/expanse.sh"
    ;;
esac

say ""
say "Installing skill links"
link "$REPO_DIR" "$CLAUDE_SKILLS/$NAME"
link "$REPO_DIR" "$AGENT_SKILLS/$NAME"

if [ "${1:-}" = "--project" ]; then
  say ""
  say "Installing into this project ($PWD)"
  link "$REPO_DIR" "$PWD/.claude/skills/$NAME"
  link "$REPO_DIR" "$PWD/.agents/skills/$NAME"
fi

cat <<EOF

Done. Verify with:

    scripts/install.sh --check
    expanse --help
    scripts/selftest.sh

Then set up your account and open a session:

    scripts/expanse-setup.sh
    expanse login
EOF
