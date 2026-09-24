#!/usr/bin/env bash
# /sweep-tickets — list and remove what finished tickets left behind
#
# A ticket launched by /ticket or /implement-tickets leaves five things behind:
# a Herdr workspace, its tabs, its panes, a git worktree, and a branch. This
# script reports all of them and removes them one item at a time.
#
# Usage:
#   sweep.sh list [--no-fetch]
#   sweep.sh remove --worktree <path> [--keep-branch] [--force]
#   sweep.sh remove --branch <name> [--force]
#
# `list` writes nothing but remote-tracking refs (it fetches the base branch, as
# /implement-tickets' digest does; --no-fetch skips even that) and works from any
# worktree of the repo. `remove` takes exactly one item per call — there is no
# "remove everything" verb, deliberately: opt-in per item is the whole point.
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
for lib in ticket-git-repo.sh; do
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
HAVE_HERDR=0
[[ "${HERDR_ENV:-}" == 1 ]] && command -v herdr >/dev/null 2>&1 && [[ $HAVE_JQ -eq 1 ]] && HAVE_HERDR=1

# ---- the repo, from wherever this is run ------------------------------------
# Sets ROOT (the main checkout, so a sweep run from a ticket's own worktree
# resolves what one run from the checkout would), REPO_NAME, and SELF.
resolve_repo_root

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

load_herdr() {
  [[ $HAVE_HERDR -eq 1 ]] || return 0
  local json line p w
  json="$(herdr worktree list --cwd "$ROOT" 2>/dev/null || true)"
  while IFS=$'\t' read -r p w; do
    [[ -n "$p" && -n "$w" && "$w" != "null" ]] && WS_OF_PATH["$p"]="$w"
  done < <(jq -r '.result.worktrees[]? | [.path, (.open_workspace_id // "")] | @tsv' <<<"$json" 2>/dev/null || true)

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
}

# "none" is an answer, not a shrug: it means Herdr was asked and returned nothing
# for this worktree. Where Herdr can't be reached at all the cell reads "unknown",
# so a row never claims a dead agent on the strength of a missing CLI.
agent_for() {  # <worktree path> -> "<name>:<status>" | "none" | "unknown"
  local path="$1" ws="${WS_OF_PATH[$1]:-}"
  [[ $HAVE_HERDR -eq 1 ]] || { printf 'unknown'; return 0; }
  if [[ -n "$ws" && -n "${AGENT_OF_WS[$ws]:-}" ]]; then printf '%s' "${AGENT_OF_WS[$ws]}"; return 0; fi
  if [[ -n "${AGENT_OF_CWD[$path]:-}" ]]; then printf '%s' "${AGENT_OF_CWD[$path]}"; return 0; fi
  printf 'none'
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
load_worktrees() {
  local path="" branch="" prunable="" first=1
  while IFS= read -r l || [[ -n "$l" ]]; do
    case "$l" in
      worktree\ *) path="${l#worktree }"; branch="-"; prunable="no" ;;
      branch\ refs/heads/*) branch="${l#branch refs/heads/}" ;;
      detached) branch="-" ;;
      prunable*) prunable="yes" ;;
      "")
        if [[ -n "$path" ]]; then
          WT_PATHS+=("$path"); WT_BRANCHES+=("$branch"); WT_PRUNABLE+=("$prunable")
          WT_MAIN+=("$first"); first=0; path=""
        fi ;;
    esac
  done < <(git -C "$ROOT" worktree list --porcelain; echo)
}

dirty_count() {  # <path> -> number of porcelain lines, or "-" when the path is gone
  [[ -d "$1" ]] || { printf '%s' '-'; return 0; }
  git -C "$1" status --porcelain 2>/dev/null | grep -c '' || true
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
    case "$agent" in
      none)    flags+="no-agent," ;;
      unknown) flags+="agent-unknown," ;;
      *)       if agent_busy "$agent"; then flags+="agent-busy,"; else flags+="agent-idle,"; fi ;;
    esac
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

  echo "# root=$ROOT base=$BASE_REF gh=$([[ $HAVE_GH -eq 1 ]] && echo yes || echo no) herdr=$([[ $HAVE_HERDR -eq 1 ]] && echo yes || echo no)"
  echo "# kind	branch	path	state	reason	agent	dirty	workspace	board	flags"
  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "# nothing left behind"
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
      --branch)   [[ -n "$kind" ]] && die "pass one of --worktree / --branch, not both"
                  kind=branch; target="${2:-}"; shift ;;
      --keep-branch) keep_branch=1 ;;
      --force) force=1 ;;
      *) die "unknown flag for remove: $1" ;;
    esac
    shift
  done
  [[ -n "$kind" && -n "$target" ]] || die "usage: sweep.sh remove --worktree <path> [--keep-branch] [--force] | --branch <name> [--force]"
  [[ "$kind" == "branch" && $keep_branch -eq 1 ]] && die "--keep-branch makes no sense with --branch"

  if [[ "$kind" == "worktree" ]]; then
    remove_worktree "$target" "$keep_branch" "$force"
  else
    remove_branch "$target" "$force"
  fi
}

# ---- dispatch ----------------------------------------------------------------
case "${1:-}" in
  list)   shift; do_list "$@" ;;
  remove) shift; do_remove "$@" ;;
  *) die "usage: sweep.sh list [--no-fetch] | sweep.sh remove --worktree <path> [--keep-branch] [--force] | sweep.sh remove --branch <name> [--force]" ;;
esac
