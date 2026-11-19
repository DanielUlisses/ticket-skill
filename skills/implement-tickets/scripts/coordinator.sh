#!/usr/bin/env bash
# coordinator.sh — start the project coordinator session for one project, in
# this terminal (the `tkc` alias).
#
# The project coordinator is one Claude Code session per project: it reads the
# project's repos and boards, answers agents' questions that were already
# answered (the answers ledger), brings the developer what is new, and runs
# the board work he asks for through tk.sh. Not the per-ticket coordinator
# (TICKET_COORD_*), which every ticket launch starts.
#
# The session is disposable; the project lives in files under
# $TICKET_PCOORD_HOME/<project>/ (default ~/work/.coordinators/<project>/):
#   repos        the project's main checkouts, one absolute path per line
#   state.md     the handoff the session rewrites (typing `handoff` in it)
#   journal.log  one line per event and action, appended
#   inbox/       one small JSON file per event tk-hub's daemon hands over (an
#                agent's question, a ticket that needs the developer, a ready
#                batch); the session moves what it handled to inbox/done/
#   artifacts/   files the session keeps for the developer (a report, a plan's
#                output); tk-hub's daemon sends them to the hub's Artifacts page
# Every start is a fresh conversation that reads state.md; --resume continues
# the folder's last conversation instead (one cut short by a restart).
# docs/agents/project-coordinator.md.
#
# Usage: coordinator.sh [--print|--json] [--resume] <project> [<repo>...]
#   <project>  a name for the folder: lowercase letters, digits, . _ -
#   <repo>     a repo to add to the project: a path, or a name under
#              $TICKET_WORK_DIR (default ~/work). Kept in the repos file, so
#              later starts need none. First start with none: the repo this
#              shell is in.
#   --print    print the claude command instead of running it
#   --json     the same for a program (tk-hub's daemon, which starts the session
#              as a Herdr agent): {"project","dir","prompt","args"}, args being
#              claude's arguments after the first prompt. Starts nothing
#   --resume   continue the last conversation of the folder (claude --continue)
#
# Optional variables:
#   TICKET_PCOORD_MODEL / TICKET_PCOORD_EFFORT  (default: sonnet / medium, from ticket-models.env)
#   TICKET_PCOORD_HOME        (default: ~/work/.coordinators)
#   TICKET_PCOORD_AUTOCOMPACT (optional) — Claude Code's --autocompact window; unset
#                             leaves Claude Code's own. The handoff is the intended
#                             way to shed context, so this is a backstop only
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
require_valid_effort

usage="usage: coordinator.sh [--print|--json] [--resume] <project> [<repo>...]"
print=0; resume=0; as_json=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --print) print=1 ;; --resume) resume=1 ;; --json) as_json=1; print=1 ;;
    *) die "unknown option $1 — $usage" ;;
  esac
  shift
