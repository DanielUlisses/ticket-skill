#!/usr/bin/env bash
# /sweep-tickets — list and remove what finished tickets left behind
#
# A ticket launched by /ticket or /implement-tickets leaves five things behind:
# a Herdr workspace, its tabs, its panes, a git worktree, and a branch. This
# script reports all of them and removes them one item at a time. A ticket
# launched with --account leaves a sixth, a claude-acc directory link, which
# `remove --worktree` takes with the worktree (see docs/agents/accounts.md).
#
# Usage:
#   sweep.sh list [--no-fetch]
#   sweep.sh remove --worktree <path> [--keep-branch] [--force]
#   sweep.sh remove --branch <name> [--force]
#   sweep.sh remove --workspace <id> [--force]
#
# `list` writes nothing but remote-tracking refs (it fetches the base branch, as
# /implement-tickets' digest does; --no-fetch skips even that) and works from any
# worktree of the repo. `remove` takes exactly one item per call — there is no
# "remove everything" verb, deliberately: opt-in per item is the whole point.
#
# Leftovers are enumerated from three sources, not two. Git's worktrees and git's
# branches are the obvious two, and between them they miss the most common
# leftover there is: `gh pr merge --delete-branch` takes the directory, git's
# registration and the branch, and leaves the Herdr workspace — its tabs, its
# panes and an idle agent — with nothing on git's side left to find it by. So
# Herdr's own workspace list is the third source, scoped to this repo, and it
# removes with `herdr workspace close <id>` (positional; the --workspace flag
# form is a usage error) because `herdr worktree remove` cannot see a workspace
# whose checkout is gone.
#
# Optional variables:
#   TICKET_REMOTE        (default: origin)
#   TICKET_BASE_BRANCH   (default: the remote's default branch, e.g. main)
#   TICKET_DIGEST_GLOB   (default: /tmp/implement-tickets-digest-*.txt)
#   TICKET_LIB_DIR       — the directory holding the shared ticket-*.sh libraries (default: <skills-dir>)
#
# Exit codes:
#   0 = ok | 1 = error | 2 = skipped, uncommitted changes | 3 = skipped, live agent
#   4 = skipped, branch not merged
#
# `remove --workspace` uses 2 and 3 and never 4: a workspace has no branch of its
# own to classify.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- the shared repo-resolution library --------------------------------------
# It gives this script die/log/need, run_git_net, and — the point of sharing it —
# the very same ROOT and BASE_BRANCH the launchers resolve, which is what the
# guards below rest on when they refuse the main checkout or a dirty worktree.
# ---- the shared libraries ----------------------------------------------------
# Installed one level up from the skill directories (~/.claude/skills/ticket-*.sh),
# where config/models.env also lands; in this repo's source tree they are in lib/.
# TICKET_LIB_DIR replaces that search outright rather than joining the front of
# it, so a typo in it is an error instead of a silent fall-through to another
# copy. `die` isn't defined until the libraries are sourced, so these errors are
# raw. Every script that sources them uses this block verbatim, bar the list.
if [[ -n "${TICKET_LIB_DIR:-}" ]]; then
  LIB_DIR="$TICKET_LIB_DIR"
else
  for d in "$(dirname "$SKILL_DIR")" "$(dirname "$(dirname "$SKILL_DIR")")/lib"; do
    [[ -f "$d/ticket-git-repo.sh" ]] && { LIB_DIR="$d"; break; }
  done
