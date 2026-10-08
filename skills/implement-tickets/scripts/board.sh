#!/usr/bin/env bash
# board.sh — start the board session for one board, in this Herdr tab.
#
# The board session is bookkeeping: launching waves, merging on the developer's
# word, relaying messages, resolving what landed. Every check is in tk.sh, so
# the model only reads results and decides — which is what lets it run on Haiku.
# Haiku is cheap only while the prompt stays small (it reprices above 100K
# tokens), so this starts Claude Code with exactly what the board needs: a short
# appended prompt, the tools it and its agents use, no MCP servers, no skill listing, the three
# agents it dispatches, and auto-compaction before the price step.
# See docs/adr/0004-haiku-board-session.md.
#
# Usage: board.sh [<board>]     (a Jira id, a slug, ticket:<slug>, a .scratch path; empty = auto)
#        board.sh --print [<board>]   print the claude command instead of running it
#
# Optional variables:
#   TICKET_BOARD_MODEL / TICKET_BOARD_EFFORT  (default: haiku / low, from ticket-models.env)
#   TICKET_BOARD_AUTOCOMPACT  (default: 100k) — Claude Code's --autocompact window
#   TICKET_BOARD_SKILLS       (default: 0) — 1 keeps skills (and their listing in the prompt)
#   TICKET_SESSION_AGENTS     (default: 1) — 0 leaves the dispatched agents on their frontmatter
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${TICKET_LIB_DIR:-}" ]]; then LIB_DIR="$TICKET_LIB_DIR"; else
  for d in "$(dirname "$SKILL_DIR")" "$(dirname "$(dirname "$SKILL_DIR")")/lib"; do
    [[ -f "$d/ticket-git-repo.sh" ]] && { LIB_DIR="$d"; break; }
  done
fi
for lib in ticket-git-repo.sh ticket-account.sh ticket-launcher.sh; do
  [[ -f "${LIB_DIR:-}/$lib" ]] || { echo "ERROR: shared library $lib not found — re-run install.sh, or set TICKET_LIB_DIR" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$LIB_DIR/$lib"
done
load_ticket_models
COORDINATOR=config
require_valid_effort

print=0; [[ "${1:-}" == --print ]] && { print=1; shift; }
BOARD="${1:-}"
SCRIPTS="$SKILL_DIR/scripts"
LAUNCHER_PATH="$(dirname "$SKILL_DIR")/ticket/scripts/launch.sh"

need git; need jq
command -v claude >/dev/null || die "claude not found in PATH"
[[ "${HERDR_ENV:-}" == 1 ]] || log "warning: not inside a Herdr pane — the board can read and merge, but launching tickets needs Herdr"
resolve_repo_root

# Resolve the board now, so a typo fails here rather than as the session's first turn.
REMOTE="${TICKET_REMOTE:-origin}"
# shellcheck source=/dev/null
source "$SCRIPTS/board-lib.sh"
resolve_base_branch
resolve_board "$BOARD"

RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/ticket-board"; mkdir -p "$RUN_DIR"
PROMPT="$RUN_DIR/$BOARD_SLUG.prompt.md"
tpl="$(cat "$SKILL_DIR/templates/board-prompt.md")"
tpl="${tpl//'{{BOARD}}'/"$BOARD_ID"}"
tpl="${tpl//'{{TK}}'/"$SCRIPTS/tk.sh"}"
tpl="${tpl//'{{MERGER}}'/"$SCRIPTS/merge-conflict.sh"}"
tpl="${tpl//'{{LAUNCHER}}'/"$LAUNCHER_PATH"}"
printf '%s\n' "$tpl" >"$PROMPT"

build_session_agents ticket-merger ticket-memory-curator ticket-researcher

cmd=(claude --model "$BOARD_MODEL" --effort "$BOARD_EFFORT"
     # The board itself uses Bash, Read, Write, Agent and AskUserQuestion; the rest
     # are there because the agents it dispatches need them (the merger edits,
     # the researcher fetches) and a session's tool set may bound its subagents'.
     --tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Agent,AskUserQuestion"
     --strict-mcp-config
     --append-system-prompt-file "$PROMPT"
     --autocompact "${TICKET_BOARD_AUTOCOMPACT:-100k}")
[[ "${TICKET_BOARD_SKILLS:-0}" == 1 ]] || cmd+=(--disable-slash-commands)
[[ -n "$SESSION_AGENTS_JSON" ]] && cmd+=(--agents "$SESSION_AGENTS_JSON")
# The board's own scripts run without a prompt each time; anything else asks.
cmd+=(--allowedTools "Bash($SCRIPTS/tk.sh *)" "Bash($LAUNCHER_PATH *)" "Bash($SCRIPTS/merge-conflict.sh *)")
cmd+=("Run the board ${BOARD_ID}: start with the first turn.")

log "board $BOARD_ID ($BOARD_KIND) on $BOARD_MODEL @ $BOARD_EFFORT — subagents: $SESSION_AGENTS_STATUS"
if (( print )); then printf '%q ' "${cmd[@]}"; echo; exit 0; fi
cd "$ROOT"
exec "${cmd[@]}"
