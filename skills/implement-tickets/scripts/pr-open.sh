#!/usr/bin/env bash
# pr-open.sh — the ticket-pr-creator agent's guard rails. A ticket's work lands
# unstaged in its worktree; this script is the only way an agent turns it into
# a commit, a pushed branch and a PR — on the ticket's own branch, without
# force, with exactly the files the agent named. See docs/adr/0004-haiku-board-session.md.
#
# Usage:
#   pr-open.sh check <board> <NN> [--push]
#       is the ticket ready for a PR (--push: for a push); what changed; where the PR skill lives
#   pr-open.sh open  <board> <NN> --title <t> --message-file <f> --body-file <f> --paths-file <f>
#       stage exactly those paths, commit, push, open the PR against the base
#   pr-open.sh push  <board> <NN> --message-file <f> --paths-file <f>
#       the same commit and push, and no PR — for TICKET_FORGE=none, where the
#       developer merges on the forge; asks no forge anything (message optional
#       when the paths file is empty: the commit is already made)
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
[[ "$verb" =~ ^(check|open|push)$ && -n "$nn" ]] || { sed -n '2,17p' "$0"; exit 1; }
shift 3
# Push mode: commit and push only. No PR is opened or looked up, so no forge is needed.
PUSH=0; [[ "$verb" == push ]] && PUSH=1
[[ "$verb" == check && "${1:-}" == --push ]] && { PUSH=1; shift; }
board_init "$board"
(( HAS_REMOTE )) || die "no '$REMOTE' remote in $ROOT — nowhere to push or open a PR; the developer commits and merges locally"
(( PUSH )) || forge_need
t="$(ticket_json "$nn")"
BRANCH="$(jq -r .branch <<<"$t")"
WT="$(jq -r .worktree <<<"$t")"
[[ -n "$WT" ]] || WT="$(dirname "$ROOT")/${REPO_NAME}--${BRANCH}"
g() { git -C "$WT" "$@"; }

# Every refusal is a reason the developer can act on, printed rather than worked around.
preflight() {
  local foreign; foreign="$(foreign_repo "$t")"
  [[ -z "$foreign" ]] || die "ticket $nn changes $foreign, not $REPO_NAME — its PR belongs on that repo's board"
  [[ "$(jq -r .status <<<"$t")" == in-progress ]] || die "ticket $nn is $(jq -r .status <<<"$t"), not in-progress"
  [[ -n "$BRANCH" && -d "$WT" ]] || die "ticket $nn has no worktree at ${WT:-?}"
  [[ "$(g rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || die "$WT is not on $BRANCH"
  ! g rev-parse -q --verify MERGE_HEAD >/dev/null || die "a merge is in progress in $WT"
  require_agent_quiet "$(jq -r .agent <<<"$t")" "$( ((PUSH)) && echo "pushing" || echo "opening a PR")"
  (( ! PUSH )) || return 0
  local pr; pr="$(forge_pr_open "$BRANCH")" || die "couldn't ask $(forge_name) whether $BRANCH has an open PR — not signed in, or it timed out after ${TICKET_NET_TIMEOUT:-90}s (az devops login / gh auth login in a shell, then ask again)"
  pr="$(jq -r '.url // empty' <<<"${pr:-null}")"
  [[ -z "$pr" ]] || die "$BRANCH already has an open PR: $pr"
}

# Files the ticket changed: tracked modifications and untracked files, one per line.
changed() { g status --porcelain --untracked-files=all | sed -E 's/^.. //; s/^"(.*)"$/\1/; s/.* -> //'; }

# Paths that should never be committed by an agent, whatever it was told.
risky() { grep -iE '(^|/)(\.env(\..*)?|.*\.pem|.*\.key|id_[a-z0-9]+|.*credentials.*|.*secret.*)$' || true; }

# Commits on the branch the remote doesn't have yet: past the remote's own copy
# when it has one, else past the base. The remote is asked (ls-remote), not the
# remote-tracking ref, which outlives a branch deleted on the remote after its
# merge; only when it can't be asked does the tracking ref stand in. Sets UNPUSHED.
count_unpushed() {
  local from="$REMOTE/$BASE_BRANCH" heads sha
  if heads="$(quiet_net git -C "$WT" ls-remote --heads "$REMOTE" "refs/heads/$BRANCH" 2>/dev/null)"; then
    sha="$(awk -v r="refs/heads/$BRANCH" '$2 == r { print $1; exit }' <<<"$heads")"
    [[ -n "$sha" ]] && g cat-file -e "$sha^{commit}" 2>/dev/null && from="$sha"
  elif g show-ref --verify --quiet "refs/remotes/$REMOTE/$BRANCH"; then
    from="$REMOTE/$BRANCH"
  fi
  UNPUSHED="$(g rev-list --count "$from..HEAD" 2>/dev/null || echo 0)"
}

# Stage exactly the named paths, commit them with <msg>, push the branch — the
# one guarded path both open and push take. Sets LEFT to what stays uncommitted.
# <retry> is how to ask again once a push failed, the commit already made.
commit_and_push() {
  local msg="$1" paths="$2" retry="$3" files r staged p rc; local -a want
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
    [[ -s "$msg" ]] || die "no commit message for the named paths — refusing"
    g add -- "${want[@]}"
    g commit -q -F "$msg" -- "${want[@]}"
    echo "STEP committed $(g rev-parse --short HEAD) — pushing $BRANCH to $REMOTE" >&2
  else
    if (( PUSH )); then
      count_unpushed
      (( UNPUSHED > 0 )) || die "no paths named and nothing on $BRANCH that $REMOTE doesn't have — nothing to push"
    elif [[ "$(g rev-list --count "$REMOTE/$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)" -eq 0 ]]; then
      die "no paths named and no commits on $BRANCH — nothing to push"
    fi
    echo "STEP nothing to commit — pushing $(g rev-parse --short HEAD) on $BRANCH to $REMOTE" >&2
  fi
  LEFT="$(changed)"
  rc=0; quiet_net git -C "$WT" push -q -u "$REMOTE" "HEAD:refs/heads/$BRANCH" || rc=$?
  case $rc in
    0) ;;
    124) die "git push timed out after ${TICKET_NET_TIMEOUT:-90}s — git is likely waiting on credentials it can't ask for here (Git Credential Manager's browser sign-in, an ssh passphrase). Push once by hand from a shell — git -C $WT push -u $REMOTE HEAD:refs/heads/$BRANCH — so the credential is cached, then $retry. Nothing is lost." ;;
    *) die "git push failed (exit $rc) — the commit is made, nothing is lost; see git's error above. Retry: $retry" ;;
  esac
}

