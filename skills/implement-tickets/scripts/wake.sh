#!/usr/bin/env bash
# wake.sh — a project coordinator's own reminders: "look at this deploy in
# 20 minutes", "every weekday at 08:30, run the digests and tell me what moved".
#
# The wakes live in <dir>/wakes.json (the coordinator's folder). The inbox
# watcher (coordinator-inbox.sh) runs `wake.sh <dir> due` while it waits, which
# drops a `wake` event in <dir>/inbox/ for each wake whose time has come; the
# watcher then ends and the session's turn starts, with nothing typed and no hub
# call. A one-off wake goes once it fired; a repeating one moves to its next
# time. A wake missed while the box was off fires once when the watcher runs
# again (the event says how late), never once per missed time.
#
# Usage: wake.sh <dir> <verb> ...
#   add --in <dur> <text>       once, <dur> from now: 20m, 2h, 1d (1m .. 30d)
#   add --at <when> <text>      once, at <when> in the box's time zone: "14:30"
#                               (today, or tomorrow once past), "2026-12-01 09:00",
#                               "tomorrow 08:00" (anything `date -d` reads)
#   add --every <spec> <text>   repeating. <spec> is an interval, 10m .. 7d ("30m",
#                               "2h"), or "[<days>] HH:MM", days being daily (the
#                               default), weekday, weekend or a list such as
#                               mon,wed,fri ("weekday 08:30", "mon 09:00")
#       --max <n>               with --every: gone after its n-th firing
#   list [--json]               what is scheduled, soonest first
#   rm <id>...                  remove wakes (unknown ids: exit 3)
#   due                         the watcher's: write the events of the wakes due
#                               now, print their file names
#
# A wake event: {"at", "kind": "wake", "board": "", "nn": null, "repo": "",
# "id", "text", "due", "late_min", "repeat", "fired", "next"}; `next` is null
# once the wake is gone. docs/agents/project-coordinator.md, Check back later.
set -euo pipefail

usage="usage: wake.sh <dir> add (--in <dur>|--at <when>|--every <spec> [--max <n>]) <text> | list [--json] | rm <id>... | due"
die() { echo "wake.sh: $*" >&2; exit 2; }
DIR="${1:-}"; VERB="${2:-}"
[[ -n "$DIR" && -n "$VERB" ]] || die "$usage"
shift 2
[[ -d "$DIR" ]] || die "no folder $DIR"
command -v jq >/dev/null || die "jq not found"
FILE="$DIR/wakes.json"
INBOX="$DIR/inbox"
TEXT_MAX=500

# Every read-modify-write of wakes.json holds this lock: the session adds and
# removes while the watcher fires.
exec 9>>"$DIR/.wakes.lock"
flock -w 10 9 || die "wakes.json is locked"

load() { if [[ -s "$FILE" ]] && jq -e '.wakes | type == "array"' "$FILE" >/dev/null 2>&1; then cat "$FILE"; else echo '{"next_id":1,"wakes":[]}'; fi; }
save() { local tmp; tmp="$(mktemp "$DIR/.wakes.XXXXXX")"; cat >"$tmp"; mv "$tmp" "$FILE"; }
iso() { date -d "@$1" +%Y-%m-%dT%H:%M:%S%:z; }

# A duration (20m, 2h, 1d) in seconds, or nothing.
seconds_of() {
  [[ "$1" =~ ^([0-9]{1,4})(m|min|h|d)$ ]] || return 1
  local n=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in m | min) echo $((n * 60)) ;; h) echo $((n * 3600)) ;; d) echo $((n * 86400)) ;; esac
}

# "[<days>] HH:MM" -> "<days>\t<HH:MM>", days normalised to daily|weekday|weekend|mon,tue,...
calendar_of() {
  local spec="$1" days t d out=() seen=" "
  if [[ "$spec" =~ ^([0-2]?[0-9]):([0-5][0-9])$ ]]; then days=daily; t="$spec"
  elif [[ "$spec" =~ ^([A-Za-z,]+)[[:space:]]+([0-2]?[0-9]:[0-5][0-9])$ ]]; then days="${BASH_REMATCH[1],,}"; t="${BASH_REMATCH[2]}"
  else return 1; fi
  [[ "$t" =~ ^([0-2]?[0-9]):([0-5][0-9])$ ]] && (( 10#${BASH_REMATCH[1]} < 24 )) || return 1
  t="$(printf '%02d:%s' $((10#${BASH_REMATCH[1]})) "${BASH_REMATCH[2]}")"
  case "$days" in
    daily | weekday | weekend) ;;
    *)
      IFS=, read -ra parts <<<"$days"
      for d in "${parts[@]}"; do
        d="${d:0:3}"
        [[ " mon tue wed thu fri sat sun " == *" $d "* ]] || return 1
        [[ "$seen" == *" $d "* ]] || { out+=("$d"); seen+="$d "; }
      done
      (( ${#out[@]} )) || return 1
      days="$(IFS=,; echo "${out[*]}")" ;;
  esac
  printf '%s\t%s\n' "$days" "$t"
}

day_matches() {  # <days> <date YYYY-MM-DD>
  local u name
  u="$(date -d "$2" +%u)"; name="$(date -d "$2" +%a)"; name="${name,,}"
  case "$1" in
    daily) return 0 ;;
    weekday) (( u <= 5 )) ;;
    weekend) (( u >= 6 )) ;;
    *) [[ ",$1," == *",$name,"* ]] ;;
  esac
}

