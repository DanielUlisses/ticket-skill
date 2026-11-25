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
#                batch); the session moves what it handled to inbox/done/. It
#                hears of them through coordinator-inbox.sh: a watcher it runs in
#                the background, and a hook on each of the developer's messages
#                (.settings.json here), so nothing is typed into its terminal
#   wakes.json   the session's own wakes ("check the deploy in 20 minutes",
#                "every weekday at 08:30"), set through wake.sh and fired into
#                inbox/ by the watcher
#   artifacts/   files the session keeps for the developer (a report, a plan's
#                output); tk-hub's daemon sends them to the hub's Artifacts page
# Every start is a fresh conversation that reads state.md; --resume continues
# the folder's last conversation instead (one cut short by a restart).
# docs/agents/project-coordinator.md.
#
# Usage: coordinator.sh [--print|--json] [--resume] [--runner] <project> [<repo>...]
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
#   --runner   run it through the box runner (devboxes' devbox-run) as session
#              pc-<project>, detached, instead of in this terminal: a fresh start,
#              or with --resume the runner's resume of its last conversation (a
#              note tells it to start the inbox watcher again). Nothing recycles
#              it. With --json: the arguments for `devbox-run start` (no
#              --settings: the inbox hook goes in the folder's
#              .claude/settings.local.json, so the runner's own hooks stay), plus
#              "session" and "resume_note". docs/agents/short-loop.md, The
#              coordinator under the runner
#
# Optional variables:
#   TICKET_PCOORD_MODEL / TICKET_PCOORD_EFFORT  (default: sonnet / medium, from ticket-models.env)
#   TICKET_THREAD_MODEL / TICKET_THREAD_EFFORT  (default: opus / medium) — the threads it opens
#                             with thread.sh; written to <folder>/thread.env on every start
#                             and resume, so a resumed session's next thread picks them up
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

usage="usage: coordinator.sh [--print|--json] [--resume] [--runner] <project> [<repo>...]"
print=0; resume=0; as_json=0; runner=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --print) print=1 ;; --resume) resume=1 ;; --json) as_json=1; print=1 ;; --runner) runner=1 ;;
    *) die "unknown option $1 — $usage" ;;
  esac
  shift
