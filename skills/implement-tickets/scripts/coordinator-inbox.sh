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
#                still waiting that the session was not told of.
#
# What was announced is kept in <dir>/inbox/.announced (one name per line), so
# an event is announced once, by whichever comes first.
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
    waited=0
    while :; do
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
    mapfile -t new < <(fresh)
    (( ${#new[@]} )) || exit 0
    announce "${new[@]}"
    echo "Waiting in $INBOX (from tk-hub's daemon, not from the developer): ${new[*]}. Handle them as under 'The inbox' after answering him."
    ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
