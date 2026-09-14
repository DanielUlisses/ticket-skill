#!/usr/bin/env bash
# Installs the /ticket skill and its subagents into a Claude Code install dir
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$HOME/.claude}"
DEST_SKILL="$DEST/skills/ticket"
DEST_AGENTS="$DEST/agents"

mkdir -p "$DEST_SKILL" "$DEST_AGENTS"
cp -r "$SRC/SKILL.md" "$SRC/scripts" "$SRC/templates" "$DEST_SKILL/"
cp "$SRC"/agents/*.md "$DEST_AGENTS/"
chmod +x "$DEST_SKILL/scripts/launch.sh"

for cmd in herdr git jq; do
  command -v "$cmd" >/dev/null || echo "warning: '$cmd' not found in PATH"
done
bash -ic 'type ga >/dev/null 2>&1' || echo "warning: Omarchy's 'ga' function not found in interactive bash"

echo "installed: $DEST_SKILL and $DEST_AGENTS/ticket-*.md"
