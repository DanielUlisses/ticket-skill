#!/usr/bin/env bash
# The project coordinator's proposals for project memory: a line it would add
# to a repo's .scratch/project-memory.md, which the developer accepts or rejects
# in tk-hub's Project settings (Memory). The coordinator never edits the memory
# file; accepting appends the line there (tk-hub's daemon, settle_memory). See
# docs/agents/project-coordinator.md, Instructions and memory.
#
#   memory.sh <coordinator dir> propose --repo <repo> [--why <text>] <line>
#   memory.sh <coordinator dir> list [open|all]
#
# The proposals live in <coordinator dir>/memory-proposals.json, an array of
# {id: "m<N>", repo, text, why, at, state: open|accepted|rejected, settled_at}.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

usage="usage: memory.sh <coordinator dir> propose --repo <repo> [--why <text>] <line> | list [open|all]"
DIR="${1:-}"; [[ -n "$DIR" ]] || die "$usage"; shift
[[ -d "$DIR" && -f "$DIR/repos" ]] || die "$DIR is not a project coordinator's folder (no repos file)"
FILE="$DIR/memory-proposals.json"
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The repo's name as the hub knows it, when it is one of the project's.
repo_name() {
  local want="$1" r
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    if [[ "$r" == "$want" || "$(basename "$r")" == "$want" ]]; then basename "$r"; return 0; fi
  done <"$DIR/repos"
  die "repo '$want' isn't one of this project's (see $DIR/repos)"
}

# The shapes tk-hub refuses as secrets; a proposal never holds one.
looks_secret() {
  grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|ops_[A-Za-z0-9_-]{16,}|(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|[Bb]earer [A-Za-z0-9._~+/=-]{20,}' <<<"$1" \
    || grep -qiE -- '[A-Za-z0-9_-]*(password|passwd|secret|token|api[_-]?key)[A-Za-z0-9_-]*[[:space:]]*[:=][[:space:]]*[^[:space:]]{8,}' <<<"$1"
}

cmd_propose() {
  local repo="" why="" line=""
  while (( $# )); do
    case "$1" in
      --repo) repo="$(repo_name "${2:?--repo needs a repo}")"; shift 2 ;;
      --why) why="${2:?--why needs text}"; shift 2 ;;
      --*) die "unknown option $1 — $usage" ;;
      *) line="${line:+$line }$1"; shift ;;
    esac
  done
  [[ -n "$repo" ]] || die "a proposal needs --repo: which repo's memory it belongs in"
  line="$(tr -s '[:space:]' ' ' <<<"$line" | sed 's/^ *//; s/ *$//')"
  [[ -n "$line" ]] || die "a proposal needs the line itself"
  (( ${#line} <= 600 )) || die "keep it to one line of at most 600 characters"
  looks_secret "$line $why" && die "that looks like a secret: name where the value lives instead"
  [[ -s "$FILE" ]] || echo '[]' >"$FILE"
  jq -e 'type == "array"' "$FILE" >/dev/null 2>&1 || die "$FILE is not a JSON array: fix it by hand first"
  if jq -e --arg repo "$repo" --arg text "$line" 'any(.[]; .repo == $repo and .text == $text and (.state // "open") == "open")' "$FILE" >/dev/null; then
    echo "ALREADY proposed for $repo, waiting in Project settings"; return 0
  fi
  local id tmp="$FILE.tmp"
  id="m$(jq '[.[] | .id // "" | ltrimstr("m") | tonumber? ] | (max // 0) + 1' "$FILE")"
  jq --arg id "$id" --arg repo "$repo" --arg text "$line" --arg why "$why" --arg at "$(now_iso)" \
    '. + [{id: $id, repo: $repo, text: $text, why: $why, at: $at, state: "open", settled_at: null}]' "$FILE" >"$tmp"
  mv "$tmp" "$FILE"
  printf '%s memory proposal %s (%s): %s\n' "$(now_iso)" "$id" "$repo" "$line" >>"$DIR/journal.log"
  echo "PROPOSED $id for $repo — Daniel accepts or rejects it in the project's settings, under Memory"
}

cmd_list() {
  local which="${1:-open}"
  [[ -s "$FILE" ]] || { echo "no proposals"; return 0; }
  jq -r --arg which "$which" '.[] | select($which == "all" or (.state // "open") == "open")
    | "\(.id)  \(.state // "open")  \(.repo)  \(.text)"' "$FILE"
}

verb="${1:-}"; [[ -n "$verb" ]] || die "$usage"; shift
case "$verb" in
  propose) cmd_propose "$@" ;;
  list) cmd_list "$@" ;;
  *) die "$usage" ;;
esac
