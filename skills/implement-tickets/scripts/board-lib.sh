#!/usr/bin/env bash
# The board, as data — shared by the /implement-tickets scripts.
#
# Sourced, never executed. The board session runs on a small model with a small
# prompt (docs/adr/0004-haiku-board-session.md), which only works if everything
# mechanical about a board lives here instead of in prose the model has to
# execute faithfully: finding the board, parsing tickets out of either home,
# resolving free-text blockers, and answering "has this branch landed".
#
# Requires ticket-git-repo.sh (die/log/need, resolve_repo_root,
# resolve_base_branch, run_git_net) to have been sourced first.
#
# The one output shape is BOARD_JSON: an array of tickets, ordered by number,
#   {nn, title, ref, issue, file, status, branch, base, model, effort, account,
#    agent, blocked_raw, blockers:[nn], smodel, seffort, parent}
# plus BOARD_KIND (file|github), BOARD_ID (what to pass back to every script),
# BOARD_SLUG (a path-safe name for state files), BOARD_PATH / BOARD_LABEL.

JIRA_RE='^[A-Za-z][A-Za-z0-9]+-[0-9]+$'

board_state_dir() {
  local d="${XDG_STATE_HOME:-$HOME/.local/state}/ticket-skill/$REPO_NAME"
  mkdir -p "$d"; echo "$d"
}

gh_label_exists() {
  command -v gh >/dev/null 2>&1 || return 1
  gh label list --search "$1" --limit 1000 --json name --jq '.[].name' 2>/dev/null | grep -qxF "$1"
}

