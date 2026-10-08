#!/usr/bin/env bash
# merge-conflict.sh — the ticket-merger agent's guard rails. Nothing else in the
# workflow commits or pushes; this script is the one exception, and it only ever
# makes one kind of commit: a merge of the base branch into the ticket's own
# branch, pushed without force. See docs/adr/0004-haiku-board-session.md.
#
# Usage:
#   merge-conflict.sh start  <board> <NN>   merge <remote>/<base> into the ticket's worktree, stop before committing
#   merge-conflict.sh status <board> <NN>   what is still unresolved
#   merge-conflict.sh finish <board> <NN>   commit the resolved merge and push it — only after the developer said yes
#   merge-conflict.sh abort  <board> <NN>   undo the merge in progress
#
# Exit codes: 0 ok | 1 error/refused | 2 start: conflicts to resolve | 4 finish: still unresolved
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${TICKET_LIB_DIR:-}" ]]; then LIB_DIR="$TICKET_LIB_DIR"; else
  for d in "$(dirname "$SKILL_DIR")" "$(dirname "$(dirname "$SKILL_DIR")")/lib"; do
    [[ -f "$d/ticket-git-repo.sh" ]] && { LIB_DIR="$d"; break; }
  done
fi
[[ -f "${LIB_DIR:-}/ticket-git-repo.sh" ]] || { echo "ERROR: ticket-git-repo.sh not found — re-run install.sh, or set TICKET_LIB_DIR" >&2; exit 1; }
# shellcheck source=/dev/null
source "$LIB_DIR/ticket-git-repo.sh"
# shellcheck source=/dev/null
source "$SKILL_DIR/scripts/board-lib.sh"

verb="${1:-}"; board="${2:-}"; nn="${3:-}"
[[ "$verb" =~ ^(start|status|finish|abort)$ && -n "$nn" ]] || { sed -n '2,15p' "$0"; exit 1; }
board_init "$board"
(( HAS_REMOTE )) || die "no '$REMOTE' remote in $ROOT — no PR to unblock; merge the branch locally"
t="$(ticket_json "$nn")"
BRANCH="$(jq -r .branch <<<"$t")"
WT="$(jq -r .worktree <<<"$t")"
[[ -n "$WT" ]] || WT="$(dirname "$ROOT")/${REPO_NAME}--${BRANCH}"
[[ -n "$BRANCH" && -d "$WT" ]] || die "ticket $nn has no worktree at ${WT:-?}"
[[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || die "$WT is not on $BRANCH"

g() { git -C "$WT" "$@"; }
in_merge() { g rev-parse -q --verify MERGE_HEAD >/dev/null; }
unmerged() { g diff --name-only --diff-filter=U; }
# Conflict markers left in any file the merge touched. `=======` alone is too
# common in Markdown to count; the two outer markers are not.
markers() {
  local f
  while IFS= read -r f; do
    [[ -f "$WT/$f" ]] && grep -nE '^(<<<<<<<|>>>>>>>)( |$)' "$WT/$f" | sed "s|^|$f:|"
  done < <(g diff --name-only HEAD) || true
}

case "$verb" in
  start)
    in_merge && die "a merge is already in progress in $WT — use status, finish or abort"
    # The ticket's own agent works in this same directory; two agents editing one
    # worktree is how a resolution gets silently overwritten.
    agent="$(jq -r .agent <<<"$t")"
    if [[ -n "$agent" ]]; then
      st="$( (agent_states || true) | awk -F'\t' -v a="$agent" '$1 == a {print $2}')"
      [[ "$st" != working ]] || die "$agent is working in $WT — wait until it's idle"
    fi
    [[ -z "$(g status --porcelain)" ]] || die "$WT has uncommitted changes — the merge needs a clean worktree; the developer commits or discards them first"
    GIT_TERMINAL_PROMPT=0 g fetch "$REMOTE" "$BASE_BRANCH" --quiet
    if g merge --no-ff --no-commit "$REMOTE/$BASE_BRANCH" >/dev/null 2>&1; then
      echo "CLEAN — $REMOTE/$BASE_BRANCH merged into $BRANCH without conflicts, not committed yet"
      echo "WORKTREE $WT"
      exit 0
    fi
    in_merge || die "git merge failed without starting a merge — read 'git -C $WT status'"
    echo "CONFLICTS in $WT:"; unmerged | sed 's/^/  /'
    exit 2 ;;
  status)
    in_merge || { echo "no merge in progress in $WT"; exit 0; }
    u="$(unmerged)"; m="$(markers)"
    [[ -z "$u" ]] && echo "UNMERGED none" || { echo "UNMERGED"; sed 's/^/  /' <<<"$u"; }
    [[ -z "$m" ]] && echo "MARKERS none" || { echo "MARKERS"; sed 's/^/  /' <<<"$m"; }
    echo "DIFF vs $BRANCH before the merge:"; g diff --stat HEAD | tail -20 ;;
  finish)
    in_merge || die "no merge in progress in $WT — nothing to finish"
    u="$(unmerged)"; m="$(markers)"
    if [[ -n "$u" || -n "$m" ]]; then
      echo "STILL UNRESOLVED — not committing"; [[ -n "$u" ]] && sed 's/^/  unmerged: /' <<<"$u"; [[ -n "$m" ]] && sed 's/^/  marker: /' <<<"$m"
      exit 4
    fi
    g add -u
    g commit --no-edit >/dev/null
    # Plain push to the same branch: never --force, never another ref.
    GIT_TERMINAL_PROMPT=0 g push "$REMOTE" "HEAD:refs/heads/$BRANCH"
    echo "PUSHED merge $(g rev-parse --short HEAD) to $REMOTE/$BRANCH — CI re-runs; check the gates again before merging the PR" ;;
  abort)
    in_merge || { echo "no merge in progress in $WT"; exit 0; }
    g merge --abort; echo "ABORTED — $WT is back where it was" ;;
esac
