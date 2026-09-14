#!/usr/bin/env bash
# Installs the /ticket and /small-ticket skills and their shared subagents
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$HOME/.claude}"
DEST_SKILLS="$DEST/skills"
DEST_AGENTS="$DEST/agents"

mkdir -p "$DEST_SKILLS" "$DEST_AGENTS"
for skill in small-ticket ticket; do
  mkdir -p "$DEST_SKILLS/$skill"
  cp -r "$SRC/skills/$skill/SKILL.md" "$SRC/skills/$skill/scripts" "$SRC/skills/$skill/templates" "$DEST_SKILLS/$skill/"
  chmod +x "$DEST_SKILLS/$skill/scripts/launch.sh"
done
cp "$SRC"/agents/*.md "$DEST_AGENTS/"

for cmd in herdr git jq; do
  command -v "$cmd" >/dev/null || echo "warning: '$cmd' not found in PATH"
done
bash -ic 'type ga >/dev/null 2>&1' || echo "warning: Omarchy's 'ga' function not found in interactive bash"

echo "installed: $DEST_SKILLS/{small-ticket,ticket} and $DEST_AGENTS/ticket-*.md"