# Sets BOARD_KIND, BOARD_PATH|BOARD_LABEL, BOARD_ID, BOARD_SLUG. Needs ROOT.
# Every ambiguity dies with the choices in the message: the model asks the
# developer and passes the answer back, it never guesses.
resolve_board() {
  local arg="${1:-}" id dirs labels
  BOARD_KIND=""; BOARD_PATH=""; BOARD_LABEL=""
  if [[ "$arg" =~ $JIRA_RE ]]; then
    id="${arg,,}"
    local has_file=0 has_gh=0
    [[ -d "$ROOT/.scratch/$id" ]] && has_file=1
    gh_label_exists "ticket:$id" && has_gh=1
    if (( has_file && has_gh )); then
      die "board '$id' exists in both homes — pass .scratch/$id or ticket:$id"
    elif (( has_file )); then BOARD_KIND=file; BOARD_PATH="$ROOT/.scratch/$id"
    elif (( has_gh )); then BOARD_KIND=github; BOARD_LABEL="ticket:$id"
    fi
    [[ -n "$BOARD_KIND" ]] || arg="$id"   # may be a slug that only looks like an id
  fi
  if [[ -z "$BOARD_KIND" && -n "$arg" ]]; then
    if [[ "$arg" == ticket:* ]]; then
      BOARD_KIND=github; BOARD_LABEL="$arg"
    elif [[ "$arg" == */* || "$arg" == *.md || -d "$arg" || -d "$ROOT/$arg" ]]; then
      BOARD_KIND=file
      if [[ "$arg" == /* ]]; then BOARD_PATH="$arg"; else BOARD_PATH="$ROOT/$arg"; fi
      [[ -e "$BOARD_PATH" ]] || die "no board at $BOARD_PATH"
    elif [[ -d "$ROOT/.scratch/$arg" ]]; then
      BOARD_KIND=file; BOARD_PATH="$ROOT/.scratch/$arg"
    elif gh_label_exists "ticket:$arg"; then
      BOARD_KIND=github; BOARD_LABEL="ticket:$arg"
    else
      die "no board '$arg': looked for $ROOT/.scratch/$arg and the label ticket:$arg"
    fi
  fi
  if [[ -z "$BOARD_KIND" ]]; then
    # No argument: the same two tests /ticket uses to pick a home.
    if command -v gh >/dev/null 2>&1 \
       && [[ -n "$(gh repo view --json hasIssuesEnabled --jq 'select(.hasIssuesEnabled) | "y"' 2>/dev/null)" ]] \
       && { [[ -f "$ROOT/docs/agents/issue-tracker.md" ]] \
            || [[ "$(gh issue list --state all --limit 1 --json number --jq length 2>/dev/null)" == 1 ]]; }; then
      BOARD_KIND=github
      labels="$(gh label list --search "ticket:" --limit 1000 --json name --jq '.[].name | select(startswith("ticket:"))' 2>/dev/null)"
      case "$(grep -c . <<<"$labels")" in
        0) BOARD_LABEL="" ;;   # the whole tracker's NN:-titled issues
        1) BOARD_LABEL="$labels" ;;
        *) die "several boards — pass one of: $(tr '\n' ' ' <<<"$labels")" ;;
      esac
    else
      BOARD_KIND=file; BOARD_PATH="$ROOT/.scratch"
    fi
  fi
  if [[ "$BOARD_KIND" == file ]]; then
    # A bare .scratch holds one directory per feature; a board is one of them.
    if [[ -d "$BOARD_PATH" && "$(basename "$BOARD_PATH")" == .scratch ]]; then
      dirs="$(find "$BOARD_PATH" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)"
      case "$(grep -c . <<<"$dirs")" in
        0) die "no boards under $BOARD_PATH" ;;
        1) BOARD_PATH="$BOARD_PATH/$dirs" ;;
        *) die "several boards — pass one of: $(tr '\n' ' ' <<<"$dirs")" ;;
      esac
    fi
    BOARD_ID="${BOARD_PATH#"$ROOT"/}"
    BOARD_SLUG="$(tr '/' '-' <<<"$BOARD_ID" | sed 's/^[.-]*//')"
  else
    BOARD_ID="${BOARD_LABEL:-tracker}"
    BOARD_SLUG="gh-${BOARD_LABEL#ticket:}"; BOARD_SLUG="${BOARD_SLUG%-}"
  fi
}

# ---- parsing -------------------------------------------------------------------

# One ticket file -> one JSON object. Only header lines are read; the prose under
# them never leaves this function.
parse_ticket_file() {
  local f="$1"
  awk -v file="$f" '
    function val(line) { sub(/^\*\*[^*]+:\*\*[ ]*/, "", line); return line }
    function first(s) { split(s, a, /[ \t]+/); return a[1] }
    /^# [0-9]+:/ && !nn { nn = $2; sub(/:$/, "", nn); t = $0; sub(/^# [0-9]+:[ ]*/, "", t); title = t; next }
    /^\*\*Status:\*\*/            { status = tolower(first(val($0))) }
    /^\*\*Branch:\*\*/            { branch = first(val($0)) }
    /^\*\*Base:\*\*/              { base = first(val($0)) }
    /^\*\*Model:\*\*/             { model = first(val($0)) }
    /^\*\*Effort:\*\*/            { effort = first(val($0)) }
    /^\*\*Account:\*\*/           { account = first(val($0)) }
    /^\*\*Agent:\*\*/             { agent = first(val($0)) }
    /^\*\*Worktree:\*\*/          { worktree = first(val($0)) }
    /^\*\*Blocked by:\*\*/        { blocked = val($0) }
    /^\*\*Suggested model:\*\*/   { smodel = first(val($0)) }
    /^\*\*Suggested effort:\*\*/  { seffort = first(val($0)) }
    /^\*\*Parent:\*\*/            { parent = tolower(first(val($0))) }
    END {
      if (!nn) { n = file; sub(/.*\//, "", n); if (match(n, /^[0-9]+/)) nn = substr(n, 1, RLENGTH) }
      printf "%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n",
        nn, title, status, branch, base, model, effort, account, agent, blocked, smodel, seffort, parent, worktree
    }' "$f" \
  | jq -R --arg file "$f" 'split("\u001f") as $v | {
      nn: $v[0], title: $v[1], ref: $file, file: $file, issue: null,
      status: (if $v[2] == "" then "open" else $v[2] end),
      branch: $v[3], base: $v[4], model: $v[5], effort: $v[6], account: $v[7], agent: $v[8],
      blocked_raw: $v[9], smodel: $v[10], seffort: $v[11], parent: $v[12], worktree: $v[13], native_blockers: null }'
}

load_file_board() {
  local f files
  if [[ -f "$BOARD_PATH" ]]; then files="$BOARD_PATH"
  else files="$(find "$BOARD_PATH" -name '*.md' -type f | sort)"; fi
  [[ -n "$files" ]] || die "no ticket files under $BOARD_PATH"
  while IFS= read -r f; do parse_ticket_file "$f"; done <<<"$files" | jq -s '.'
}

load_github_board() {
  local args=(issue list --state all --limit 500) json
  [[ -n "$BOARD_LABEL" ]] && args+=(--label "$BOARD_LABEL")
  json="$(gh "${args[@]}" --json number,title,state,assignees,body,comments,blockedBy 2>/dev/null)" \
    || json="$(gh "${args[@]}" --json number,title,state,assignees,body,comments)" \
    || die "couldn't read the GitHub board (gh issue list)"
  jq '
    def field($s; $k): ($s // "") | (capture("(?m)^\\*\\*" + $k + ":\\*\\* *(?<v>[^\\n]*)").v // "");
    def first: split(" ")[0] // "";
    [ .[] | select(.title | test("^[0-9]+:")) |
      ([.comments[]? | select(.body | test("(?m)^\\*\\*Branch:\\*\\*"))] | last | .body // "") as $rs |
      { nn: (.title | capture("^(?<n>[0-9]+):").n),
        title: (.title | sub("^[0-9]+: *"; "")),
        ref: "#\(.number)", issue: .number, file: null,
        status: (if .state == "CLOSED" then "resolved"
                 elif ((.assignees | length) > 0 or $rs != "") then "in-progress" else "open" end),
        branch: (field($rs; "Branch") | first), base: (field($rs; "Base") | first),
        model: (field($rs; "Model") | first), effort: (field($rs; "Effort") | first),
        account: (field($rs; "Account") | first), agent: (field($rs; "Agent") | first),
        worktree: (field($rs; "Worktree") | first),
        blocked_raw: field(.body; "Blocked by"),
        smodel: (field(.body; "Suggested model") | first), seffort: (field(.body; "Suggested effort") | first),
        parent: (field(.body; "Parent") | first | ascii_downcase),
        native_blockers: (if .blockedBy then [.blockedBy.nodes[]? | {issue: .number, open: (.state == "OPEN")}] else null end) } ]
  ' <<<"$json"
}

# Sets BOARD_JSON: the parsed board with blockers resolved to ticket numbers and
# `unknown_refs` listing anything in a Blocked-by line that matched nothing.
load_board() {
  local raw
  if [[ "$BOARD_KIND" == file ]]; then raw="$(load_file_board)"; else raw="$(load_github_board)"; fi
  BOARD_JSON="$(jq '
    (map({key: (.issue | tostring), value: .nn}) | from_entries) as $by_issue |
    (map(.nn) ) as $nns |
    def norm: tostring | ltrimstr("0") | if . == "" then "0" else . end;
    (map({key: (.nn | norm), value: .nn}) | from_entries) as $by_num |
    map(
      . as $t |
      (if ($t.native_blockers // []) | length > 0
       then [ $t.native_blockers[] | {ref: "#\(.issue)", nn: $by_issue[(.issue | tostring)]} ]
       elif ($t.blocked_raw | test("[0-9]") | not)   # "None (can start immediately)", empty
       then []
       else [ $t.blocked_raw | scan("#?[0-9]+") |
              if startswith("#") then {ref: ., nn: $by_issue[ltrimstr("#")]}
              else {ref: ., nn: $by_num[norm]} end ]
       end) as $refs |
      . + { blockers: [ $refs[] | select(.nn) | .nn ] | unique,
            unknown_refs: [ $refs[] | select(.nn | not) | .ref ] }
    ) | sort_by(.nn | tonumber)
  ' <<<"$raw")"
}

# The ticket object for one number, or die.
ticket_json() {
  local nn="$1" t
  t="$(jq -c --arg n "$nn" 'map(select((.nn | tonumber) == ($n | tonumber))) | first // empty' <<<"$BOARD_JSON")"
  [[ -n "$t" ]] || die "no ticket $nn on board $BOARD_ID"
  echo "$t"
}

# ---- has it landed? --------------------------------------------------------------

# Prints yes:<how> | no | unknown:<why>. Needs ROOT, REMOTE, BASE_BRANCH and a
# fetch already done. The empty-branch guard comes first: a freshly launched
# branch sits *at* the base, and ancestry would call it merged.
landed() {
  local branch="$1" base_sha="$2" count pr
  [[ -n "$branch" ]] || { echo "-"; return; }
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" || {
    # A deleted local branch can still have a merged PR.
    pr="$(gh pr list --head "$branch" --state merged --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    [[ -n "$pr" ]] && echo "yes:pr#$pr" || echo "unknown:no-local-branch"; return; }
  [[ -n "$base_sha" ]] || base_sha="$(git -C "$ROOT" merge-base "$branch" "$REMOTE/$BASE_BRANCH" 2>/dev/null || true)"
  if ! count="$(git -C "$ROOT" rev-list --count "$base_sha..$branch" 2>/dev/null)"; then
    echo "unknown:base-unresolvable"; return
  fi
  if [[ "$count" -eq 0 ]]; then echo "no"; return; fi
  if git -C "$ROOT" merge-base --is-ancestor "$branch" "$REMOTE/$BASE_BRANCH" 2>/dev/null \
     || git -C "$ROOT" merge-base --is-ancestor "$branch" "$BASE_BRANCH" 2>/dev/null; then
    echo "yes:ancestry"; return
  fi
  pr="$(gh pr list --head "$branch" --state merged --json number --jq '.[0].number // empty' 2>/dev/null || true)"
  [[ -n "$pr" ]] && { echo "yes:pr#$pr"; return; }
  echo "no"
}

# name<TAB>state<TAB>tab for every Herdr agent. Fails when Herdr can't be asked,
# so a caller can tell "no agents" (an orphaned ticket) from "don't know".
agent_states() {
  command -v herdr >/dev/null 2>&1 || return 1
  local j; j="$(herdr agent list 2>/dev/null)" || return 1
  jq -r '.result.agents[]? | select(.name) | "\(.name)\t\(.agent_status // "unknown")\t\(.tab_id // "-")"' <<<"$j" 2>/dev/null
}

# Every board script starts the same way.
board_init() {
  REMOTE="${TICKET_REMOTE:-origin}"
  need git; need jq
  resolve_repo_root
  resolve_base_branch
  resolve_board "${1:-}"
  load_board
}