done
PROJECT="${1:-}"; [[ -n "$PROJECT" ]] || die "$usage"; shift
[[ "$PROJECT" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || die "project name '$PROJECT' — lowercase letters, digits, . _ - (at most 64)"

SCRIPTS="$SKILL_DIR/scripts"
LAUNCHER_PATH="$(dirname "$SKILL_DIR")/ticket/scripts/launch.sh"
need git
(( ! as_json )) || need jq
(( print )) || command -v claude >/dev/null || die "claude not found in PATH"

HOME_DIR="${TICKET_PCOORD_HOME:-$HOME/work/.coordinators}"
DIR="$HOME_DIR/$PROJECT"
WORK_DIR="${TICKET_WORK_DIR:-$HOME/work}"
REPOS_FILE="$DIR/repos"

# A repo argument to its main checkout's root (never a ticket's worktree).
repo_root_of() {
  local arg="$1" path top
  if [[ -d "$arg" ]]; then path="$arg"; elif [[ -d "$WORK_DIR/$arg" ]]; then path="$WORK_DIR/$arg"
  else die "no repo '$arg' (not a directory, and not under $WORK_DIR)"; fi
  top="$(git -C "$path" worktree list --porcelain 2>/dev/null | awk 'NR==1 && /^worktree /{ sub(/^worktree /, ""); print }')"
  [[ -n "$top" ]] || die "$path is not a git repository"
  echo "$top"
}

new=()
for arg in "$@"; do new+=("$(repo_root_of "$arg")"); done
if [[ ! -s "$REPOS_FILE" && ${#new[@]} -eq 0 ]]; then
  git rev-parse --show-toplevel >/dev/null 2>&1 \
    || die "project '$PROJECT' has no repos yet — name them once: tkc $PROJECT <repo>... (or run it inside one)"
  new+=("$(repo_root_of "$PWD")")
fi

mkdir -p "$DIR" "$DIR/inbox/done" "$DIR/artifacts"
touch "$REPOS_FILE" "$DIR/journal.log"
for r in ${new[@]+"${new[@]}"}; do
  grep -qxF -- "$r" "$REPOS_FILE" || { echo "$r" >>"$REPOS_FILE"; log "project $PROJECT: added $r"; }
done
REPOS=()
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  if [[ -d "$r/.git" || -f "$r/.git" ]]; then REPOS+=("$r"); else log "warning: $r (in $REPOS_FILE) is not a repo any more — left out"; fi
done <"$REPOS_FILE"
(( ${#REPOS[@]} )) || die "none of the repos in $REPOS_FILE exist — edit it, or name the repos again"

if [[ ! -s "$DIR/state.md" ]]; then
  cat >"$DIR/state.md" <<STATE
# $PROJECT — state

Written by the project coordinator at each handoff; rewritten, never appended.
First start: nothing here yet. Read the boards and build it.

## Open loops

## Decided this week

## Watch next

## Queue

## Notes for the next session
STATE
fi

repo_lines=""
for r in "${REPOS[@]}"; do
  boards="$(find "$r/.scratch" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f ' 2>/dev/null || true)"
  repo_lines+="- \`$r\` — boards: ${boards:-none yet}"$'\n'
done

PROMPT="$DIR/.brief.md"
tpl="$(cat "$SKILL_DIR/templates/project-coordinator-prompt.md")"
tpl="${tpl//'{{PROJECT}}'/"$PROJECT"}"
tpl="${tpl//'{{DIR}}'/"$DIR"}"
tpl="${tpl//'{{TK}}'/"$SCRIPTS/tk.sh"}"
tpl="${tpl//'{{MERGER}}'/"$SCRIPTS/merge-conflict.sh"}"
fill_prose '{{REPOS}}' "${repo_lines%$'\n'}"
printf '%s\n' "$tpl" >"$PROMPT"

build_session_agents ticket-merger ticket-pr-creator ticket-scout ticket-researcher

first="Start as the project coordinator of ${PROJECT}: follow 'Every start' in your instructions."
(( resume )) && first="You were restarted. Read state.md and journal.log's last lines, run the digests again, and carry on: tell me only what changed."
cmd=(claude "$first"
     --model "$PCOORD_MODEL" --effort "$PCOORD_EFFORT"
     --strict-mcp-config
     --append-system-prompt-file "$PROMPT")
(( resume )) && cmd+=(--continue)
[[ -n "${TICKET_PCOORD_AUTOCOMPACT:-}" ]] && cmd+=(--autocompact "$TICKET_PCOORD_AUTOCOMPACT")
for r in "${REPOS[@]}"; do cmd+=(--add-dir "$r"); done
[[ -n "$SESSION_AGENTS_JSON" ]] && cmd+=(--agents "$SESSION_AGENTS_JSON")
# Its own scripts run without a prompt each time; anything else asks.
cmd+=(--allowedTools "Bash($SCRIPTS/tk.sh *)" "Bash($LAUNCHER_PATH *)" "Bash($SCRIPTS/merge-conflict.sh *)" "Bash($SCRIPTS/pr-open.sh *)")

log "project coordinator $PROJECT on $PCOORD_MODEL @ $PCOORD_EFFORT — ${#REPOS[@]} repo(s), folder $DIR — subagents: $SESSION_AGENTS_STATUS"
if (( as_json )); then
  jq -cn --arg project "$PROJECT" --arg dir "$DIR" --arg prompt "$first" '{project: $project, dir: $dir, prompt: $prompt, args: $ARGS.positional}' --args -- "${cmd[@]:2}"
  exit 0
fi
if (( print )); then printf '%q ' "${cmd[@]}"; echo; exit 0; fi
cd "$DIR"
exec "${cmd[@]}"