print_left() { [[ -z "$LEFT" ]] || { echo "LEFT UNCOMMITTED (not named):"; sed 's/^/  /' <<<"$LEFT"; }; }

case "$verb" in
  check)
    preflight
    files="$(changed)"
    ahead="$(g rev-list --count "$REMOTE/$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)"
    if (( PUSH )); then
      count_unpushed
      [[ -n "$files" || "$UNPUSHED" -gt 0 ]] || die "nothing to push: no changes, and $REMOTE already has every commit on $BRANCH"
    else
      [[ -n "$files" || "$ahead" -gt 0 ]] || die "nothing to open a PR for: no changes and no commits on $BRANCH"
    fi
    echo "READY ticket $nn on $BRANCH (base $BASE_BRANCH) in $WT"
    if (( PUSH )); then echo "MODE push — a commit and a pushed branch, no PR"
    else echo "FORGE $(forge_name)$([[ $FORGE == azure ]] && echo " — description capped at 4000 characters; keep the body under it")"; fi
    echo "COMMITS already on the branch: $ahead"
    (( ! PUSH )) || echo "UNPUSHED $UNPUSHED"
    echo "CHANGED"; sed 's/^/  /' <<<"${files:-  (none — only the commits above)}"
    r="$(risky <<<"$files")"; [[ -z "$r" ]] || { echo "RISKY — never include these:"; sed 's/^/  /' <<<"$r"; }
    echo "TICKET $(jq -r '.file // .ref' <<<"$t")"
    p="$(jq -r .parent <<<"$t")"; [[ -n "$p" ]] && echo "PARENT ${p^^}"
    rep="$(board_state_dir)/reports/$BRANCH.md"
    if [[ -s "$rep" ]]; then echo "REPORT $rep"; else echo "REPORT none"; fi
    (( ! PUSH )) || exit 0
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
    # No attribution in what lands: the message and body are cleaned here,
    # whatever wrote them, so no agent's habit can slip a trailer through.
    clean="$(mktemp -d)"; trap 'rm -rf "$clean"' EXIT
    strip_attribution "$msg" >"$clean/msg"; strip_attribution "$body" >"$clean/body"
    msg="$clean/msg"; body="$clean/body"
    [[ -s "$msg" && -s "$body" ]] || die "the commit message or PR body is empty once attribution lines are removed"
    preflight
    commit_and_push "$msg" "$paths" "ask for the PR again — run open with an empty --paths-file, since the commit is already made"
    echo "STEP pushed — opening the PR on $(forge_name)" >&2
    url="$(cd "$WT" && forge_pr_create "$BASE_BRANCH" "$BRANCH" "$title" "$body")"
    echo "OPENED $url"
    echo "COMMIT $(g rev-parse --short HEAD) on $BRANCH, pushed"
    print_left ;;
  push)
    msg="" paths=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --message-file) msg="$2"; shift 2 ;; --paths-file) paths="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    [[ -f "$paths" ]] || die "push needs --paths-file (and --message-file when it names paths)"
    clean="$(mktemp -d)"; trap 'rm -rf "$clean"' EXIT
    : >"$clean/msg"
    if [[ -n "$msg" ]]; then
      [[ -s "$msg" ]] || die "the commit message file $msg is empty"
      # grep selects nothing from a message that is all attribution; the check below says so.
      strip_attribution "$msg" >"$clean/msg" || true
      [[ -s "$clean/msg" ]] || die "the commit message is empty once attribution lines are removed"
    fi
    preflight
    commit_and_push "$clean/msg" "$paths" "run tk.sh push again — the commit already made is pushed with it"
    # The remote-tracking copy is what the board reads as "pushed"; set it even
    # where a narrow fetch refspec kept git push from doing so.
    g update-ref "refs/remotes/$REMOTE/$BRANCH" HEAD
    echo "PUSHED $(g rev-parse --short HEAD) $BRANCH to $REMOTE — no PR; it lands when merged on the forge"
    echo "COMMIT $(g rev-parse --short HEAD) on $BRANCH, pushed"
    print_left ;;
esac
