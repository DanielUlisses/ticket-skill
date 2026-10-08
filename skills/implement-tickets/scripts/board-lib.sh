#!/usr/bin/env bash
# The board, as data — shared by the /implement-tickets scripts.
#
# Sourced, never executed. The board session runs on a small model with a small
# prompt (docs/adr/0004-haiku-board-session.md), which only works if everything
# mechanical about a board lives here instead of in prose the model has to
# execute faithfully: finding the board, parsing tickets out of either home,
# resolving free-text blockers, and answering "has this branch landed".
#
# Boards live in one home: files under <root>/.scratch/<board>/ (ADR 0005 dropped
# GitHub-issue boards). PRs live on the repo's forge — GitHub or Azure DevOps —
# which is a merge question, not a board one; the forge layer below answers it.
#
# Requires ticket-git-repo.sh (die/log/need, resolve_repo_root,
# resolve_base_branch, run_git_net) to have been sourced first.
#
# The one output shape is BOARD_JSON: an array of tickets, ordered by number,
#   {nn, title, ref, file, status, branch, base, model, effort, account,
#    agent, blocked_raw, blockers:[nn], smodel, seffort, parent}
# plus BOARD_ID (what to pass back to every script), BOARD_SLUG (a path-safe
# name for state files) and BOARD_PATH.

JIRA_RE='^[A-Za-z][A-Za-z0-9]+-[0-9]+$'

board_state_dir() {
  local d="${XDG_STATE_HOME:-$HOME/.local/state}/ticket-skill/$REPO_NAME"
  mkdir -p "$d"; echo "$d"
}

