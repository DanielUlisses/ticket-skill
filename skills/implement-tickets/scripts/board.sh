#!/usr/bin/env bash
# board.sh — start the board session for one board, in this Herdr tab.
#
# The board session is bookkeeping: launching waves, merging on the developer's
# word, relaying messages, resolving what landed. Every check is in tk.sh, so
# the model only reads results and decides — which is what lets it run on Haiku.
# Haiku is cheap only while the prompt stays small (it reprices above 100K
# tokens), so this starts Claude Code with exactly what the board needs: a short
# appended prompt, the tools it and its agents use, no MCP servers, no skill listing, the four
# agents it dispatches, and auto-compaction before the price step.
# See docs/adr/0004-haiku-board-session.md.
#
# Usage: board.sh [<board>]     (a Jira id or slug under .scratch/, a path; empty = the only one there)
#        board.sh --print [<board>]   print the claude command instead of running it
#
# Optional variables:
#   TICKET_BOARD_MODEL / TICKET_BOARD_EFFORT  (default: haiku / low, from ticket-models.env)
#   TICKET_BOARD_AUTOCOMPACT  (default: 100k) — Claude Code's --autocompact window
#   TICKET_BOARD_SKILLS       (default: 0) — 1 keeps skills (and their listing in the prompt)
#   TICKET_SESSION_AGENTS     (default: 1) — 0 leaves the dispatched agents on their frontmatter
#   TICKET_BOARD_VIEW         (default: 30) — seconds between refreshes of the status board the
#                             session opens beside itself (tk.sh view --watch); 0 opens none
#   TICKET_BOARD_VIEW_PLACEMENT (default: tab) — tab: a `tickets` tab of its own, full width;
#                             right / down: a pane split off the board session (Herdr splits only
#                             right or down, so a split always sits beside or below it)
#   TICKET_BOARD_VIEW_RATIO   (optional) — passed to `herdr pane split --ratio` for the split
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
tpl="${tpl//'{{PR}}'/"$SCRIPTS/pr-open.sh"}"
tpl="${tpl//'{{LAUNCHER}}'/"$LAUNCHER_PATH"}"
printf '%s\n' "$tpl" >"$PROMPT"

build_session_agents ticket-merger ticket-pr-creator ticket-retro ticket-researcher

# The prompt goes first: --tools and --allowedTools take lists, and a positional
# after either is swallowed as one more entry — the session would open idle.
cmd=(claude "Run the board ${BOARD_ID}: start with the first turn."
     --model "$BOARD_MODEL" --effort "$BOARD_EFFORT"
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
cmd+=(--allowedTools "Bash($SCRIPTS/tk.sh *)" "Bash($LAUNCHER_PATH *)" "Bash($SCRIPTS/merge-conflict.sh *)" "Bash($SCRIPTS/pr-open.sh *)")

# The status board beside the board session: tk.sh view, refreshing itself — a
# script, not a model, so it costs nothing to leave open. By default a `tickets`
# tab of its own — the full width fits the most columns; TICKET_BOARD_VIEW_PLACEMENT
# =right or =down splits this pane instead (`--current` resolves it from
# HERDR_PANE_ID). A refused split falls back to the tab. Best effort: where this
# Herdr can do neither, say what to run.
open_view() {
  local every="${TICKET_BOARD_VIEW:-30}" view_cmd json pane="" how place="${TICKET_BOARD_VIEW_PLACEMENT:-tab}"
  [[ "$place" == split ]] && place=right   # the earlier name for it
  [[ "$every" =~ ^[0-9]+$ && "$every" -gt 0 ]] || return 0
  view_cmd="$SCRIPTS/tk.sh view $(printf '%q' "$BOARD_ID") --watch $every"
  if [[ "${HERDR_ENV:-}" == 1 ]] && command -v herdr >/dev/null 2>&1; then
    if [[ "$place" =~ ^(right|down)$ && -n "${HERDR_PANE_ID:-}" ]]; then
      local split=(pane split --current --direction "$place" --cwd "$ROOT" --no-focus)
      [[ -n "${TICKET_BOARD_VIEW_RATIO:-}" ]] && split+=(--ratio "$TICKET_BOARD_VIEW_RATIO")
      json="$(herdr "${split[@]}" 2>/dev/null)" && pane="$(jq -r '.result.pane.pane_id // .result.pane.id // empty' <<<"$json")"
      how="a pane split $place"
    fi
    if [[ -z "$pane" ]]; then
      local create=(tab create --cwd "$ROOT" --label tickets)
      has_flag --no-focus tab create && create+=(--no-focus)
      json="$(herdr "${create[@]}" 2>/dev/null)" \
        && pane="$(jq -r '.result.root_pane.pane_id // .result.root_pane.id // .result.tab.root_pane.pane_id // empty' <<<"$json")"
      how="a 'tickets' tab"
    fi
    if [[ -n "$pane" ]] && herdr pane run "$pane" "$view_cmd" >/dev/null 2>&1; then
      log "status board opened in $how (pane $pane)"
      return 0
    fi
  fi
  log "couldn't open the status board — in any pane at $ROOT, run: $view_cmd"
}

log "board $BOARD_ID on $BOARD_MODEL @ $BOARD_EFFORT — subagents: $SESSION_AGENTS_STATUS"
if (( print )); then printf '%q ' "${cmd[@]}"; echo; exit 0; fi
open_view
cd "$ROOT"
exec "${cmd[@]}"
