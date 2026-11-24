#!/usr/bin/env bash
# The project coordinator's threads: a session of its own, on the project's
# repos, for anything deeper than a quick lookup (troubleshooting, reading code
# across files, a CI log, research, a design question). The coordinator stays
# the one the developer talks to; the thread does the work and reports back in
# a few lines through the coordinator's inbox. See docs/agents/project-coordinator.md,
# Threads.
#
#   thread.sh <coordinator dir> start --title <t> (--brief <text> | --brief-file <f>) [--repo <repo>]...
#                                     [--model m] [--effort e]
#   thread.sh <coordinator dir> list
#   thread.sh <coordinator dir> say <id> <file>
#   thread.sh <coordinator dir> log <id> [lines]
#   thread.sh <coordinator dir> report <id>      (the thread runs this when done)
#   thread.sh <coordinator dir> stop <id>
#
# A thread is an ad-hoc chat as tk-hub's daemon knows them: a folder
# <base>/.chats/<id>/ beside the coordinators' <base>/.coordinators/ holding
# its brief and a .grill, run by the box runner as session chat-<id>, so the
# hub lists it under its project (the .grill's `project`) and Daniel can open
# and talk to it. It starts in the first repo's main checkout, the others and
# its own folder added; it runs the box user's claude with
# --permission-mode bypassPermissions and git's writing commands denied: a
# thread reads, runs and reports, and a change it finds needed comes back as a
# proposal the coordinator turns into a ticket.
#
# Model and effort: --model/--effort, else <coordinator dir>/thread.env
# (coordinator.sh writes it on every start from the hub's project setting or
# the config), else config/models.env's TICKET_THREAD_* (opus @ medium).
#
# Environment: TICKET_RUNNER (default devbox-run), TICKET_THREAD_PERMISSION_MODE
# (default bypassPermissions).
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

usage="usage: thread.sh <coordinator dir> start|list|say|log|report|stop ..."
DIR="${1:-}"; [[ -n "$DIR" ]] || die "$usage"; shift
[[ -d "$DIR" && -f "$DIR/repos" ]] || die "$DIR is not a project coordinator's folder (no repos file)"
DIR="$(cd "$DIR" && pwd)"
PROJECT="$(basename "$DIR")"
CHATS="$(dirname "$(dirname "$DIR")")/.chats"
RUNNER="${TICKET_RUNNER:-devbox-run}"
SCRIPTS="$SKILL_DIR/scripts"
need jq

# What coordinator.sh resolved for this project, under what the config says.
if [[ -f "$DIR/thread.env" ]]; then
  # shellcheck source=/dev/null
  source "$DIR/thread.env"
  export TICKET_THREAD_MODEL TICKET_THREAD_EFFORT
fi
load_ticket_models

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# A thread's folder from its id, refusing anything that isn't one of this project's.
thread_dir() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9]{8}T[0-9]{9}Z$ ]] || die "no thread '$id' — ids look like 20261124T211735123Z (thread.sh $DIR list)"
  [[ -f "$CHATS/$id/.grill" ]] || die "no thread $id on this box"
  [[ "$(jq -r '.project // ""' "$CHATS/$id/.grill")" == "$PROJECT" ]] || die "thread $id isn't one of $PROJECT's"
  echo "$CHATS/$id"
}

# A repo name or path to the project's main checkout of it (one listed in repos).
repo_of() {
  local want="$1" r
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    if [[ "$r" == "$want" || "$(basename "$r")" == "$want" ]]; then echo "$r"; return 0; fi
  done <"$DIR/repos"
  die "repo '$want' isn't one of $PROJECT's (see $DIR/repos)"
}