# Sets BOARD_PATH, BOARD_ID, BOARD_SLUG. Needs ROOT. Every ambiguity dies with
# the choices in the message: the model asks the developer and passes the answer
# back, it never guesses.
resolve_board() {
  local arg="${1:-}" dirs
  [[ "$arg" =~ $JIRA_RE ]] && arg="${arg,,}"
  if [[ -z "$arg" ]]; then BOARD_PATH="$ROOT/.scratch"
  elif [[ "$arg" == /* ]]; then BOARD_PATH="$arg"
  elif [[ -e "$ROOT/$arg" ]]; then BOARD_PATH="$ROOT/$arg"
  else BOARD_PATH="$ROOT/.scratch/$arg"
  fi
  [[ -e "$BOARD_PATH" ]] || die "no board '$arg': looked for $BOARD_PATH"
  # A bare .scratch holds one directory per feature; a board is one of them.
  if [[ -d "$BOARD_PATH" && "$(basename "$BOARD_PATH")" == .scratch ]]; then
    dirs="$(find "$BOARD_PATH" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)"
    case "$(grep -c . <<<"$dirs")" in
      0) die "no boards under $BOARD_PATH" ;;
      1) BOARD_PATH="$BOARD_PATH/$dirs" ;;
      *) die "several boards — pass one of: $(tr '\n' ' ' <<<"$dirs")" ;;
    esac
  fi
  BOARD_ID="${BOARD_PATH#"$ROOT"/}"; BOARD_ID="${BOARD_ID#.scratch/}"
  BOARD_SLUG="$(tr '/' '-' <<<"$BOARD_ID" | sed 's/^[.-]*//')"
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
      nn: $v[0], title: $v[1], ref: ($file | split("/") | last), file: $file,
      status: (if $v[2] == "" then "open" else $v[2] end),
      branch: $v[3], base: $v[4], model: $v[5], effort: $v[6], account: $v[7], agent: $v[8],
      blocked_raw: $v[9], smodel: $v[10], seffort: $v[11], parent: $v[12], worktree: $v[13] }'
}

load_file_board() {
  local f files
  if [[ -f "$BOARD_PATH" ]]; then files="$BOARD_PATH"
  else files="$(find "$BOARD_PATH" -name '*.md' -type f | sort)"; fi
  [[ -n "$files" ]] || die "no ticket files under $BOARD_PATH"
  while IFS= read -r f; do parse_ticket_file "$f"; done <<<"$files" | jq -s '.'
}

# Sets BOARD_JSON: the parsed board with blockers resolved to ticket numbers and
# `unknown_refs` listing anything in a Blocked-by line that matched nothing.
load_board() {
  local raw; raw="$(load_file_board)"
  BOARD_JSON="$(jq '
    def norm: tostring | sub("^0+"; "") | if . == "" then "0" else . end;
    (map({key: (.nn | norm), value: .nn}) | from_entries) as $by_num |
    map(
      . as $t |
      (if ($t.blocked_raw | test("[0-9]") | not)   # "None (can start immediately)", empty
       then []
       else [ $t.blocked_raw | gsub("\\([^)]*\\)"; "") | scan("[0-9]+") | {ref: ., nn: $by_num[norm]} ]
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

# Prints yes:<how> | no | unknown:<why>. Needs ROOT, BASE_BRANCH, BASE_REF and
# HAS_REMOTE from board_init, and a fetch already done where there is a remote
# (fetch_ticket_branches too, for the remote side of each branch).
# Asks, in order, of the local branch and of its remote-tracking copy (a PR
# pushed or fixed from elsewhere ends up only there): is it an ancestor of the
# base (a merge commit or a fast-forward); is everything it changed already in a
# commit on the base (a squash or a rebase — what Azure DevOps and GitHub both
# default to, and invisible to ancestry). Then the forge: a merged PR from the
# branch. The git checks need no forge, so a PR merged in the web UI resolves
# even where gh or az can't be asked. A branch with nothing committed sits *at*
# the base, where both git checks would call it merged, so it is "no".
# LANDED_TRACE=1 explains each step on stderr (tk.sh why); LANDED_ERRS names a
# file the forge's errors are appended to (tk.sh digest warns once from it).
landed() {
  local branch="$1" base_sha="$2" count pr="" t err sha
  local -a tips=() refs=()
  _lt() { [[ "${LANDED_TRACE:-0}" == 1 ]] && echo "  $*" >&2; return 0; }
  [[ -n "$branch" ]] || { echo "-"; return; }
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" && refs+=("$branch")
  (( HAS_REMOTE )) && git -C "$ROOT" show-ref --verify --quiet "refs/remotes/$REMOTE/$branch" && refs+=("$REMOTE/$branch")
  _lt "branch $branch: ${refs[*]:-no local or remote-tracking ref}"
  if [[ -z "$base_sha" && ${#refs[@]} -gt 0 ]]; then
    base_sha="$(git -C "$ROOT" merge-base "${refs[0]}" "$BASE_REF" 2>/dev/null || true)"
  fi
  _lt "base: ${base_sha:-?} → $BASE_REF ($(git -C "$ROOT" rev-parse --short "$BASE_REF" 2>/dev/null || echo ?))"
  for t in "${refs[@]}"; do
    if ! count="$(git -C "$ROOT" rev-list --count "$base_sha..$t" 2>/dev/null)"; then
      _lt "$t: base unresolvable"; continue
    fi
    _lt "$t: $count commit(s) since base, tip $(git -C "$ROOT" rev-parse --short "$t")"
    (( count > 0 )) && tips+=("$t")
  done
  for t in "${tips[@]}"; do
    if git -C "$ROOT" merge-base --is-ancestor "$t" "$BASE_REF" 2>/dev/null \
       || git -C "$ROOT" merge-base --is-ancestor "$t" "$BASE_BRANCH" 2>/dev/null; then
      _lt "$t: an ancestor of $BASE_REF — merged"; echo "yes:ancestry"; return
    fi
    _lt "$t: not an ancestor of $BASE_REF"
    sha="$(landing_commit "$t" "$BASE_REF" "$base_sha")"
    if [[ -n "$sha" ]]; then _lt "$t: every change is in $sha — squashed or rebased"; echo "yes:squash:$sha"; return; fi
    _lt "$t: no commit on $BASE_REF contains all its changes"
  done
  if (( ${#tips[@]} > 0 || ${#refs[@]} == 0 )) && forge_ok; then
    if pr="$(forge_merged_pr "$branch" 2>>"${LANDED_ERRS:-/dev/null}")"; then
      _lt "$(forge_name): ${pr:+merged PR #$pr}${pr:-no merged PR from $branch}"
      [[ -n "$pr" ]] && { echo "yes:pr#$pr"; return; }
    else
      _lt "$(forge_name) couldn't be asked${LANDED_ERRS:+ — see the WARN}"
    fi
  elif (( HAS_REMOTE )); then
    _lt "$(forge_name): not asked ($( ((${#tips[@]})) && echo "its CLI isn't available" || echo "nothing committed"))"
  fi
  (( ${#refs[@]} )) || { echo "unknown:no-local-branch"; return; }
  (( ${#tips[@]} )) || { [[ -n "$base_sha" ]] && echo "no" || echo "unknown:base-unresolvable"; return; }
  echo "no"
}

# Brings each in-progress ticket's remote branch up to date, best effort — one
# deleted after its merge just keeps its last-fetched copy.
fetch_ticket_branches() {
  (( HAS_REMOTE )) || return 0
  local b
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    run_git_net fetch "$REMOTE" "+refs/heads/$b:refs/remotes/$REMOTE/$b" --quiet 2>/dev/null || true
  done < <(jq -r '.[] | select(.status == "in-progress") | .branch' <<<"$BOARD_JSON")
}

# Is every change on <tip> already in commit <c>? True at a squash commit, or the
# last commit of a rebase: merging the branch there changes nothing — the merged
# tree is <c>'s own (git 2.38+, merge-tree --write-tree). Older git: every file
# the branch touched since <base> reads the same at <c>.
contained() {
  local tip="$1" c="$2" base="$3" tree
  if tree="$(git -C "$ROOT" merge-tree --write-tree --no-messages "$c" "$tip" 2>/dev/null)"; then
    [[ "$tree" == "$(git -C "$ROOT" rev-parse "$c^{tree}")" ]]; return
  fi
  git -C "$ROOT" merge-tree --write-tree "$c" "$c" >/dev/null 2>&1 && return 1   # new git: a real conflict
  git -C "$ROOT" diff --quiet "$tip" "$c" -- "${LANDING_FILES[@]}"
}

# The short sha on <ref> where <tip>'s changes arrived, or nothing: the oldest
# commit after <base> that contains them all. Each candidate is checked itself,
# not <ref>'s head, because the base may have moved on and edited the same files
# since — a merge against the head would then re-apply the branch's change and
# miss the squash. Only commits touching the branch's files can be it, which
# keeps this to a handful of merge-tree runs.
landing_commit() {
  local tip="$1" ref="$2" base="$3" c files
  files="$(git -C "$ROOT" diff --name-only "$base" "$tip" 2>/dev/null)" && [[ -n "$files" ]] || return 0
  mapfile -t LANDING_FILES <<<"$files"
  [[ "${LANDED_TRACE:-0}" == 1 ]] && echo "  $tip: ${#LANDING_FILES[@]} file(s) changed; $(git -C "$ROOT" rev-list --count --max-count=300 "$base..$ref" -- "${LANDING_FILES[@]}" 2>/dev/null || echo ?) commit(s) on $ref touch them; $(git -C "$ROOT" merge-tree --write-tree "$ref" "$ref" >/dev/null 2>&1 && echo "merge-tree check" || echo "file-compare check (git < 2.38)")" >&2
  while IFS= read -r c; do
    contained "$tip" "$c" "$base" && { git -C "$ROOT" rev-parse --short "$c"; return; }
  done < <(git -C "$ROOT" rev-list --reverse --max-count=300 "$base..$ref" -- "${LANDING_FILES[@]}" 2>/dev/null)
  return 0
}

# name<TAB>state<TAB>tab for every Herdr agent. Fails when Herdr can't be asked,
# so a caller can tell "no agents" (an orphaned ticket) from "don't know".
agent_states() {
  command -v herdr >/dev/null 2>&1 || return 1
  local j; j="$(herdr agent list 2>/dev/null)" || return 1
  jq -r '.result.agents[]? | select(.name) | "\(.name)\t\(.agent_status // "unknown")\t\(.tab_id // "-")"' <<<"$j" 2>/dev/null
}

# The gate for anything that writes in a ticket's worktree: only when its agent
# is idle, done or gone (or none was recorded). Fails closed — working, at a
# dialog, a state Herdr didn't classify, or Herdr not answering all refuse.
require_agent_quiet() {
  local agent="$1" what="$2" states st
  [[ -n "$agent" ]] || return 0
  states="$(agent_states)" || die "Herdr didn't answer — can't tell whether $agent is working; not $what"
  st="$(awk -F'\t' -v a="$agent" '$1 == a {print $2}' <<<"$states")"
  case "${st:-gone}" in
    idle|done|gone) return 0 ;;
    working) die "$agent is working — wait until it's idle before $what" ;;
    blocked) die "$agent is waiting at a dialog — the developer answers it before $what" ;;
    *)       die "$agent is in state '$st' — not $what until it's idle" ;;
  esac
}

# Every board script starts the same way.
board_init() {
  REMOTE="${TICKET_REMOTE:-origin}"
  need git; need jq
  resolve_repo_root
  resolve_base_branch
  # A repo with no remote (a presales document repo, say) has only its local
  # base to merge into, and no PRs to ask about.
  HAS_REMOTE=0; BASE_REF="$BASE_BRANCH"
  if git -C "$ROOT" remote get-url "$REMOTE" >/dev/null 2>&1; then
    HAS_REMOTE=1
    git -C "$ROOT" show-ref --verify --quiet "refs/remotes/$REMOTE/$BASE_BRANCH" && BASE_REF="$REMOTE/$BASE_BRANCH"
  fi
  forge_detect
  resolve_board "${1:-}"
  load_board
}

# ---- the forge: where PRs live ---------------------------------------------------
# GitHub (gh) or Azure DevOps (az + its azure-devops extension), picked from the
# remote's URL; TICKET_FORGE=github|azure overrides it. Every caller reads one PR
# shape, whichever forge answered:
#   {number, url, isDraft, base, mergeable: MERGEABLE|CONFLICTING|UNKNOWN,
#    review: APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED|"", checks: [{n, s: ok|pending|bad}]}
# so the gates, the merge, the landing check, the status board and pr-open.sh
# never call gh or az themselves.

# Sets FORGE (github|azure|none) and, for Azure, AZ_ORG / AZ_PROJECT / AZ_REPO
# parsed from the remote — passed explicitly, so a remote not named origin works.
forge_detect() {
  FORGE=none; AZ_ORG=""; AZ_PROJECT=""; AZ_REPO=""
  (( HAS_REMOTE )) || return 0
  local url; url="$(git -C "$ROOT" remote get-url "$REMOTE")"
  case "${TICKET_FORGE:-}" in
    github|azure) FORGE="$TICKET_FORGE" ;;
    "") if [[ "$url" =~ (dev\.azure\.com|visualstudio\.com) ]]; then FORGE=azure; else FORGE=github; fi ;;
    *) die "TICKET_FORGE is '$TICKET_FORGE' — github or azure" ;;
  esac
  [[ "$FORGE" == azure ]] || return 0
  local re_https='^https?://([^@/]+@)?dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/?#]+)'
  local re_vs='^https?://([^@/]+@)?([^./]+)\.visualstudio\.com/(DefaultCollection/)?([^/]+)/_git/([^/?#]+)'
  local re_ssh='^([^@]+@)?(ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com):v3/([^/]+)/([^/]+)/([^/]+)$'
  local re_https1='^https?://([^@/]+@)?dev\.azure\.com/([^/]+)/_git/([^/?#]+)'
  local re_vs1='^https?://([^@/]+@)?([^./]+)\.visualstudio\.com/(DefaultCollection/)?_git/([^/?#]+)'
  if [[ "$url" =~ $re_https1 ]]; then   # no project in the URL: it is named after the repo
    AZ_ORG="https://dev.azure.com/${BASH_REMATCH[2]}"; AZ_PROJECT="${BASH_REMATCH[3]}"; AZ_REPO="${BASH_REMATCH[3]}"
  elif [[ "$url" =~ $re_vs1 ]]; then
    AZ_ORG="https://${BASH_REMATCH[2]}.visualstudio.com"; AZ_PROJECT="${BASH_REMATCH[4]}"; AZ_REPO="${BASH_REMATCH[4]}"
  elif [[ "$url" =~ $re_https ]]; then
    AZ_ORG="https://dev.azure.com/${BASH_REMATCH[2]}"; AZ_PROJECT="${BASH_REMATCH[3]}"; AZ_REPO="${BASH_REMATCH[4]}"
  elif [[ "$url" =~ $re_vs ]]; then
    AZ_ORG="https://${BASH_REMATCH[2]}.visualstudio.com"; AZ_PROJECT="${BASH_REMATCH[4]}"; AZ_REPO="${BASH_REMATCH[5]}"
  elif [[ "$url" =~ $re_ssh ]]; then
    AZ_ORG="https://dev.azure.com/${BASH_REMATCH[3]}"; AZ_PROJECT="${BASH_REMATCH[4]}"; AZ_REPO="${BASH_REMATCH[5]}"
  fi
  AZ_REPO="${AZ_REPO%.git}"; AZ_PROJECT="${AZ_PROJECT%.git}"; AZ_PROJECT="${AZ_PROJECT//%20/ }"; AZ_REPO="${AZ_REPO//%20/ }"
}

# Quiet: can the forge be asked at all? (The landing check and the status board
# just skip it when not.)
forge_ok() {
  case "${FORGE:-none}" in
    github) command -v gh >/dev/null 2>&1 ;;
    azure)  command -v az >/dev/null 2>&1 && [[ -n "$AZ_ORG" ]] ;;
    *) return 1 ;;
  esac
}

# Loud: what a PR verb needs, or why it can't run.
forge_need() {
  case "$FORGE" in
    github) need gh ;;
    azure)
      need az
      [[ "${TICKET_AZURE_MERGE:-squash}" =~ ^(squash|merge)$ ]] || die "TICKET_AZURE_MERGE is '$TICKET_AZURE_MERGE' — squash or merge"
      [[ -n "$AZ_ORG" ]] || die "can't read an Azure DevOps org/project/repo from the '$REMOTE' remote ($(git -C "$ROOT" remote get-url "$REMOTE"))"
      az extension show --name azure-devops --only-show-errors >/dev/null 2>&1 \
        || die "the azure-devops extension isn't installed — az extension add --name azure-devops (then az devops login, or set AZURE_DEVOPS_EXT_PAT)" ;;
    *) die "no '$REMOTE' remote in $ROOT — no PRs here" ;;
  esac
}

forge_name() { case "$FORGE" in github) echo GitHub ;; azure) echo "Azure DevOps" ;; *) echo "no forge" ;; esac; }