fi
for lib in ticket-git-repo.sh ticket-account.sh; do
  [[ -f "${LIB_DIR:-}/$lib" ]] \
    || { echo "ERROR: shared library $lib not found in ${LIB_DIR:-<no library directory found next to $SKILL_DIR>} — re-run install.sh, or set TICKET_LIB_DIR" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$LIB_DIR/$lib"
done

REMOTE="${TICKET_REMOTE:-origin}"

need git
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
HAVE_GH=0; command -v gh >/dev/null 2>&1 && HAVE_GH=1
# Herdr is only reachable from inside a Herdr pane; outside one, the sweep still
# reports git's side of the leftovers rather than refusing to run.
#
# HERDR_WHY names which of the three conditions failed, because with Herdr
# unreachable a whole source of leftovers — the orphaned workspaces below — goes
# unenumerated, and "nothing left behind" would then be a lie. A listing that
# can't see that source has to say so, and say why.
HAVE_HERDR=0; HERDR_WHY=""
if [[ "${HERDR_ENV:-}" != 1 ]]; then
  HERDR_WHY="not running inside a Herdr pane (HERDR_ENV is not 1)"
elif ! command -v herdr >/dev/null 2>&1; then
  HERDR_WHY="the 'herdr' command is not in PATH"
elif [[ $HAVE_JQ -ne 1 ]]; then
  HERDR_WHY="'jq' is not installed, and Herdr only speaks JSON"
else
  HAVE_HERDR=1
fi

# ---- the repo, from wherever this is run ------------------------------------
# Sets ROOT (the main checkout, so a sweep run from a ticket's own worktree
# resolves what one run from the checkout would), REPO_NAME, and SELF.
resolve_repo_root

# The directory the launchers cut worktrees into (`<parent>/<repo>--<branch>`),
# derived once because `ws_is_ours` asks about it per workspace.
ROOT_PARENT="$(dirname "$ROOT")"

# `<owner>/<repo>` for `gh --repo`, derived once. A function caching into a global
# wouldn't: every call site is a `$(...)`, so the assignment would die with the
# subshell and the sed would re-run per branch — the same trap `launch.sh` calls
# out for `die` inside a command substitution. Where it can't be derived, gh is
# treated as unavailable, so leg 2 reports `unknown` rather than a false `unmerged`.
GH_REPO="$(git -C "$ROOT" config --get "remote.$REMOTE.url" 2>/dev/null \
  | sed -E 's#^git@[^:]+:#https://host/#; s#\.git$##; s#^.*[/:]([^/]+/[^/]+)$#\1#')"
[[ "$GH_REPO" == */* ]] || { GH_REPO=""; HAVE_GH=0; }

# The digests /implement-tickets writes, narrowed to this repo: its slug is
# `<owner>-<repo>` (plus the label) for a GitHub board and the board path for a
# file board, so both carry the repo name. `*.txt` alone would also pick up the
# `.new.txt` that skill writes and `mv`s mid-round, and a round killed between
# the two leaves one behind.
DIGEST_GLOB="${TICKET_DIGEST_GLOB:-/tmp/implement-tickets-digest-*${REPO_NAME}*.txt}"

resolve_base_branch

# The ref every merge question is asked against: the remote's base where it
# exists (a merge the developer hasn't pulled is still a merge), the local one
# otherwise.
if git -C "$ROOT" show-ref --verify --quiet "refs/remotes/$REMOTE/$BASE_BRANCH"; then
  BASE_REF="$REMOTE/$BASE_BRANCH"
else
  BASE_REF="$BASE_BRANCH"
fi

# ---- git facts about one branch ---------------------------------------------

# Commits made *on* this branch since it was created, from its reflog. This is
# what tells a branch whose work has landed apart from one that was cut minutes
# ago and never committed — the two are indistinguishable by ancestry, because
# both are ancestors of the base. /implement-tickets' digest reads the `**Base:**`
# sha from run state to make the same distinction; the sweep has no run state to
# read, and the reflog's creation entry is the same fact recorded by git itself.
branch_own_commits() {
  local branch="$1" created
  created="$(git -C "$ROOT" reflog show --format='%H' "$branch" 2>/dev/null | tail -1)"
  if [[ -n "$created" ]]; then
    git -C "$ROOT" rev-list --count "$created..$branch" 2>/dev/null || echo unknown
  else
    # No reflog (a branch fetched rather than created here) — fall back to the
    # count against the base, which over-reports "empty" only for a branch cut
    # from an older base and never committed to.
    git -C "$ROOT" rev-list --count "$BASE_REF..$branch" 2>/dev/null || echo unknown
  fi
}

# Whether this branch's work is in the base, and on what evidence. Ancestry alone
# is never proof: every PR in repos using GitHub's default is squash-merged, which
# rewrites the commits and leaves merge-base nothing to find. So three legs run,
# and the first that answers wins.
BRANCH_STATE=""; BRANCH_REASON=""
classify_branch() {
  local branch="$1" own
  BRANCH_STATE="unknown"; BRANCH_REASON="-"

  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" || {
    BRANCH_STATE="unknown"; BRANCH_REASON="no-such-branch"; return 0; }

  own="$(branch_own_commits "$branch")"

  # Nothing was ever committed here, so there is nothing to have merged and
  # nothing to lose. Both halves are needed: the reflog says no commit was made
  # on the branch, and ancestry says everything it points at is already in the
  # base — so a branch cut from somewhere other than the base, whose reflog shows
  # no commits of its own but whose tip carries unlanded work, falls through to
  # the merge legs below instead of being called empty.
  if [[ "$own" == "0" ]] && git -C "$ROOT" merge-base --is-ancestor "$branch" "$BASE_REF" 2>/dev/null; then
    BRANCH_STATE="empty"; BRANCH_REASON="no-commits"; return 0
  fi

  # Leg 1 — ancestry, against the remote base and then the local one. A merge the
  # developer hasn't pushed is visible only against the local base.
  if git -C "$ROOT" merge-base --is-ancestor "$branch" "$BASE_REF" 2>/dev/null; then
    BRANCH_STATE="merged"; BRANCH_REASON="ancestor:$BASE_REF"; return 0
  fi
  if [[ "$BASE_REF" != "$BASE_BRANCH" ]] \
    && git -C "$ROOT" merge-base --is-ancestor "$branch" "$BASE_BRANCH" 2>/dev/null; then
    BRANCH_STATE="merged"; BRANCH_REASON="ancestor:$BASE_BRANCH"; return 0
  fi

  # Leg 2 — the merged PR for this branch. Scoped to --head, never a board-wide
  # `gh pr list --state merged --limit <n>`, which silently loses any branch that
  # merged beyond the newest <n> PRs.
  if [[ $HAVE_GH -eq 1 ]]; then
    local pr
    pr="$(gh pr list --repo "$GH_REPO" --head "$branch" --state merged --limit 1 \
            --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    if [[ -n "$pr" ]]; then
      BRANCH_STATE="merged"; BRANCH_REASON="pr#$pr"; return 0
    fi
  fi

  # Leg 3 — patch ids. `git cherry` marks a commit `-` when a commit with the same
  # patch id is already upstream, which catches a rebase merge (and a squash of a
  # single commit) with no network and no gh.
  local cherry
  cherry="$(git -C "$ROOT" cherry "$BASE_REF" "$branch" 2>/dev/null || true)"
  if [[ -n "$cherry" ]] && ! grep -q '^+' <<<"$cherry"; then
    BRANCH_STATE="merged"; BRANCH_REASON="patch-id"; return 0
  fi

  if [[ $HAVE_GH -eq 1 ]]; then
    BRANCH_STATE="unmerged"; BRANCH_REASON="no-merged-pr"
  else
    # Without gh, a squash merge of several commits is undetectable — say so
    # rather than calling it unmerged, because the two lead to different actions.
    BRANCH_STATE="unknown"; BRANCH_REASON="no-gh"
  fi
}

# ---- Herdr's side: which workspace holds which worktree, and who is alive ----
declare -A WS_OF_PATH=()   # worktree path -> herdr workspace id
declare -A AGENT_OF_WS=()  # herdr workspace id -> "<name-or-kind>:<status>"
declare -A AGENT_OF_CWD=() # agent cwd -> "<name-or-kind>:<status>"

# Herdr's whole workspace list, which is machine-wide: most of these belong to
# other repos and `ws_is_ours` is what keeps them out of this repo's listing.
WS_IDS=()                  # every workspace id Herdr reported, in its own order
declare -A WS_LABEL=()     # id -> the label shown in the sidebar
declare -A WS_PATH=()      # id -> worktree.checkout_path, "" when it has none
declare -A WS_ROOT=()      # id -> worktree.repo_root, "" when it has none
HERDR_WS_OK=0              # 1 once `herdr workspace list` has actually answered

# The workspace this session is sitting in, resolved once and refused by id as
# well as by path. Resolving it needs both Herdr calls: `worktree list` answers
# it through git, and `workspace list` answers it when git no longer can — which
# is exactly the state an orphan row is emitted for, and the state in which this
# session's own workspace would otherwise become an option that closes the pane
# the developer is sitting in.
SELF_WS=""

load_herdr() {
  [[ $HAVE_HERDR -eq 1 ]] || return 0
  local json line p w id
  # Reset first. Every array below is filled with `+=` or by key, so a second
  # call in one process would append a duplicate of everything rather than
  # refresh it. Nothing calls this twice today; this is what keeps that from
  # being a silent trap the day something does.
  WS_OF_PATH=(); AGENT_OF_WS=(); AGENT_OF_CWD=()
  WS_IDS=(); WS_LABEL=(); WS_ROOT=(); WS_PATH=(); SELF_WS=""; HERDR_WS_OK=0

  json="$(herdr worktree list --cwd "$ROOT" 2>/dev/null || true)"
  while IFS=$'\t' read -r p w; do
    [[ -n "$p" && -n "$w" && "$w" != "null" ]] && WS_OF_PATH["$p"]="$w"
  done < <(jq -r '.result.worktrees[]? | [.path, (.open_workspace_id // "")] | @tsv' <<<"$json" 2>/dev/null || true)
  SELF_WS="${WS_OF_PATH[$SELF]:-}"

  # The third source. `herdr worktree list` is keyed on git — it asks git for the
  # repo's worktrees and then says which of them a workspace is open for — so a
  # workspace whose checkout git has forgotten is absent from it. `workspace list`
  # is keyed on nothing but Herdr's own state, and it keeps the `worktree` block
  # (checkout_path, repo_root) it was created with even after the checkout is
  # deleted. That is what makes the orphan findable at all.
  json="$(herdr workspace list 2>/dev/null || true)"
  while IFS=$'\t' read -r id line p w; do
    [[ -n "$id" ]] || continue
    WS_IDS+=("$id"); WS_LABEL["$id"]="$line"; WS_PATH["$id"]="$p"; WS_ROOT["$id"]="$w"
    HERDR_WS_OK=1
  done < <(jq -r '
      .result.workspaces[]?
      | [ (.workspace_id // "")
        , (.label // "")
        , (.worktree.checkout_path // "")
        , (.worktree.repo_root // "") ]
      | @tsv' <<<"$json" 2>/dev/null || true)

  # The second half of resolving SELF_WS, for the case git can't answer: this
  # worktree's own registration being gone is the very condition that puts a
  # workspace in the orphan group.
  if [[ -z "$SELF_WS" ]]; then
    for id in ${WS_IDS[@]+"${WS_IDS[@]}"}; do
      [[ "${WS_PATH[$id]:-}" == "$SELF" ]] && { SELF_WS="$id"; break; }
    done
  fi

  json="$(herdr agent list 2>/dev/null || true)"
  while IFS=$'\t' read -r w p line; do
    [[ -n "$w" ]] && AGENT_OF_WS["$w"]="$line"
    [[ -n "$p" ]] && AGENT_OF_CWD["$p"]="$line"
  done < <(jq -r '
      .result.agents[]?
      | [ (.workspace_id // "")
        , (.cwd // "")
        , ((.name // .agent // "agent") + ":" + (.agent_status // "unknown")) ]
      | @tsv' <<<"$json" 2>/dev/null || true)

  # A `while` loop returns the status of the last command run in its body, and
  # every one of these bodies ends in a `[[ ]] &&` that is false for a row with a
  # missing field. Without this the function would hand that 1 back to a caller
  # running under `set -e`, which would end the sweep on nothing worse than an
  # agent Herdr reported without a cwd.
  return 0
}

# Whether a Herdr workspace is this repo's to offer. `herdr workspace list` is
# machine-wide: this machine carries workspaces for appofapps, terragrunt,
# helm-charts and others at any moment, and offering one of those for closing is
# the one failure this source must never have. So the question is asked
# conservatively, and a workspace that can't be proved ours is simply not ours.
#
# Herdr's own `repo_root` is authoritative wherever it has one — it records the
# repo the workspace was cut from, and it survives the checkout being deleted,
# which is the whole case this source exists for. Only where Herdr recorded a
# checkout path with no repo alongside it does the launcher's path convention
# answer instead: `<parent>/<repo>--<branch>`, which names this repo in the
# directory name itself.
#
# "Somewhere under the repo's parent" is deliberately *not* one of the answers.
# Every sibling repo of this one lives under that parent too, so it would match
# another project's checkout exactly as readily as this one's.
ws_is_ours() {  # <repo_root> <checkout path>
  local root="$1" path="$2"
  [[ -n "$root" ]] && { [[ "$root" == "$ROOT" ]]; return; }
  [[ -n "$path" ]] || return 1
  [[ "$path" == "$ROOT" ]] && return 0
  [[ "$path" == "$ROOT_PARENT/${REPO_NAME}--"* ]]
}

# "none" is an answer, not a shrug: it means Herdr was asked and returned nothing
# for this worktree. Where Herdr can't be reached at all the cell reads "unknown",
# so a row never claims a dead agent on the strength of a missing CLI.
agent_for_ws() {  # <workspace id> <cwd> -> "<name>:<status>" | "none" | "unknown"
  local ws="$1" path="${2:-}"
  [[ $HAVE_HERDR -eq 1 ]] || { printf 'unknown'; return 0; }
  if [[ -n "$ws" && -n "${AGENT_OF_WS[$ws]:-}" ]]; then printf '%s' "${AGENT_OF_WS[$ws]}"; return 0; fi
  if [[ -n "$path" && -n "${AGENT_OF_CWD[$path]:-}" ]]; then printf '%s' "${AGENT_OF_CWD[$path]}"; return 0; fi
  printf 'none'
}

agent_for() {  # <worktree path> -> "<name>:<status>" | "none" | "unknown"
  agent_for_ws "${WS_OF_PATH[$1]:-}" "$1"
}

# The flag an agent cell earns, so the two row loops that report an agent can't
# drift into describing the same cell differently.
agent_flag() {  # <agent cell> -> "no-agent" | "agent-unknown" | "agent-idle" | "agent-busy"
  case "$1" in
    none)    printf 'no-agent' ;;
    unknown) printf 'agent-unknown' ;;
    *)       if agent_busy "$1"; then printf 'agent-busy'; else printf 'agent-idle'; fi ;;
  esac
}

# Whether an agent is doing something that removing its pane would interrupt.
# This is the distinction that decides whether a leftover is offered at all, and
# getting it wrong the other way makes the sweep useless: the ordinary state of a
# ticket whose PR has merged is an agent still sitting in its pane at `idle` or
# `done`, having finished its implement-and-review pass hours ago. Requiring the
# agent to be *gone* would mean a freshly merged wave — the exact thing this
# command exists to clear — offers nothing at all.
#
# `unknown` counts as busy: Herdr's own rule is that it means an agent is present
# but can't be classified confidently, and "does not prove completion".
agent_busy() {  # <agent cell> -> 0 when removing would interrupt something
  local cell="$1"
  # "none" (nobody there) and "unknown" (Herdr unreachable) are whole cells, not
  # `<name>:<status>` pairs, and neither is an agent doing work.
  [[ "$cell" == "none" || "$cell" == "unknown" ]] && return 1
  case "${cell##*:}" in
    working|blocked|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- the board's own answer, if /implement-tickets has left a digest ---------
# Reuse rather than re-derive: the digest already ran an ancestry sweep and an
# agent read for the board it coordinates. Its lines are
# `<NN> <status> <#issue|file> <branch> <agent-state> <landed> <open-blockers>`,
# and the branch in field 4 is what joins them to this sweep. Where the two
# disagree about whether something is finished, the row is flagged rather than
# silently resolved one way — that disagreement is the interesting part.
declare -A BOARD_OF_BRANCH=()
load_board() {
  local f br line
  shopt -s nullglob
  for f in $DIGEST_GLOB; do
    [[ "$f" == *.new.txt ]] && continue
    while read -r br line; do
      [[ -n "$br" && "$br" != "-" ]] && BOARD_OF_BRANCH["$br"]="$line"
    done < <(awk 'NF>=6 && $1 !~ /^#/ { print $4 "\t" $1 ":" $2 ":" $6 }' "$f" 2>/dev/null || true)
  done
  shopt -u nullglob
}

board_disagrees() {  # <board cell> <sweep state>
  local cell="$1" state="$2" status landed
  [[ -n "$cell" && "$cell" != "-" ]] || return 1
  status="$(cut -d: -f2 <<<"$cell")"; landed="$(cut -d: -f3 <<<"$cell")"
  local finished=no
  [[ "$status" == "resolved" ]] && finished=yes
  case "$landed" in yes|true|landed|merged) finished=yes ;; esac
  [[ "$state" == "merged" && "$finished" == "no" ]] && return 0
  [[ "$state" == "unmerged" && "$finished" == "yes" ]] && return 0
  return 1
}

# ---- the worktree inventory --------------------------------------------------
# Parsed once into four parallel arrays, so `list` and `remove` see one inventory.
WT_PATHS=(); WT_BRANCHES=(); WT_PRUNABLE=(); WT_MAIN=()
# The same inventory keyed by path, which is the question the workspace source
# asks: does any git worktree still claim this checkout?
declare -A WT_BY_PATH=()
load_worktrees() {
  local path="" branch="" prunable="" first=1
  # Reset first, for the same reason load_herdr does: these are appended to.
  WT_PATHS=(); WT_BRANCHES=(); WT_PRUNABLE=(); WT_MAIN=(); WT_BY_PATH=()
  while IFS= read -r l || [[ -n "$l" ]]; do
    case "$l" in
      worktree\ *) path="${l#worktree }"; branch="-"; prunable="no" ;;
      branch\ refs/heads/*) branch="${l#branch refs/heads/}" ;;
      detached) branch="-" ;;
      prunable*) prunable="yes" ;;
      "")
        if [[ -n "$path" ]]; then
          WT_PATHS+=("$path"); WT_BRANCHES+=("$branch"); WT_PRUNABLE+=("$prunable")
          WT_MAIN+=("$first"); WT_BY_PATH["$path"]=1; first=0; path=""
        fi ;;
    esac
  done < <(git -C "$ROOT" worktree list --porcelain; echo)
}

# `?` is the third answer and it exists for the workspace source: a directory
# that is there but is not a git worktree any more answers `git status` with
# nothing, and counting that as zero would call a directory full of files clean.
# Only `0` and `-` are treated as safe to remove, so `?` holds the item back.
dirty_count() {  # <path> -> porcelain line count, "-" when gone, "?" when not a worktree
  local out rc=0
  [[ -d "$1" ]] || { printf '%s' '-'; return 0; }
  out="$(git -C "$1" status --porcelain 2>/dev/null)" || rc=$?
  [[ $rc -eq 0 ]] || { printf '%s' '?'; return 0; }
  # Empty output is a clean worktree, and has to be answered before grep sees it:
  # a here-string of "" is one empty line, which `grep -c ''` counts as 1.
  [[ -n "$out" ]] || { printf '%s' '0'; return 0; }
  grep -c '' <<<"$out"
}

# ---- list --------------------------------------------------------------------
do_list() {
  local fetch=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-fetch) fetch=0 ;;
      *) die "unknown flag for list: $1" ;;
    esac
    shift
  done

  if [[ $fetch -eq 1 ]]; then
    # Fetch, never pull: a pull needs the root clean and on the base branch, and a
    # listing that breaks on the developer's dirty root isn't one you can run
    # whenever you like.
    run_git_net fetch "$REMOTE" "$BASE_BRANCH" --quiet 2>/dev/null \
      || log "warning: fetch of $REMOTE/$BASE_BRANCH failed — merge answers may be stale"
  fi

  load_worktrees; load_herdr; load_board

  local rows=() i path branch prunable state reason agent dirty ws board flags
  declare -A SEEN_BRANCH=()

  for i in "${!WT_PATHS[@]}"; do
    path="${WT_PATHS[$i]}"; branch="${WT_BRANCHES[$i]}"; prunable="${WT_PRUNABLE[$i]}"
    # Claim the branch before skipping the main checkout, or the root's own
    # branch — whenever it isn't the base — comes back round as a `branch` row
    # offering to delete the branch the developer is standing on.
    [[ "$branch" != "-" ]] && SEEN_BRANCH["$branch"]=1
    [[ "${WT_MAIN[$i]}" == "1" ]] && continue   # the checkout itself is never a leftover

    if [[ "$branch" == "-" ]]; then
      state="unknown"; reason="detached"
    else
      classify_branch "$branch"; state="$BRANCH_STATE"; reason="$BRANCH_REASON"
    fi
    agent="$(agent_for "$path")"
    dirty="$(dirty_count "$path")"
    ws="${WS_OF_PATH[$path]:--}"
    board="${BOARD_OF_BRANCH[$branch]:--}"

    flags=""
    [[ "$state" == "merged" ]] && flags+="orphan,"
    [[ "$state" == "empty" ]] && flags+="never-started,"
    flags+="$(agent_flag "$agent"),"
    [[ "$dirty" != "-" && "$dirty" != "0" ]] && flags+="dirty,"
    [[ "$prunable" == "yes" ]] && flags+="prunable,"
    [[ "$path" == "$SELF" ]] && flags+="self,"
    board_disagrees "$board" "$state" && flags+="board-disagrees,"
    # Exactly the conditions `remove` enforces, so the list never offers an item
    # the script will refuse, nor withholds one it would accept.
    if [[ ( "$state" == "merged" || "$state" == "empty" ) \
          && ( "$dirty" == "0" || "$dirty" == "-" ) && "$path" != "$SELF" ]] \
       && ! agent_busy "$agent"; then
      flags+="removable,"
    else
      flags+="keep,"
    fi

    rows+=("worktree	$branch	$path	$state	$reason	$agent	$dirty	$ws	$board	${flags%,}")
  done

  # Local branches with no worktree of their own — what a `gd` left behind, or a
  # worktree removed by hand without the branch.
  while IFS= read -r branch; do
    [[ -z "$branch" || "$branch" == "$BASE_BRANCH" ]] && continue
    [[ -n "${SEEN_BRANCH[$branch]:-}" ]] && continue
    classify_branch "$branch"; state="$BRANCH_STATE"; reason="$BRANCH_REASON"
    board="${BOARD_OF_BRANCH[$branch]:--}"
    flags=""
    [[ "$state" == "merged" ]] && flags+="merged-branch,"
    [[ "$state" == "empty" ]] && flags+="never-started,"
    board_disagrees "$board" "$state" && flags+="board-disagrees,"
    if [[ "$state" == "merged" || "$state" == "empty" ]]; then flags+="removable,"; else flags+="keep,"; fi
    rows+=("branch	$branch	-	$state	$reason	-	-	-	$board	${flags%,}")
  done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads/)

  # Herdr workspaces git has lost track of — the third source, and the one that
  # catches the ordinary leftover of `gh pr merge --delete-branch`. Neither loop
  # above can reach these: there is no worktree entry and no branch to enumerate
  # them from, so without this the workspace, its tabs, its panes and its idle
  # agent are reported as nothing at all.
  local id wpath wroot label
  for id in ${WS_IDS[@]+"${WS_IDS[@]}"}; do
    wpath="${WS_PATH[$id]:-}"; wroot="${WS_ROOT[$id]:-}"; label="${WS_LABEL[$id]:-}"
    ws_is_ours "$wroot" "$wpath" || continue
    # A workspace Herdr never recorded a checkout for can't be placed, can't be
    # checked for uncommitted work, and isn't a worktree leftover.
    [[ -n "$wpath" ]] || continue
    # Still claimed by a git worktree, so it already has a `worktree` row above —
    # including the main checkout's own workspace.
    [[ -n "${WT_BY_PATH[$wpath]:-}" ]] && continue

    if [[ -d "$wpath" ]]; then
      state="unregistered"; reason="no-git-worktree"
    else
      state="gone"; reason="checkout-missing"
    fi
    # The sidebar label is how the developer recognises one of these ("w17
    # project memory"); the branch column stays `-` because a workspace has no
    # branch, and guessing one from the path would invite `remove --branch`.
    [[ -n "$label" ]] && reason+=" ($label)"
    agent="$(agent_for_ws "$id" "$wpath")"
    dirty="$(dirty_count "$wpath")"

    flags="orphan-workspace,"
    flags+="$(agent_flag "$agent"),"
    case "$dirty" in
      -|0) ;;
      \?) flags+="dirty-unknown," ;;
      *)   flags+="dirty," ;;
    esac
    [[ "$wpath" == "$SELF" || "$id" == "$SELF_WS" ]] && flags+="self,"
    # The same conditions `remove --workspace` enforces. There is no branch guard
    # here because there is no branch: whatever branch this workspace was cut for
    # is either gone already or standing on its own as a `branch` row above.
    if [[ ( "$dirty" == "0" || "$dirty" == "-" ) \
          && "$wpath" != "$SELF" && "$id" != "$SELF_WS" ]] \
       && ! agent_busy "$agent"; then
      flags+="removable,"
    else
      flags+="keep,"
    fi

    rows+=("workspace	-	$wpath	$state	$reason	$agent	$dirty	$id	-	${flags%,}")
  done

  echo "# root=$ROOT base=$BASE_REF gh=$([[ $HAVE_GH -eq 1 ]] && echo yes || echo no) herdr=$([[ $HAVE_HERDR -eq 1 ]] && echo yes || echo no)"
  # Say when a whole source could not be read, rather than letting its silence
  # read as absence. This is the failure the source was added for: the workspaces
  # were always there, and the listing said "nothing left behind".
  if [[ $HAVE_HERDR -ne 1 ]]; then
    echo "# source unavailable: Herdr workspaces — $HERDR_WHY. Orphaned workspaces cannot be listed; what follows is git's side only."
  elif [[ $HERDR_WS_OK -ne 1 ]]; then
    echo "# source unavailable: Herdr workspaces — 'herdr workspace list' returned nothing usable. Orphaned workspaces cannot be listed; what follows is git's side only."
  fi
  echo "# kind	branch	path	state	reason	agent	dirty	workspace	board	flags"
  if [[ ${#rows[@]} -eq 0 ]]; then
    if [[ $HAVE_HERDR -eq 1 && $HERDR_WS_OK -eq 1 ]]; then
      echo "# nothing left behind"
    else
      echo "# nothing left behind that git knows about — Herdr's workspaces were not checked (see above)"
    fi
  else
    printf '%s\n' "${rows[@]}"
  fi
}

# ---- remove ------------------------------------------------------------------
delete_branch() {  # <branch> <state> <force>
  local branch="$1" state="$2" force="$3" why
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" || { log "branch '$branch' is already gone"; return 0; }
  if git -C "$ROOT" branch -d "$branch" >/dev/null 2>&1; then
    echo "REMOVED branch $branch (git branch -d)"
    return 0
  fi
  # -d refuses a squash- or rebase-merged branch: its commits are not ancestors
  # of the base even though its work is. It also refuses an `empty` branch when
  # the root's own base has fallen behind the remote. Force only on evidence —
  # a merged PR, matching patch ids, or a branch with no commits of its own —
  # or on an explicit --force.
  if [[ "$state" == "merged" || "$state" == "empty" || "$force" == "1" ]]; then
    git -C "$ROOT" branch -D "$branch" >/dev/null \
      || die "failed to delete branch '$branch'"
    case "$state" in
      merged) why="merged, no ancestry to find" ;;
      empty)  why="no commits of its own" ;;
      *)      why="forced" ;;
    esac
    echo "REMOVED branch $branch (git branch -D — $why)"
  else
    echo "KEPT branch $branch — git refused -d and the sweep can't prove it merged ($state); re-run with --force to delete it anyway"
  fi
}

remove_worktree() {
  local target="$1" keep_branch="$2" force="$3" i idx=-1 path branch prunable agent dirty ws
  load_worktrees; load_herdr

  # -P, because `git worktree list` reports physical paths: a logical one taken
  # through a symlinked parent wouldn't match any of them.
  target="$(cd "$(dirname "$target")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$target")" || printf '%s' "$target")"
  for i in "${!WT_PATHS[@]}"; do
    [[ "${WT_PATHS[$i]}" == "$target" ]] && { idx=$i; break; }
  done
  [[ $idx -ge 0 ]] || die "'$target' is not a worktree of $ROOT (see: sweep.sh list)"
  [[ "${WT_MAIN[$idx]}" == "1" ]] && die "'$target' is the main checkout, not a leftover — refusing"
  [[ "$target" == "$SELF" ]] && die "'$target' is the worktree this command is running in — refusing"

  path="${WT_PATHS[$idx]}"; branch="${WT_BRANCHES[$idx]}"; prunable="${WT_PRUNABLE[$idx]}"

  # Guard 1 — uncommitted changes. Not overridable, by --force or anything else:
  # a worktree with work in it is not a leftover, whatever its branch says.
  dirty="$(dirty_count "$path")"
  if [[ "$dirty" != "-" && "$dirty" != "0" ]]; then
    echo "SKIPPED $path — uncommitted changes ($dirty file(s)); commit or discard them first" >&2
    git -C "$path" status --short >&2
    exit 2
  fi

  # Guard 2 — a live agent. Removing the workspace kills the pane it is running in.
  agent="$(agent_for "$path")"
  if agent_busy "$agent" && [[ "$force" != "1" ]]; then
    echo "SKIPPED $path — agent $agent is mid-turn in workspace ${WS_OF_PATH[$path]:-?}; let it finish or stop it, or pass --force" >&2
    exit 3
  fi

  # Guard 3 — the branch's work. `empty` is safe (nothing was ever committed);
  # `unmerged`/`unknown` needs the developer to say so.
  if [[ "$branch" != "-" ]]; then
    classify_branch "$branch"
  else
    BRANCH_STATE="unknown"; BRANCH_REASON="detached"
  fi
  if [[ "$BRANCH_STATE" != "merged" && "$BRANCH_STATE" != "empty" && "$force" != "1" ]]; then
    echo "SKIPPED $path — branch '$branch' is $BRANCH_STATE ($BRANCH_REASON); pass --force to remove it anyway" >&2
    exit 4
  fi

  # Past every guard, so this worktree is going — and this is the last moment the
  # link can be taken back through claude-acc, which unlinks the directory it is
  # standing in and has nothing to stand in once the removal below has run. It
  # has to be here rather than after the removal for that reason, and after the
  # guards rather than before them because a worktree the sweep refuses keeps its
  # account: a `SKIPPED` item is one the developer still has.
  #
  # Only a link this worktree owns outright is removed. A ticket that never
  # overrode its account has none, and the inherited one above it is the
  # developer's.
  account_release "$path"

  ws="${WS_OF_PATH[$path]:-}"
  if [[ "$prunable" == "yes" || ! -d "$path" ]]; then
    # The directory is already gone; only git's administrative entry is left.
    # `worktree remove --force` clears that one entry. `worktree prune` would do
    # it too, but repo-wide — one confirmed item would silently take every other
    # broken entry with it, which is the blanket delete this command doesn't have.
    git -C "$ROOT" worktree remove --force "$path" >/dev/null 2>&1 \
      || die "couldn't remove the stale worktree entry for '$path'"
    echo "REMOVED worktree entry $path (its directory was already gone)"
  elif [[ -n "$ws" && $HAVE_HERDR -eq 1 ]]; then
    # One call takes the workspace, its tabs, its panes, the git worktree and the
    # directory. It does not take the branch — that is the line below.
    herdr worktree remove --workspace "$ws" >/dev/null \
      || die "herdr worktree remove --workspace $ws failed (run it by hand to see Herdr's message)"
    echo "REMOVED workspace $ws with its tabs and panes, and worktree $path"
  else
    git -C "$ROOT" worktree remove "$path" >/dev/null \
      || die "git worktree remove '$path' failed"
    echo "REMOVED worktree $path (no Herdr workspace was open for it)"
  fi

  if [[ "$keep_branch" == "1" ]]; then
    echo "KEPT branch $branch (--keep-branch)"
  elif [[ "$branch" != "-" ]]; then
    delete_branch "$branch" "$BRANCH_STATE" "$force"
  fi
}

# The third kind. A workspace whose git worktree is gone cannot be removed the
# way the other two are: `herdr worktree remove --workspace <id>` asks git for
# the repo's worktrees first and doesn't list this one at all, so it is the wrong
# verb. `herdr workspace close <id>` is the working call — positional, because
# the `--workspace` flag form prints a usage error — and it takes the workspace,
# its tabs and its panes, which is everything that is actually left.
remove_workspace() {
  local id="$1" force="$2" wpath wroot label agent dirty
  [[ $HAVE_HERDR -eq 1 ]] \
    || die "Herdr is unavailable ($HERDR_WHY) — 'remove --workspace' has nothing to talk to"
  load_worktrees; load_herdr
  [[ $HERDR_WS_OK -eq 1 ]] \
    || die "'herdr workspace list' returned nothing usable — refusing to close '$id' without being able to check it belongs to $ROOT"
  # Checked before it is used as an array subscript: a workspace id is `w17`, and
  # anything carrying `]` or `[` would be read as a subscript pattern rather than
  # as the key it is.
  [[ "$id" =~ ^[A-Za-z0-9_:.-]+$ ]] || die "'$id' is not a Herdr workspace id (see: sweep.sh list)"
  [[ -n "${WS_LABEL[$id]+set}" ]] || die "no such Herdr workspace: $id (see: sweep.sh list)"

  wpath="${WS_PATH[$id]:-}"; wroot="${WS_ROOT[$id]:-}"; label="${WS_LABEL[$id]:-}"

  # Guard 0 — whose workspace this is. Herdr's list is machine-wide, so this is
  # the guard that stands between a typo'd id and another project's workspace.
  ws_is_ours "$wroot" "$wpath" \
    || die "workspace $id (${label:-no label}) doesn't belong to $ROOT — its checkout is ${wpath:-unrecorded} and its repo ${wroot:-unrecorded}; refusing"
  [[ -n "$wpath" ]] \
    || die "workspace $id has no checkout path recorded — refusing, since nothing here can tell what it is a leftover of"
  [[ "$wpath" == "$SELF" || "$id" == "$SELF_WS" ]] \
    && die "workspace $id is the one this command is running in — refusing"
  [[ -n "${WT_BY_PATH[$wpath]:-}" ]] \
    && die "workspace $id still holds the git worktree $wpath — remove it that way instead, so the worktree and the branch go with it: sweep.sh remove --worktree $wpath"

  # Guard 1 — uncommitted changes. Moot when the checkout is gone, which is the
  # ordinary case here, and not skipped when it isn't. Not overridable by --force.
  dirty="$(dirty_count "$wpath")"
  if [[ "$dirty" == "?" ]]; then
    echo "SKIPPED workspace $id — $wpath is still on disk and git can't read it as a worktree, so there is no telling what is in it; look at it and remove the directory by hand" >&2
    exit 2
  fi
  if [[ "$dirty" != "-" && "$dirty" != "0" ]]; then
    echo "SKIPPED workspace $id — uncommitted changes in $wpath ($dirty file(s)); commit or discard them first" >&2
    git -C "$wpath" status --short >&2
    exit 2
  fi

  # Guard 2 — a live agent. Closing the workspace kills the pane it runs in.
  agent="$(agent_for_ws "$id" "$wpath")"
  if agent_busy "$agent" && [[ "$force" != "1" ]]; then
    echo "SKIPPED workspace $id — agent $agent is mid-turn in it; let it finish or stop it, or pass --force" >&2
    exit 3
  fi

  # There is no guard 3: a workspace has no branch of its own to classify. The
  # branch this one was cut for either went with the merge or is standing on its
  # own as a `branch` row, where `remove --branch` classifies it properly.

  # The same moment, and the same reason, as in remove_worktree: past every guard,
  # so this is going. `account_unlink` handles the directory already being gone by
  # dropping the `<path>=<account>` line in place, which is exactly this case —
  # see docs/agents/accounts.md.
  account_release "$wpath"

  herdr workspace close "$id" >/dev/null \
    || die "herdr workspace close $id failed (run it by hand to see Herdr's message)"
  echo "REMOVED workspace $id${label:+ ($label)} with its tabs and panes — git had no worktree left for $wpath"

  if [[ -d "$wpath" ]]; then
    echo "KEPT directory $wpath — no git worktree was registered for it, so closing the workspace left it where it is; remove it by hand if it is a leftover"
  fi
}

remove_branch() {
  local branch="$1" force="$2" i
  load_worktrees
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" || die "no such branch: $branch"
  [[ "$branch" == "$BASE_BRANCH" ]] && die "'$branch' is the base branch — refusing"
  for i in "${!WT_PATHS[@]}"; do
    [[ "${WT_BRANCHES[$i]}" == "$branch" ]] \
      && die "'$branch' is checked out in ${WT_PATHS[$i]} — remove the worktree instead: sweep.sh remove --worktree ${WT_PATHS[$i]}"
  done

  classify_branch "$branch"
  if [[ "$BRANCH_STATE" != "merged" && "$BRANCH_STATE" != "empty" && "$force" != "1" ]]; then
    echo "SKIPPED branch $branch — $BRANCH_STATE ($BRANCH_REASON); pass --force to delete it anyway" >&2
    exit 4
  fi
  delete_branch "$branch" "$BRANCH_STATE" "$force"
}

do_remove() {
  local kind="" target="" keep_branch=0 force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --worktree) [[ -n "$kind" ]] && die "pass one of --worktree / --branch, not both"
                  kind=worktree; target="${2:-}"; shift ;;
      --branch)   [[ -n "$kind" ]] && die "pass one of --worktree / --branch / --workspace, not more than one"
                  kind=branch; target="${2:-}"; shift ;;
      --workspace) [[ -n "$kind" ]] && die "pass one of --worktree / --branch / --workspace, not more than one"
                  kind=workspace; target="${2:-}"; shift ;;
      --keep-branch) keep_branch=1 ;;
      --force) force=1 ;;
      *) die "unknown flag for remove: $1" ;;
    esac
    shift
  done
  [[ -n "$kind" && -n "$target" ]] || die "usage: sweep.sh remove --worktree <path> [--keep-branch] [--force] | --branch <name> [--force] | --workspace <id> [--force]"
  [[ "$kind" != "worktree" && $keep_branch -eq 1 ]] && die "--keep-branch only makes sense with --worktree"

  case "$kind" in
    worktree)  remove_worktree "$target" "$keep_branch" "$force" ;;
    branch)    remove_branch "$target" "$force" ;;
    workspace) remove_workspace "$target" "$force" ;;
  esac
}

# ---- dispatch ----------------------------------------------------------------
case "${1:-}" in
  list)   shift; do_list "$@" ;;
  remove) shift; do_remove "$@" ;;
  *) die "usage: sweep.sh list [--no-fetch] | sweep.sh remove --worktree <path> [--keep-branch] [--force] | sweep.sh remove --branch <name> [--force] | sweep.sh remove --workspace <id> [--force]" ;;
esac
