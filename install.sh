#!/usr/bin/env bash
# Installs the /ticket, /small-ticket and /implement-tickets skills and their shared subagents
#
# Usage: ./install.sh [dest ...]   (default: ~/.claude)
# Each dest is a Claude config root, e.g. ~/.claude or ~/.claude-switch/accounts/<name>
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTS=("$@")
[[ ${#DESTS[@]} -gt 0 ]] || DESTS=("$HOME/.claude")

for DEST in "${DESTS[@]}"; do
  DEST_SKILLS="$DEST/skills"
  DEST_AGENTS="$DEST/agents"
  mkdir -p "$DEST_SKILLS" "$DEST_AGENTS"

  # /implement-tickets ships no scripts or templates of its own — it reuses /ticket's launcher
  for skill in small-ticket ticket implement-tickets; do
    mkdir -p "$DEST_SKILLS/$skill"
    cp "$SRC/skills/$skill/SKILL.md" "$DEST_SKILLS/$skill/"
    for dir in scripts templates; do
      [[ -d "$SRC/skills/$skill/$dir" ]] || continue
      cp -r "$SRC/skills/$skill/$dir" "$DEST_SKILLS/$skill/"
    done
    if [[ -f "$DEST_SKILLS/$skill/scripts/launch.sh" ]]; then
      chmod +x "$DEST_SKILLS/$skill/scripts/launch.sh"
    fi
  done
  cp "$SRC"/agents/*.md "$DEST_AGENTS/"

  # config/models.env is shared by all three skills' launch.sh, one level up from
  # the individual skill dirs — never overwrite a destination copy the developer
  # has hand-edited, since that's the whole point of a per-machine override.
  MODELS_SRC="$SRC/config/models.env"
  MODELS_DEST="$DEST_SKILLS/ticket-models.env"
  if [[ ! -f "$MODELS_SRC" ]]; then
    echo "warning: $MODELS_SRC not found — skipping model config install (skills/agents were still installed)"
  elif [[ ! -f "$MODELS_DEST" ]]; then
    cp "$MODELS_SRC" "$MODELS_DEST"
    echo "installed: $MODELS_DEST"
  elif ! cmp -s "$MODELS_SRC" "$MODELS_DEST"; then
    echo "warning: $MODELS_DEST differs from $MODELS_SRC — keeping the destination copy (hand-edited config is never overwritten)"
  fi

  echo "installed: $DEST_SKILLS/{small-ticket,ticket,implement-tickets} and $DEST_AGENTS/ticket-*.md"
done

for cmd in herdr git jq gh; do
  command -v "$cmd" >/dev/null || echo "warning: '$cmd' not found in PATH"
done
bash -ic 'type ga >/dev/null 2>&1' || echo "warning: Omarchy's 'ga' function not found in interactive bash"