az_() { az "$@" --org "$AZ_ORG" --output json --only-show-errors; }

# One GitHub PR (from pr list/view --json) into the common shape.
GH_PR_FIELDS=number,url,isDraft,baseRefName,mergeable,reviewDecision,statusCheckRollup
gh_norm() {
  jq -c '{number, url, isDraft, base: .baseRefName,
    mergeable: (if .mergeable == "MERGEABLE" or .mergeable == "CONFLICTING" then .mergeable else "UNKNOWN" end),
    review: (.reviewDecision // ""),
    checks: [.statusCheckRollup[]? |
      if .__typename == "StatusContext" then {n: .context, s: (if .state == "SUCCESS" then "ok" elif (.state == "PENDING" or .state == "EXPECTED") then "pending" else "bad" end)}
      else {n: .name, s: (if .status != "COMPLETED" then "pending"
                          elif (.conclusion == "SUCCESS" or .conclusion == "SKIPPED" or .conclusion == "NEUTRAL") then "ok" else "bad" end)} end]}'
}

# One Azure PR (pr show) plus its policy evaluations (pr policy list) into the
# common shape. Votes: 10 approved, 5 approved with suggestions, 0 none,
# -5 waiting for author, -10 rejected. Reviewer policies feed review; every
# other blocking policy (build validation, status checks, comment resolution,
# linked work items) is a check.
az_norm() {
  local pr="$1" pol="$2"
  jq -cn --argjson p "$pr" --argjson pol "$pol" --arg web "$AZ_ORG/$(jq -rn --arg s "$AZ_PROJECT" '$s|@uri')/_git/$(jq -rn --arg s "$AZ_REPO" '$s|@uri')" '
    def ok_st: . == "approved" or . == "notApplicable";
    def reviewer_policy: (.configuration.type.displayName // "") | test("reviewers"; "i");
    ($pol | map(select(.configuration.isBlocking != false and .configuration.isEnabled != false))) as $blocking |
    ($p.reviewers // []) as $rv |
    {number: $p.pullRequestId, url: "\($web)/pullrequest/\($p.pullRequestId)",
     isDraft: ($p.isDraft // false), base: ($p.targetRefName | sub("^refs/heads/"; "")),
     mergeable: (if $p.mergeStatus == "succeeded" then "MERGEABLE" elif $p.mergeStatus == "conflicts" then "CONFLICTING" else "UNKNOWN" end),
     review: (if any($rv[]; (.vote // 0) <= -5) then "CHANGES_REQUESTED"
              elif any($blocking[] | select(reviewer_policy); .status | ok_st | not) then "REVIEW_REQUIRED"
              elif any($rv[]; .isRequired == true and (.vote // 0) < 5) then "REVIEW_REQUIRED"
              elif any($rv[]; (.vote // 0) >= 5) then "APPROVED" else "" end),
     checks: [$blocking[] | select(reviewer_policy | not) |
       {n: (.configuration.settings.displayName // .configuration.type.displayName // "policy"),
        s: (if (.status | ok_st) then "ok" elif .status == "running" or .status == "queued" then "pending" else "bad" end)}]}'
}

az_pr_full() {
  local id="$1" pr pol
  pr="$(az_ repos pr show --id "$id")" || return 1
  pol="$(az_ repos pr policy list --id "$id" 2>/dev/null)" || pol='[]'
  az_norm "$pr" "${pol:-[]}"
}

# The open PR from <branch>, in the common shape, or nothing.
forge_pr_open() {
  local branch="$1" id
  case "$FORGE" in
    github)
      local j; j="$(gh pr list --head "$branch" --state open --json "$GH_PR_FIELDS" --jq '.[0] // empty')" || return 1
      [[ -z "$j" ]] || gh_norm <<<"$j" ;;
    azure)
      id="$(az_ repos pr list --project "$AZ_PROJECT" --repository "$AZ_REPO" --source-branch "$branch" --status active | jq -r '.[0].pullRequestId // empty')" || return 1
      [[ -z "$id" ]] || az_pr_full "$id" ;;
    *) return 1 ;;
  esac
}

# PR <id> again, in the common shape (the gates re-ask while mergeability computes).
forge_pr_get() {
  case "$FORGE" in
    github) gh pr view "$1" --json "$GH_PR_FIELDS" | gh_norm ;;
    azure)  az_pr_full "$1" ;;
    *) return 1 ;;
  esac
}

# The id of a merged PR from <branch>, or nothing.
forge_merged_pr() {
  case "$FORGE" in
    github) gh pr list --head "$1" --state merged --json number --jq '.[0].number // empty' ;;
    azure)  az_ repos pr list --project "$AZ_PROJECT" --repository "$AZ_REPO" --source-branch "$1" --status completed | jq -r '.[0].pullRequestId // empty' ;;
    *) return 1 ;;
  esac
}

# Opens a PR; prints its URL. Run from the ticket's worktree.
forge_pr_create() {
  local base="$1" branch="$2" title="$3" body="$4" desc id
  case "$FORGE" in
    github) gh pr create --base "$base" --head "$branch" --title "$title" --body-file "$body" ;;
    azure)
      # Azure caps a description at 4000 characters; the full body stays in the
      # file the agent wrote, so a long one is cut with a note rather than refused.
      desc="$(cat "$body")"
      (( ${#desc} <= 4000 )) || desc="${desc:0:3950}"$'\n\n'"… (truncated at Azure DevOps' 4000-character limit)"
      id="$(az_ repos pr create --project "$AZ_PROJECT" --repository "$AZ_REPO" \
              --source-branch "$branch" --target-branch "$base" --title "$title" --description "$desc" \
            | jq -r '.pullRequestId // empty')"
      [[ -n "$id" ]] || die "az repos pr create returned no PR id"
      forge_pr_get "$id" | jq -r .url ;;
    *) return 1 ;;
  esac
}

# Merges PR <id>; prints the method used. Never bypasses policy or admin rules,
# never deletes the source branch — it's still checked out in the ticket's
# worktree, and /sweep-tickets owns it.
forge_merge() {
  local id="$1" method
  case "$FORGE" in
    github)
      method="$(gh repo view --json viewerDefaultMergeMethod --jq .viewerDefaultMergeMethod | tr '[:upper:]' '[:lower:]')"
      [[ "$method" =~ ^(merge|squash|rebase)$ ]] || method=squash
      gh pr merge "$id" "--$method" >&2 ;;
    azure)
      method="${TICKET_AZURE_MERGE:-squash}"
      [[ "$method" =~ ^(squash|merge)$ ]] || die "TICKET_AZURE_MERGE is '$method' — squash or merge"
      local st
      st="$(az_ repos pr update --id "$id" --status completed --squash "$([[ $method == squash ]] && echo true || echo false)" \
              --delete-source-branch false | jq -r '.status // empty')"
      # Azure merges asynchronously after the update: give it a few seconds, then
      # only "completed" counts — a policy can still refuse it.
      local i; for i in 1 2 3 4 5; do
        [[ "$st" == active ]] || break
        sleep 3; st="$(az_ repos pr show --id "$id" | jq -r '.status // empty')"
      done
      [[ "$st" == completed ]] || die "Azure DevOps didn't complete PR $id (status: ${st:-?}) — a policy may still be pending"
      ;;
    *) return 1 ;;
  esac
  echo "$method"
}

# The short sha PR <id> merged as, or nothing.
forge_merge_commit() {
  case "$FORGE" in
    github) gh pr view "$1" --json mergeCommit --jq '.mergeCommit.oid // ""' ;;
    azure)  az_ repos pr show --id "$1" | jq -r '.lastMergeCommit.commitId // ""' ;;
    *) return 0 ;;
  esac | cut -c1-7
}