cmd_start() {
  local title="" brief="" brief_text="" model="$THREAD_MODEL" effort="$THREAD_EFFORT" repos=() r
  while (( $# )); do
    case "$1" in
      --title) title="${2:?--title needs a value}"; shift 2 ;;
      --brief-file) brief="${2:?--brief-file needs a file}"; shift 2 ;;
      --brief) brief_text="${2:?--brief needs the ask}"; shift 2 ;;
      --repo) repos+=("$(repo_of "${2:?--repo needs a repo}")"); shift 2 ;;
      --model) model="${2:?--model needs a value}"; shift 2 ;;
      --effort) effort="${2:?--effort needs a value}"; shift 2 ;;
      *) die "unknown option $1 — thread.sh <dir> start --title <t> (--brief <text> | --brief-file <f>) [--repo <repo>]... [--model m] [--effort e]" ;;
    esac
  done
  [[ -n "$title" ]] || die "a thread needs --title (what Daniel sees in the hub)"
  title="${title:0:120}"
  [[ -n "$brief_text" || -s "$brief" ]] || die "a thread needs --brief <text> or --brief-file <f>: what to find out, and why"
  local model_re='^[A-Za-z0-9][A-Za-z0-9._:-]{0,80}(\[1m\])?$'
  [[ "$model" =~ $model_re ]] || die "model '$model' — an alias (opus, sonnet, haiku) or a full model id"
  effort_valid "$effort" || die "invalid effort '$effort' — one of: $EFFORT_LEVELS"
  (( ${#repos[@]} )) || repos=("$(head -n1 "$DIR/repos")")
  command -v "$RUNNER" >/dev/null 2>&1 || die "the box runner '$RUNNER' isn't installed (devboxes' bin/devbox-run)"

  # The daemon's grill id shape (YYYYMMDDTHHMMSSmmmZ), unique among the chats.
  local id folder
  mkdir -p "$CHATS"
  while :; do
    id="$(date -u +%Y%m%dT%H%M%S%3NZ)"
    folder="$CHATS/$id"
    mkdir "$folder" 2>/dev/null && break
    sleep 0.01
  done
  local session="chat-$id"

  local tpl
  tpl="$(cat "$SKILL_DIR/templates/coordinator-thread-prompt.md")"
  tpl="${tpl//'{{PROJECT}}'/"$PROJECT"}"
  tpl="${tpl//'{{TITLE}}'/"$title"}"
  tpl="${tpl//'{{FOLDER}}'/"$folder"}"
  tpl="${tpl//'{{REPORT_CMD}}'/"$SCRIPTS/thread.sh $DIR report $id"}"
  { printf '%s\n\n## The ask\n\n' "$tpl"; if [[ -n "$brief_text" ]]; then printf '%s\n' "$brief_text"; else cat "$brief"; echo; fi; } >"$folder/brief.md"

  local args=(claude --model "$model" --effort "$effort"
              --permission-mode "${TICKET_THREAD_PERMISSION_MODE:-bypassPermissions}"
              --append-system-prompt-file "$folder/brief.md"
              --add-dir "$folder")
  for r in "${repos[@]:1}"; do args+=(--add-dir "$r"); done
  mcp_user_args "${TICKET_THREAD_MCP:-}"
  args+=(--strict-mcp-config ${MCP_ARGS[@]+"${MCP_ARGS[@]}"})
  args+=(--disallowedTools "Bash(git add:*)" "Bash(git commit:*)" "Bash(git push:*)" "Bash(git stash:*)"
         "Bash(git reset:*)" "Bash(git rebase:*)" "Bash(git checkout:*)" "Bash(git switch:*)"
         "Bash(gh pr:*)" "Bash(az repos pr:*)")

  # The .grill first: the daemon lists it (and doesn't stop it) from the start.
  jq -n --arg id "$id" --arg session "$session" --arg at "$(now_iso)" \
        --arg repo "$(basename "${repos[0]}")" --arg path "${repos[0]}" --arg title "$title" \
        --arg project "$PROJECT" --arg model "$model" --arg effort "$effort" \
    '{id: $id, session: $session, started_at: $at, repo: $repo, path: $path,
      prompt: $title, name: $title, stopped: null, project: $project,
      by: "coordinator", model: $model, effort: $effort}' >"$folder/.grill"

  local first="Read your brief (the ask is at its end), do it, then report as it says."
  if ! "$RUNNER" start "$session" --dir "${repos[0]}" --prompt "$first" --trust -- "${args[@]}" >/dev/null; then
    jq '.stopped = (now | todate)' "$folder/.grill" >"$folder/.grill.tmp" && mv "$folder/.grill.tmp" "$folder/.grill"
    die "$RUNNER start $session failed"
  fi
  printf '%s thread %s %s (%s @ %s): %s\n' "$(now_iso)" "$id" started "$model" "$effort" "$title" >>"$DIR/journal.log"
  echo "STARTED $id — \"$title\" on $model @ $effort in ${repos[0]} (runner session $session)"
}

cmd_list() {
  local g id
  for g in "$CHATS"/*/.grill; do
    [[ -f "$g" ]] || continue
    [[ "$(jq -r '.project // ""' "$g")" == "$PROJECT" ]] || continue
    id="$(jq -r .id "$g")"
    local state alive
    alive="$("$RUNNER" status "chat-$id" 2>/dev/null | jq -r '.sessions[0] | if .alive then (.last_turn // "running") else (.state // "gone") end' 2>/dev/null || echo unknown)"
    state="$alive"
    [[ "$(jq -r '.stopped // ""' "$g")" == "" ]] || state=stopped
    [[ -s "$(dirname "$g")/report.md" ]] && state+=", reported"
    jq -r --arg s "$state" '"\(.id)  \(.model // "?") @ \(.effort // "?")  \($s)  \(.name)"' "$g"
  done
}

cmd_say() {
  local folder; folder="$(thread_dir "${1:-}")"
  local f="${2:-}"; [[ -s "$f" ]] || die "usage: thread.sh <dir> say <id> <file>"
  "$RUNNER" say "chat-$(basename "$folder")" - <"$f"
}

cmd_log() {
  local folder; folder="$(thread_dir "${1:-}")"
  "$RUNNER" log "chat-$(basename "$folder")" --lines "${2:-40}"
}

cmd_report() {
  local folder; folder="$(thread_dir "${1:-}")"
  local id; id="$(basename "$folder")"
  [[ -s "$folder/report.md" ]] || die "write $folder/report.md first"
  local title summary
  title="$(jq -r .name "$folder/.grill")"
  summary="$(grep -m1 -v '^[[:space:]]*\(#.*\)\{0,1\}$' "$folder/report.md" | cut -c1-400 || true)"
  mkdir -p "$DIR/inbox"
  local ev
  ev="$DIR/inbox/$(date -u +%Y%m%dT%H%M%S%3NZ)-thread-$id.json"
  jq -n --arg at "$(now_iso)" --arg id "$id" --arg title "$title" --arg text "$summary" \
        --arg report "$folder/report.md" \
    '{at: $at, kind: "thread", thread: $id, title: $title, text: $text, report: $report}' >"$ev.tmp"
  mv "$ev.tmp" "$ev"
  echo "REPORTED — the coordinator has it in its inbox"
}

cmd_stop() {
  local folder; folder="$(thread_dir "${1:-}")"
  "$RUNNER" stop "chat-$(basename "$folder")" >/dev/null || true
  jq '.stopped = (now | todate)' "$folder/.grill" >"$folder/.grill.tmp" && mv "$folder/.grill.tmp" "$folder/.grill"
  printf '%s thread %s stopped\n' "$(now_iso)" "$(basename "$folder")" >>"$DIR/journal.log"
  echo "STOPPED $(basename "$folder")"
}

verb="${1:-}"; [[ -n "$verb" ]] || die "$usage"; shift
case "$verb" in
  start) cmd_start "$@" ;;
  list) cmd_list ;;
  say) cmd_say "$@" ;;
  log) cmd_log "$@" ;;
  report) cmd_report "$@" ;;
  stop) cmd_stop "$@" ;;
  *) die "$usage" ;;
esac
