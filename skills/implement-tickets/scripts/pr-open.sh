#!/usr/bin/env bash
# pr-open.sh — the ticket-pr-creator agent's guard rails. A ticket's work lands
# unstaged in its worktree; this script is the only way an agent turns it into
# a commit, a pushed branch and a PR — on the ticket's own branch, without
# force, with exactly the files the agent named. See docs/adr/0004-haiku-board-session.md.
#
# Usage:
#   pr-open.sh check <board> <NN>
#       is the ticket ready for a PR; what changed; where the PR skill lives
#   pr-open.sh open  <board> <NN> --title <t> --message-file <f> --body-file <f> --paths-file <f>
#       stage exactly those paths, commit, push, open the PR against the base
#
# Exit codes: 0 ok | 1 error/refused
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
[[ "$verb" =~ ^(check|open)$ && -n "$nn" ]] || { sed -n '2,13p' "$0"; exit 1; }
shift 3
board_init "$board"
(( HAS_REMOTE )) || die "no '$REMOTE' remote in $ROOT — nowhere to push or open a PR; the developer commits and merges locally"
need gh
t="$(ticket_json "$nn")"
BRANCH="$(jq -r .branch <<<"$t")"
WT="$(jq -r .worktree <<<"$t")"
[[ -n "$WT" ]] || WT="$(dirname "$ROOT")/${REPO_NAME}--${BRANCH}"
g() { git -C "$WT" "$@"; }

# Every refusal is a reason the developer can act on, printed rather than worked around.
preflight() {
  [[ "$(jq -r .status <<<"$t")" == in-progress ]] || die "ticket $nn is $(jq -r .status <<<"$t"), not in-progress"
  [[ -n "$BRANCH" && -d "$WT" ]] || die "ticket $nn has no worktree at ${WT:-?}"
  [[ "$(g rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || die "$WT is not on $BRANCH"
  ! g rev-parse -q --verify MERGE_HEAD >/dev/null || die "a merge is in progress in $WT"
  require_agent_quiet "$(jq -r .agent <<<"$t")" "opening a PR"
  local pr; pr="$(gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty')"
  [[ -z "$pr" ]] || die "$BRANCH already has an open PR: $pr"
}

# Files the ticket changed: tracked modifications and untracked files, one per line.
changed() { g status --porcelain --untracked-files=all | sed -E 's/^.. //; s/^"(.*)"$/\1/; s/.* -> //'; }

# Paths that should never be committed by an agent, whatever it was told.
risky() { grep -iE '(^|/)(\.env(\..*)?|.*\.pem|.*\.key|id_[a-z0-9]+|.*credentials.*|.*secret.*)$' || true; }

case "$verb" in
  check)
    preflight
    files="$(changed)"
    ahead="$(g rev-list --count "$REMOTE/$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)"
    [[ -n "$files" || "$ahead" -gt 0 ]] || die "nothing to open a PR for: no changes and no commits on $BRANCH"
    echo "READY ticket $nn on $BRANCH (base $BASE_BRANCH) in $WT"
    echo "COMMITS already on the branch: $ahead"
    echo "CHANGED"; sed 's/^/  /' <<<"${files:-  (none — only the commits above)}"
    r="$(risky <<<"$files")"; [[ -z "$r" ]] || { echo "RISKY — never include these:"; sed 's/^/  /' <<<"$r"; }
    echo "TICKET $(jq -r '.file // .ref' <<<"$t")"
    p="$(jq -r .parent <<<"$t")"; [[ -n "$p" ]] && echo "PARENT ${p^^}"
    rep="$(board_state_dir)/reports/$BRANCH.md"
    if [[ -s "$rep" ]]; then echo "REPORT $rep"; else echo "REPORT none"; fi
    skill="$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" -path '*mattpocock*' -path '*/pr/SKILL.md' 2>/dev/null | head -1 || true)"
    echo "PR_SKILL ${skill:-none found — use the PR template, or summary / evidence / risk}"
    tmpl="$(ls "$WT"/.github/pull_request_template.md "$WT"/.github/PULL_REQUEST_TEMPLATE.md "$WT"/PULL_REQUEST_TEMPLATE.md "$WT"/docs/PULL_REQUEST_TEMPLATE.md 2>/dev/null | head -1 || true)"
    echo "PR_TEMPLATE ${tmpl:-none}" ;;
  open)
    title="" msg="" body="" paths=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) title="$2"; shift 2 ;; --message-file) msg="$2"; shift 2 ;;
        --body-file) body="$2"; shift 2 ;; --paths-file) paths="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    [[ -n "$title" && -s "$msg" && -s "$body" && -f "$paths" ]] || die "open needs --title, --message-file, --body-file and --paths-file"
    preflight
    files="$(changed)"
    # Exactly the paths the agent named, each one a file this ticket changed.
    mapfile -t want < <(grep -v '^[[:space:]]*$' "$paths" || true)
    for p in "${want[@]}"; do
      grep -qxF "$p" <<<"$files" || die "'$p' is not a changed file in $WT — refusing"
    done
    r="$(printf '%s\n' "${want[@]}" | risky)"; [[ -z "$r" ]] || die "refusing to commit: $r"
    # The index must hold nothing but what this call stages: a file staged
    # earlier would otherwise ride into the commit without being named or checked.
    staged="$(g diff --cached --name-only)"
    [[ -z "$staged" ]] || die "files are already staged in $WT — refusing, since they'd be committed unnamed: $(tr '\n' ' ' <<<"$staged")"
    if [[ ${#want[@]} -gt 0 ]]; then
      g add -- "${want[@]}"
      g commit -q -F "$msg" -- "${want[@]}"
    elif [[ "$(g rev-list --count "$REMOTE/$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)" -eq 0 ]]; then
      die "no paths named and no commits on $BRANCH — nothing to push"
    fi
    left="$(changed)"
    GIT_TERMINAL_PROMPT=0 g push -q -u "$REMOTE" "HEAD:refs/heads/$BRANCH"
    url="$(cd "$WT" && gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "$title" --body-file "$body")"
    echo "OPENED $url"
    echo "COMMIT $(g rev-parse --short HEAD) on $BRANCH, pushed"
    [[ -z "$left" ]] || { echo "LEFT UNCOMMITTED (not named):"; sed 's/^/  /' <<<"$left"; } ;;
esac