done
PROJECT="${1:-}"; [[ -n "$PROJECT" ]] || die "$usage"; shift
[[ "$PROJECT" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || die "project name '$PROJECT' — lowercase letters, digits, . _ - (at most 64)"

SCRIPTS="$SKILL_DIR/scripts"
LAUNCHER_PATH="$(dirname "$SKILL_DIR")/ticket/scripts/launch.sh"
need git
need jq
(( print )) || command -v claude >/dev/null || die "claude not found in PATH"
RUNNER="${TICKET_RUNNER:-devbox-run}"
(( ! runner || print )) || command -v "$RUNNER" >/dev/null || die "the box runner '$RUNNER' isn't installed (devboxes' bin/devbox-run)"
# The runner's name for it: devbox-run takes letters, digits, _ and -, at most 63.
SESSION="pc-${PROJECT//./-}"; SESSION="${SESSION:0:63}"

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

repo_lines=""; short_boards=""
for r in "${REPOS[@]}"; do
  boards="$(find "$r/.scratch" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f ' 2>/dev/null || true)"
  repo_lines+="- \`$r\` — boards: ${boards:-none yet}"$'\n'
  # A board marked for the short loop (loop.sh adopt) is run with loop.sh, not tk.sh.
  for b in $boards; do
    # Under the box runner there is no other loop (no Herdr, no board session):
    # a board without the mark is one the coordinator wrote by hand or one from
    # before the rollout, and it is adopted here so loop.sh runs it. A board the
    # old loop still runs is refused by adopt and left as it is, said.
    if (( runner )) && [[ ! -f "$r/.scratch/$b/loop" && -n "$(find "$r/.scratch/$b" -maxdepth 1 -name '[0-9]*.md' -print -quit 2>/dev/null)" ]]; then
      if out="$("$SCRIPTS/loop.sh" -C "$r" adopt "$b" 2>&1)"; then log "board $b ($(basename "$r")): ${out%%$'\n'*}"
      else echo "WARN board $b ($(basename "$r")) not adopted: ${out%%$'\n'*}" >&2; fi
    fi
    if [[ -f "$r/.scratch/$b/loop" && "$(tr -d '[:space:]' <"$r/.scratch/$b/loop")" == short ]]; then
      short_boards+="${short_boards:+, }\`$b\` ($(basename "$r"))"
    fi
  done
done

PROMPT="$DIR/.brief.md"
tpl="$(cat "$SKILL_DIR/templates/project-coordinator-prompt.md")"
tpl="${tpl//'{{PROJECT}}'/"$PROJECT"}"
tpl="${tpl//'{{DIR}}'/"$DIR"}"
tpl="${tpl//'{{TK}}'/"$SCRIPTS/tk.sh"}"
tpl="${tpl//'{{MERGER}}'/"$SCRIPTS/merge-conflict.sh"}"
tpl="${tpl//'{{INBOX}}'/"$SCRIPTS/coordinator-inbox.sh"}"
tpl="${tpl//'{{THREAD}}'/"$SCRIPTS/thread.sh $DIR"}"
tpl="${tpl//'{{WAKE}}'/"$SCRIPTS/wake.sh $DIR"}"
tpl="${tpl//'{{THREAD_MODEL}}'/"$THREAD_MODEL"}"
tpl="${tpl//'{{THREAD_EFFORT}}'/"$THREAD_EFFORT"}"
fill_prose '{{REPOS}}' "${repo_lines%$'\n'}"
# Under the runner the section goes in even before the first board: the
# boards the coordinator writes run on the short loop too.
if (( runner )) && [[ -z "$short_boards" ]]; then short_boards="none yet: every board you write"; fi
if [[ -n "$short_boards" ]]; then
  sec="$(cat "$SKILL_DIR/templates/short-loop-section.md")"
  sec="${sec//'{{SHORT_BOARDS}}'/"$short_boards"}"
  sec="${sec//'{{LOOP}}'/"$SCRIPTS/loop.sh"}"
  sec="${sec//'{{DIR}}'/"$DIR"}"
  if (( runner )); then
    sec+=$'\n\n'"$(cat "$SKILL_DIR/templates/runner-section.md")"
    sec="${sec//'{{LOOP}}'/"$SCRIPTS/loop.sh"}"
  fi
  tpl+=$'\n\n'"$sec"
fi
printf '%s\n' "$tpl" >"$PROMPT"

# Each message the developer sends carries the inbox events still untold. Under
# the runner the hook goes in the folder's own local settings instead of
# --settings: devbox-run gives a command that passes --settings none of its hooks.
SETTINGS="$DIR/.settings.json"
if (( runner )); then
  SETTINGS="$DIR/.claude/settings.local.json"; mkdir -p "$DIR/.claude"
fi
jq -n --arg cmd "$(printf '%q hook %q' "$SCRIPTS/coordinator-inbox.sh" "$DIR")" \
  '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $cmd, timeout: 10}]}]}}' >"$SETTINGS"

build_session_agents ticket-merger ticket-pr-creator ticket-scout ticket-researcher

# The project's MCP servers: every name the policy key `mcp` lists in the box
# layer, its repos' layer or any of their boards' (devboxes writes the files,
# mcp_servers). It runs as the box user, so its files are the box user's; the
# --strict-mcp-config below keeps everything else out.
mcp_layers=("${TICKET_BOX_POLICY:-$HOME/.config/tk-daemon/policy.json}")
for r in "${REPOS[@]}"; do
  mcp_layers+=("$r/.scratch/policy.json")
  for f in "$r"/.scratch/*/policy.json; do [[ -f "$f" ]] && mcp_layers+=("$f"); done
done
mcp_names="$(for f in "${mcp_layers[@]}"; do if [[ -s "$f" ]]; then jq -c '.mcp // []' "$f" 2>/dev/null || true; fi; done | jq -s 'add // []' | mcp_csv)"
mcp_user_args "$mcp_names"
[[ -z "$MCP_MISSING" ]] || echo "WARN MCP server(s) not on this box, started without: $MCP_MISSING (devboxes mcp_servers, then devbox sync)" >&2

# What thread.sh opens its threads with, resolved here (the hub's per-project
# setting arrives as TICKET_THREAD_* in this script's environment).
printf 'TICKET_THREAD_MODEL=%q\nTICKET_THREAD_EFFORT=%q\nTICKET_THREAD_MCP=%q\n' \
  "$THREAD_MODEL" "$THREAD_EFFORT" "$mcp_names" >"$DIR/thread.env"

first="Start as the project coordinator of ${PROJECT}: follow 'Every start' in your instructions."
(( resume )) && first="You were restarted. Read state.md and journal.log's last lines, run the digests again, start the inbox watcher again, and carry on: tell me only what changed."
resume_note="You were restarted. Read state.md and journal.log's last lines, run the digests (and loop.sh status on short-loop boards) again, start the inbox watcher again in the background, and carry on: tell me only what changed."
cmd=(claude "$first"
     --model "$PCOORD_MODEL" --effort "$PCOORD_EFFORT"
     --strict-mcp-config ${MCP_ARGS[@]+"${MCP_ARGS[@]}"}
     --append-system-prompt-file "$PROMPT")
(( runner )) || cmd+=(--settings "$SETTINGS")
(( resume && ! runner )) && cmd+=(--continue)
[[ -n "${TICKET_PCOORD_AUTOCOMPACT:-}" ]] && cmd+=(--autocompact "$TICKET_PCOORD_AUTOCOMPACT")
for r in "${REPOS[@]}"; do cmd+=(--add-dir "$r"); done
[[ -n "$SESSION_AGENTS_JSON" ]] && cmd+=(--agents "$SESSION_AGENTS_JSON")
# Its own scripts run without a prompt each time; anything else asks.
cmd+=(--allowedTools "Bash($SCRIPTS/loop.sh *)" "Bash($SCRIPTS/tk.sh *)" "Bash($LAUNCHER_PATH *)" "Bash($SCRIPTS/merge-conflict.sh *)" "Bash($SCRIPTS/pr-open.sh *)" "Bash($SCRIPTS/coordinator-inbox.sh *)" "Bash($SCRIPTS/thread.sh *)" "Bash($SCRIPTS/wake.sh *)")

log "project coordinator $PROJECT on $PCOORD_MODEL @ $PCOORD_EFFORT, threads on $THREAD_MODEL @ $THREAD_EFFORT — ${#REPOS[@]} repo(s), folder $DIR — subagents: $SESSION_AGENTS_STATUS${short_boards:+ — short loop: $short_boards} — MCP: ${mcp_names:-none}"
if (( as_json )); then
  jq -cn --arg project "$PROJECT" --arg dir "$DIR" --arg prompt "$first" --arg session "$SESSION" --arg note "$resume_note" \
    '{project: $project, dir: $dir, prompt: $prompt, session: $session, resume_note: $note, args: $ARGS.positional}' --args -- "${cmd[@]:2}"
  exit 0
fi
if (( runner )); then
  # The runner types the first prompt in once claude is ready (--prompt), and
  # answers the folder-trust dialog of a new folder (--trust).
  rcmd=("$RUNNER" start "$SESSION" --dir "$DIR" --prompt "$first" --trust -- claude "${cmd[@]:2}")
  if (( print )); then printf '%q ' "${rcmd[@]}"; echo; exit 0; fi
  if "$RUNNER" status "$SESSION" 2>/dev/null | jq -e '.sessions[0].alive == true' >/dev/null 2>&1; then
    echo "RUNNING $SESSION is already running — devbox-run attach $SESSION to watch it, devbox-run stop $SESSION to end it"
    exit 0
  fi
  if (( resume )) && "$RUNNER" status "$SESSION" >/dev/null 2>&1; then
    "$RUNNER" resume "$SESSION" --note "$resume_note"
    echo "RESUMED $SESSION"
  else
    "$RUNNER" start "$SESSION" --dir "$DIR" --prompt "$first" --trust -- claude "${cmd[@]:2}" >/dev/null
    echo "STARTED $SESSION in $DIR"
  fi
  exit 0
fi
if (( print )); then printf '%q ' "${cmd[@]}"; echo; exit 0; fi
cd "$DIR"
exec "${cmd[@]}"