# The first time strictly after <epoch> that <spec> names, as an epoch.
next_after() {
  local spec="$1" from="$2" s days t i day c
  if s="$(seconds_of "$spec")"; then echo $((from + s)); return 0; fi
  IFS=$'\t' read -r days t < <(calendar_of "$spec") || return 1
  for i in 0 1 2 3 4 5 6 7 8; do
    day="$(date -d "@$from" +%F)"; day="$(date -d "$day +$i day" +%F)"
    day_matches "$days" "$day" || continue
    c="$(date -d "$day $t" +%s)" || continue
    (( c > from )) && { echo "$c"; return 0; }
  done
  return 1
}

# A repeating spec as stored: the interval as given, or "<days> HH:MM".
normal_every() {
  local s days t
  if s="$(seconds_of "$1")"; then
    (( s >= 600 && s <= 604800 )) || die "--every $1: an interval is 10m .. 7d"
    echo "$1"; return
  fi
  IFS=$'\t' read -r days t < <(calendar_of "$1") || die "--every $1: an interval (30m, 2h) or \"[daily|weekday|weekend|mon,wed,...] HH:MM\""
  echo "$days $t"
}

human() {  # "<epoch>" -> "in 14 min (14:32)" / "Mon 08:30"
  local e="$1" now d
  now="$(date +%s)"; d=$((e - now))
  if (( d < 0 )); then echo "due now"
  elif (( d < 3600 )); then echo "in $(( (d + 59) / 60 )) min ($(date -d "@$e" +%H:%M))"
  elif [[ "$(date -d "@$e" +%F)" == "$(date +%F)" ]]; then echo "today $(date -d "@$e" +%H:%M)"
  elif [[ "$(date -d "@$e" +%F)" == "$(date -d tomorrow +%F)" ]]; then echo "tomorrow $(date -d "@$e" +%H:%M)"
  elif (( d < 6 * 86400 )); then date -d "@$e" '+%a %H:%M'
  else date -d "@$e" '+%F %H:%M'; fi
}

