#!/usr/bin/env bash
# coordinator-inbox.sh — how the project coordinator hears of new inbox events
# without anything being typed into its terminal.
#
# tk-hub's daemon drops one JSON file per event into <dir>/inbox/. Typing a line
# into the session to say so (the old nudge) joined the developer's half-written
# message whenever he was writing at its prompt. Instead:
#
#   wait <dir>   The session runs this as a background command. It returns once
#                an event it was not told of is in the inbox, printing their
#                names. Claude Code starts a turn when a background command ends,
#                so the coordinator wakes with nothing typed. While it waits,
#                <dir>/inbox/.watcher holds its pid: tk-hub's daemon then never
#                types its nudge. Exits after TICKET_PCOORD_WAIT_S (default
#                6 h) with "no new events", so the session starts it again.
#   hook <dir>   A UserPromptSubmit hook (coordinator.sh's settings): each
#                message the developer sends carries, as context, the events
#                still waiting that the session was not told of, and one line
#                on routing: anything beyond what the coordinator already has
#                goes to a thread (thread.sh). A long session drifts from its
#                brief; a reminder beside each of his asks keeps the coordinator
#                from doing the work in its own context.
#
# What was announced is kept in <dir>/inbox/.announced (one name per line), so
# an event is announced once, by whichever comes first.
#
# Short-loop boards (loop.sh adopt) have no daemon writing their events: while it
# waits, the watcher runs `loop.sh watch` on each of them every
# TICKET_PCOORD_LOOP_POLL_S seconds (default 120), which writes an event into the
# inbox for each ticket that moved (built, a question, a dead session, a PR
# approved or sent back, landed, unblocked). docs/agents/short-loop.md, Watching.
#
# The coordinator's own wakes (wake.sh, <dir>/wakes.json) are fired here too:
# every TICKET_PCOORD_WAKE_POLL_S seconds (default 30) while it waits, and on
# each hook, `wake.sh <dir> due` writes a `wake` event for each one due, which
# this then announces like any other. docs/agents/project-coordinator.md, Check
# back later.
# docs/agents/project-coordinator.md, The inbox.
set -euo pipefail

usage="usage: coordinator-inbox.sh wait|hook <dir>"
mode="${1:-}"; DIR="${2:-}"
[[ -n "$mode" && -n "$DIR" ]] || { echo "$usage" >&2; exit 2; }
INBOX="$DIR/inbox"
[[ -d "$INBOX" ]] || { echo "no inbox in $DIR" >&2; exit 2; }
ANNOUNCED="$INBOX/.announced"
WATCHER="$INBOX/.watcher"
POLL_S="${TICKET_PCOORD_POLL_S:-5}"
WAIT_S="${TICKET_PCOORD_WAIT_S:-21600}"
LOOP_POLL_S="${TICKET_PCOORD_LOOP_POLL_S:-120}"
WAKE_POLL_S="${TICKET_PCOORD_WAKE_POLL_S:-30}"
LOOP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/loop.sh"
WAKE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wake.sh"
THREAD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/thread.sh"