case "$VERB" in
  add)
    kind=""; spec=""; max=""; at=""; now="$(date +%s)"
    while [[ "${1:-}" == --* ]]; do
      case "$1" in
        --in) [[ -z "$kind" ]] || die "one of --in, --at, --every"; kind=once
              s="$(seconds_of "${2:-}")" || die "--in ${2:-}: a duration such as 20m, 2h, 1d"
              (( s >= 60 && s <= 30 * 86400 )) || die "--in ${2:-}: 1m .. 30d"
              at=$((now + s)); shift 2 ;;
        --at) [[ -z "$kind" ]] || die "one of --in, --at, --every"; kind=once
              when="${2:-}"; [[ -n "$when" ]] || die "--at needs a time"
              at="$(date -d "$when" +%s 2>/dev/null)" || die "--at $when: not a time date -d reads"
              # A bare HH:MM already past today means tomorrow.
              if (( at <= now )) && [[ "$when" =~ ^[0-2]?[0-9]:[0-5][0-9]$ ]]; then at="$(date -d "tomorrow $when" +%s)"; fi
              (( at > now )) || die "--at $when is in the past ($(iso "$at"))"
              (( at <= now + 60 * 86400 )) || die "--at $when is more than 60 days away"
              shift 2 ;;
        --every) [[ -z "$kind" ]] || die "one of --in, --at, --every"; kind=every
              spec="$(normal_every "${2:-}")"; at="$(next_after "$spec" "$now")"; shift 2 ;;
        --max) [[ "${2:-}" =~ ^[1-9][0-9]{0,3}$ ]] || die "--max: a count, 1 .. 9999"; max="$2"; shift 2 ;;
        *) die "unknown option $1 — $usage" ;;
      esac
    done
    [[ -n "$kind" ]] || die "$usage"
    [[ -z "$max" || "$kind" == every ]] || die "--max goes with --every"
    text="$*"; text="${text//$'\n'/ }"
    [[ -n "${text// /}" ]] || die "say what the wake is for: wake.sh <dir> add --in 20m \"check the deploy of #12\""
    (( ${#text} <= TEXT_MAX )) || die "the text is longer than $TEXT_MAX characters: put the detail in a file and name it"
    cur="$(load)"
    id="w$(jq -r '.next_id // 1' <<<"$cur")"
    jq --arg id "$id" --arg text "$text" --arg kind "$kind" --arg every "$spec" --arg max "$max" \
       --argjson at "$at" --arg next "$(iso "$at")" --arg created "$(iso "$now")" \
       '.next_id = ((.next_id // 1) + 1)
        | .wakes += [{id: $id, text: $text, kind: $kind, every: (if $every == "" then null else $every end),
                      next: $next, next_epoch: $at, created: $created, fired: 0, last_fired: null,
                      max: (if $max == "" then null else ($max | tonumber) end)}]' <<<"$cur" | save
    echo "ADDED $id — $(human "$at")$( [[ "$kind" == every ]] && echo ", then every $spec${max:+, $max time(s)}"): $text"
    ;;

  list)
    cur="$(load)"
    if [[ "${1:-}" == --json ]]; then jq '.wakes | sort_by(.next_epoch)' <<<"$cur"; exit 0; fi
    n="$(jq '.wakes | length' <<<"$cur")"
    (( n )) || { echo "no wakes"; exit 0; }
    while IFS=$'\x1f' read -r id e every fired max text; do
      rep="once"; [[ -n "$every" ]] && rep="every $every${max:+ (fired $fired of $max)}"
      printf '%-5s %-22s %-28s %s\n' "$id" "$(human "$e")" "$rep" "$text"
    done < <(jq -r '.wakes | sort_by(.next_epoch)[] | [.id, .next_epoch, (.every // ""), .fired, (.max // "" | tostring), .text] | map(tostring) | join("\u001f")' <<<"$cur")
    ;;

  rm)
    (( $# )) || die "rm <id>..."
    cur="$(load)"; missing=()
    for id in "$@"; do jq -e --arg id "$id" 'any(.wakes[]; .id == $id)' <<<"$cur" >/dev/null || missing+=("$id"); done
    jq --args '.wakes |= map(select(.id as $i | $ARGS.positional | index($i) | not))' "$@" <<<"$cur" | save
    for id in "$@"; do [[ " ${missing[*]-} " == *" $id "* ]] || echo "REMOVED $id"; done
    (( ${#missing[@]} == 0 )) || { echo "no wake ${missing[*]}" >&2; exit 3; }
    ;;

  due)
    [[ -d "$INBOX" ]] || exit 0
    [[ -s "$FILE" ]] || exit 0
    cur="$(load)"; now="$(date +%s)"
    jq -e --argjson now "$now" 'any(.wakes[]; .next_epoch <= $now)' <<<"$cur" >/dev/null || exit 0
    stamp="$(date -u +%Y%m%dT%H%M%S)"; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    while IFS= read -r w; do
      id="$(jq -r .id <<<"$w")"; due="$(jq -r .next_epoch <<<"$w")"; every="$(jq -r '.every // ""' <<<"$w")"
      fired=$(( $(jq -r .fired <<<"$w") + 1 )); max="$(jq -r '.max // ""' <<<"$w")"
      nxt=""
      if [[ -n "$every" ]] && { [[ -z "$max" ]] || (( fired < max )); }; then
        nxt="$(next_after "$every" "$now")" || nxt=""
      fi
      ev="$(jq -n --arg at "$at" --argjson w "$w" --argjson late $(( (now - due) / 60 )) --argjson fired "$fired" \
              --arg next "$( [[ -n "$nxt" ]] && iso "$nxt")" \
              '{at: $at, kind: "wake", board: "", nn: null, repo: "", id: $w.id, text: $w.text, due: $w.next,
                late_min: $late, repeat: $w.every, fired: $fired, next: (if $next == "" then null else $next end)}')"
      f="$INBOX/$stamp-wake-$id.json"
      printf '%s\n' "$ev" >"$f.tmp" && mv "$f.tmp" "$f"
      echo "${f##*/}"
      if [[ -n "$nxt" ]]; then
        cur="$(jq --arg id "$id" --argjson e "$nxt" --arg next "$(iso "$nxt")" --argjson fired "$fired" --arg last "$(iso "$now")" \
                 '.wakes |= map(if .id == $id then .next_epoch = $e | .next = $next | .fired = $fired | .last_fired = $last else . end)' <<<"$cur")"
      else
        cur="$(jq --arg id "$id" '.wakes |= map(select(.id != $id))' <<<"$cur")"
      fi
    done < <(jq -c --argjson now "$now" '.wakes[] | select(.next_epoch <= $now)' <<<"$cur")
    save <<<"$cur"
    ;;

  *) die "$usage" ;;
esac