# Is a watcher alive for this folder?
watching() { local p; p="$(cat "$WATCHER" 2>/dev/null)" && [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

# Every short-loop board of the folder's repos, as "<repo path>\t<board>".
short_boards() {
  local r b
  [[ -f "$DIR/repos" ]] || return 0
  while IFS= read -r r; do
    [[ -n "$r" && -d "$r/.scratch" ]] || continue
    for b in "$r"/.scratch/*/loop; do
      [[ -f "$b" && "$(tr -d '[:space:]' <"$b")" == short ]] || continue
      b="${b%/loop}"; printf '%s\t%s\n' "$r" "${b##*/}"
    done
  done <"$DIR/repos"
}

# loop.sh watch on each short-loop board; a failure goes to journal.log at most
# once an hour per board, never ends the watcher.
watch_boards() {
  local r b out rc stamp
  while IFS=$'\t' read -r r b; do
    rc=0; out="$("$LOOP" -C "$r" watch "$b" --inbox "$INBOX" 2>&1)" || rc=$?
    (( rc == 0 )) && continue
    stamp="$INBOX/.watch-failed-${b//\//_}"
    [[ -f "$stamp" && -n "$(find "$stamp" -mmin -60 2>/dev/null)" ]] && continue
    touch "$stamp"
    printf '%s loop.sh watch %s (%s) failed: %s\n' "$(date -u +%FT%TZ)" "$b" "${r##*/}" "$(tail -n1 <<<"$out")" >>"$DIR/journal.log"
  done < <(short_boards)
}

# The wakes due now into the inbox; a failure goes to journal.log at most once
# an hour, never ends the watcher.
fire_wakes() {
  local out stamp
  [[ -s "$DIR/wakes.json" ]] || return 0
  out="$("$WAKE" "$DIR" due 2>&1)" && return 0
  stamp="$INBOX/.wake-failed"
  [[ -f "$stamp" && -n "$(find "$stamp" -mmin -60 2>/dev/null)" ]] && return 0
  touch "$stamp"
  printf '%s wake.sh due failed: %s\n' "$(date -u +%FT%TZ)" "$(tail -n1 <<<"$out")" >>"$DIR/journal.log"
}

# The events in the inbox not announced yet, one name per line.
fresh() {
  local f name
  for f in "$INBOX"/*.json; do
    [[ -f "$f" ]] || continue
    name="${f##*/}"
    [[ -f "$ANNOUNCED" ]] && grep -qxF -- "$name" "$ANNOUNCED" && continue
    echo "$name"
  done
}

# Notes names as announced; the ledger keeps only names still in the inbox.
announce() {
  local tmp name
  tmp="$(mktemp "$INBOX/.announced.XXXXXX")"
  {
    [[ -f "$ANNOUNCED" ]] && while IFS= read -r name; do
      [[ -f "$INBOX/$name" ]] && echo "$name"
    done <"$ANNOUNCED"
    printf '%s\n' "$@"
  } | sort -u >"$tmp"
  mv "$tmp" "$ANNOUNCED"
}

case "$mode" in
  wait)
    echo $$ >"$WATCHER"
    trap 'rm -f "$WATCHER"' EXIT
    waited=0; next_watch=0; next_wake=0
    while :; do
      if (( waited >= next_watch )); then watch_boards; next_watch=$(( waited + LOOP_POLL_S )); fi
      if (( waited >= next_wake )); then fire_wakes; next_wake=$(( waited + WAKE_POLL_S )); fi
      mapfile -t new < <(fresh)
      if (( ${#new[@]} )); then
        announce "${new[@]}"
        echo "${#new[@]} new event(s) in $INBOX:"
        printf '  %s\n' "${new[@]}"
        echo "Handle them as under 'The inbox', then start this watcher again."
        exit 0
      fi
      if (( waited >= WAIT_S )); then
        echo "no new events in $INBOX; start this watcher again."
        exit 0
      fi
      sleep "$POLL_S"; waited=$(( waited + POLL_S ))
    done
    ;;
  hook)
    cat >/dev/null  # the hook's JSON on stdin: not needed
    echo "Routing (your brief, Threads): answer him from what you already have (state.md, a digest, the ledger, a report, this chat) or with one of your own verbs. Anything else, ticket or not, goes to a thread: $THREAD $DIR start --title ... --brief ... (a follow-up on the same subject: say <id> <file>), and you tell him in one line. Only his \"you do it\" for this ask makes it yours."
    fire_wakes
    mapfile -t new < <(fresh)
    if (( ${#new[@]} )); then
      announce "${new[@]}"
      echo "Waiting in $INBOX (from tk-hub's daemon, not from the developer): ${new[*]}. Handle them as under 'The inbox' after answering him."
    fi
    # A restart (a resume, a reboot) ends the background watcher with the old process.
    watching || echo "The inbox watcher is not running (a restart ends it): after answering him, start it again in the background: $0 wait $DIR"
    ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
