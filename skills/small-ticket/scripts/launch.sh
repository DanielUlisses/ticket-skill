#!/usr/bin/env bash
# /small-ticket launcher — Herdr worktree + Claude Code
#
# Usage:
#   launch.sh <tab-label> <branch> <ticket-file> [model]
#   launch.sh prompt <agent-name> <prompt-file>
#
# Model resolution, highest wins: the optional 4th positional arg above →
# TICKET_IMPL_MODEL exported in the environment → config/models.env (installed
# as ticket-models.env next to this skill) → the in-script fallback below. This
# one model drives both the plan-mode orchestrator started here and the
# ticket-implementer subagent it delegates to. TICKET_PLAN_MODEL is retired —
# see docs/agents/models.md.
#
# Optional variables:
#   TICKET_AGENT_KIND  (default: claude)  — Claude Code kind in Herdr (`herdr agent`)
#   TICKET_IMPL_MODEL   — orchestrator + implementer model; see resolution order above (fallback: opus)
#   TICKET_REMOTE      (default: origin)
#   TICKET_BASE_BRANCH (default: remote's default branch, e.g. main)
#   TICKET_MODELS_CONF (default: <skills-dir>/ticket-models.env) — override the config file path
#
# Exit codes: 0 = ok | 1 = error | 3 = agent stopped at a dialog (run the `prompt` subcommand afterward)

set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "command '$1' not found in PATH"; }

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SKILL_DIR/templates/agent-prompt.md"

# ---- shared model config (config/models.env, installed as ticket-models.env) ----
MODELS_CONF="${TICKET_MODELS_CONF:-$(dirname "$SKILL_DIR")/ticket-models.env}"
if [[ -f "$MODELS_CONF" ]]; then
  # shellcheck source=/dev/null
  source "$MODELS_CONF" || die "failed to load model config: $MODELS_CONF"
fi
IMPL_MODEL="${TICKET_IMPL_MODEL:-opus}"
REVIEW_MODEL="${TICKET_REVIEW_MODEL:-opus}"
TEST_MODEL="${TICKET_TEST_MODEL:-haiku}"

AGENT_KIND="${TICKET_AGENT_KIND:-claude}"
REMOTE="${TICKET_REMOTE:-origin}"

[[ "${HERDR_ENV:-}" == 1 ]] || die "not running inside a Herdr pane (HERDR_ENV != 1)"
need herdr; need git; need jq

# Checks whether a herdr subcommand accepts a flag (via --help, doesn't execute anything)
has_flag() { local flag="$1"; shift; herdr "$@" --help 2>&1 | grep -qE -- "(^|[[:space:],])${flag}([[:space:],=]|$)"; }

send_prompt() {
  local agent="$1" file="$2"
  [[ -s "$file" ]] || die "empty prompt file: $file"
  herdr agent prompt "$agent" "$(cat "$file")" >/dev/null \
    || die "failed to send the prompt to '$agent' (check with: herdr agent read $agent --source recent-unwrapped --lines 60)"
  log "prompt sent to '$agent'"
}

# ---- subcommand: prompt -------------------------------------------------------
if [[ "${1:-}" == "prompt" ]]; then
  [[ $# -eq 3 ]] || die "usage: launch.sh prompt <agent> <prompt-file>"
  send_prompt "$2" "$3"
  exit 0
fi

# ---- arguments ---------------------------------------------------------------
[[ $# -eq 3 || $# -eq 4 ]] || die "usage: launch.sh <tab-label> <branch> <ticket-file> [model]"
LABEL="$1"; BRANCH="$2"; TICKET_FILE="$3"
[[ -n "${4:-}" ]] && IMPL_MODEL="$4"
[[ -s "$TICKET_FILE" ]] || die "ticket file is empty or missing: $TICKET_FILE"
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"

[[ "$BRANCH" =~ ^[a-z][a-z0-9-]{2,39}$ && "$BRANCH" != *--* && "$BRANCH" != *- ]] \
  || die "invalid branch '$BRANCH' — use kebab-case without '/' or '--', up to 40 chars (e.g. fix-webhook-retry)"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "branch name rejected by git: $BRANCH"
[[ "$IMPL_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid model '$IMPL_MODEL'"

# ---- main repo (--path keeps the worktree at ../<repo>--<branch>, so `gd` still works) ----
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "the current directory is not a git repository"
ROOT="$(git worktree list --porcelain | awk 'NR==1 && /^worktree /{ sub(/^worktree /, ""); print }')"
[[ -n "$ROOT" && -d "$ROOT" ]] || die "couldn't determine the main repo root"
REPO_NAME="$(basename "$ROOT")"
WT="$(dirname "$ROOT")/${REPO_NAME}--${BRANCH}"

git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" && die "branch '$BRANCH' already exists"
[[ -e "$WT" ]] && die "worktree path already exists: $WT"

# ---- update the base branch before creating the worktree -------------------------
# `herdr worktree create --base` branches from the root's ref, so the root
# needs to be on the base branch and up to date with the remote.
git -C "$ROOT" remote get-url "$REMOTE" >/dev/null 2>&1 || die "remote '$REMOTE' doesn't exist in $ROOT"
BASE_BRANCH="${TICKET_BASE_BRANCH:-}"
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="$(git -C "$ROOT" symbolic-ref --quiet --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null || true)"
  BASE_BRANCH="${BASE_BRANCH#"$REMOTE"/}"
fi
if [[ -z "$BASE_BRANCH" ]]; then
  for b in main master; do
    git -C "$ROOT" show-ref --verify --quiet "refs/heads/$b" && { BASE_BRANCH="$b"; break; }
  done
fi
[[ -n "$BASE_BRANCH" ]] || die "couldn't detect the base branch (set TICKET_BASE_BRANCH)"

CURRENT="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
[[ "$CURRENT" == "$BASE_BRANCH" ]] \
  || die "root $ROOT is on branch '$CURRENT', not '$BASE_BRANCH'. The worktree branches off the root's '$BASE_BRANCH'; check out '$BASE_BRANCH' there and run again."

run_git_net() {  # no credential prompt and with a timeout, so it doesn't hang
  if command -v timeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 timeout 120 git -C "$ROOT" "$@"
  else
    GIT_TERMINAL_PROMPT=0 git -C "$ROOT" "$@"
  fi
}

log "updating '$BASE_BRANCH' in $ROOT (git pull --ff-only $REMOTE $BASE_BRANCH)"
run_git_net pull --ff-only "$REMOTE" "$BASE_BRANCH" >&2 \
  || die "pull of '$BASE_BRANCH' failed (no fast-forward, conflict with local changes, network, or credentials). Fix it in $ROOT and run again."

BASE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
REMOTE_COMMIT="$(git -C "$ROOT" rev-parse "refs/remotes/$REMOTE/$BASE_BRANCH" 2>/dev/null || true)"
if [[ -n "$REMOTE_COMMIT" && "$BASE_COMMIT" != "$REMOTE_COMMIT" ]]; then
  if git -C "$ROOT" merge-base --is-ancestor "$REMOTE_COMMIT" "$BASE_COMMIT"; then
    log "warning: local '$BASE_BRANCH' has commits not yet pushed to $REMOTE"
  else
    die "local '$BASE_BRANCH' ($BASE_COMMIT) doesn't match $REMOTE/$BASE_BRANCH ($REMOTE_COMMIT) after the pull"
  fi
fi
BASE_SHORT="$(git -C "$ROOT" rev-parse --short HEAD)"

# ---- agent name -----------------------------------------------------------
AGENT="tk-${BRANCH}"; AGENT="${AGENT:0:32}"; AGENT="${AGENT%-}"
if herdr agent list 2>/dev/null | grep -q "\"${AGENT}\""; then
  AGENT="${AGENT:0:28}-$((RANDOM % 900 + 100))"
fi

# ---- render the prompt (outside the worktree, so it doesn't dirty git status) -------
RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/small-ticket"; mkdir -p "$RUN_DIR"
PROMPT_FILE="$RUN_DIR/${AGENT}.md"
tpl="$(cat "$TEMPLATE")"
ticket="$(cat "$TICKET_FILE")"
tpl="${tpl//'{{BRANCH}}'/"$BRANCH"}"
tpl="${tpl//'{{BASE_BRANCH}}'/"$BASE_BRANCH"}"
tpl="${tpl//'{{BASE_COMMIT}}'/"$BASE_SHORT"}"
tpl="${tpl//'{{WORKTREE}}'/"$WT"}"
tpl="${tpl//'{{IMPL_MODEL}}'/"$IMPL_MODEL"}"
tpl="${tpl//'{{REVIEW_MODEL}}'/"$REVIEW_MODEL"}"
tpl="${tpl//'{{TEST_MODEL}}'/"$TEST_MODEL"}"
tpl="${tpl//'{{TICKET}}'/"$ticket"}"   # last, so we don't replace placeholders inside the ticket text
printf '%s\n' "$tpl" > "$PROMPT_FILE"

# ---- 1. worktree + its workspace, tab and root pane, in one synchronous call --------
# One call either returns the worktree or fails with Herdr's own error. `--path`
# pins it to ../<repo>--<branch>, so `gd <repo>--<branch>` still removes it.
log "creating the worktree $WT (branch '$BRANCH' off '$BASE_BRANCH')"
create=(worktree create --cwd "$ROOT" --branch "$BRANCH" --base "$BASE_BRANCH" --path "$WT" --label "$LABEL")
has_flag --no-focus worktree create && create+=(--no-focus)
# Keep stderr out of the JSON: on success herdr writes only the response to
# stdout, and on failure only an {"error":{"message":...}} object to stderr.
WT_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/ticket-worktree.XXXXXX")"
set +e
WT_JSON="$(herdr "${create[@]}" 2>"$WT_ERR_FILE")"
WT_RC=$?
set -e
if [[ $WT_RC -ne 0 ]]; then
  # Surface Herdr's own message, not a guess about what went wrong.
  WT_ERR="$(jq -r '.error.message // empty' <"$WT_ERR_FILE" 2>/dev/null || true)"
  [[ -n "$WT_ERR" ]] || WT_ERR="$(cat "$WT_ERR_FILE")"
  rm -f "$WT_ERR_FILE"
  die "herdr worktree create failed: ${WT_ERR:-exit $WT_RC with no output}"
fi
rm -f "$WT_ERR_FILE"
# Every read below assumes JSON; fail as `die` (exit 1) rather than letting jq
# abort the script with its own status, which the skills' exit-code contract
# doesn't cover.
jq -e . >/dev/null 2>&1 <<<"$WT_JSON" \
  || die "herdr worktree create returned unparseable output: $WT_JSON"

WORKSPACE_ID="$(jq -r '.result.workspace.workspace_id // .result.workspace.id // empty' <<<"$WT_JSON")"
TAB_ID="$(jq -r '.result.tab.tab_id // .result.tab.id // empty' <<<"$WT_JSON")"
LEFT="$(jq -r '.result.root_pane.pane_id // .result.root_pane.id // empty' <<<"$WT_JSON")"
[[ -n "$LEFT" ]] || die "couldn't read the worktree's root pane from the response: $WT_JSON"
WT_PATH="$(jq -r '.result.worktree.path // empty' <<<"$WT_JSON")"
[[ "$WT_PATH" == "$WT" ]] \
  || die "herdr created the worktree at '${WT_PATH:-?}', not at the expected $WT"

# The branch matters as much as the path: a detached HEAD or a plain checkout of
# the base branch would also sit at $BASE_COMMIT.
WT_BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ "$WT_BRANCH" == "$BRANCH" ]] \
  || die "worktree at $WT is on '${WT_BRANCH:-?}', not '$BRANCH'"
WT_COMMIT="$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)"
[[ "$WT_COMMIT" == "$BASE_COMMIT" ]] \
  || die "worktree was created at $WT_COMMIT, but the updated '$BASE_BRANCH' is at $BASE_COMMIT"

# ---- 2. split: terminal on the left, Claude Code on the right -----------------------
log "splitting the tab (Claude Code on the right)"
split=(pane split "$LEFT" --direction right --cwd "$WT")
has_flag --no-focus pane split && split+=(--no-focus)
if ! SPLIT_JSON="$(herdr "${split[@]}" 2>/dev/null)"; then
  split=(pane split --pane "$LEFT" "${split[@]:3}")
  SPLIT_JSON="$(herdr "${split[@]}")" || die "failed to split pane $LEFT"
fi
RIGHT="$(jq -r '.result.pane.pane_id // .result.pane.id // empty' <<<"$SPLIT_JSON")"
[[ -n "$RIGHT" ]] || die "couldn't read the new pane from the response: $SPLIT_JSON"

# ---- 3. start Claude Code in plan mode --------------------------------------
sleep 1
log "starting '$AGENT' ($AGENT_KIND, $IMPL_MODEL, plan mode) in pane $RIGHT"
set +e
START_OUT="$(herdr agent start "$AGENT" --kind "$AGENT_KIND" --pane "$RIGHT" -- \
  --model "$IMPL_MODEL" --permission-mode plan \
  --disallowedTools "Bash(git commit:*)" "Bash(git push:*)" 2>&1)"
START_RC=$?
set -e

summary() {
  cat <<SUMMARY
TAB=${TAB_ID:-?} (workspace ${WORKSPACE_ID:-?}, labelled '$LABEL')
BRANCH=$BRANCH (base: $BASE_BRANCH @ $BASE_SHORT, updated via pull)
WORKTREE=$WT
PANES=left:$LEFT right:$RIGHT
AGENT=$AGENT
PROMPT_FILE=$PROMPT_FILE
SUMMARY
}

if [[ $START_RC -ne 0 ]]; then
  if grep -q 'agent_not_ready' <<<"$START_OUT"; then
    summary
    echo "PENDING: agent '$AGENT' is stopped at a dialog (probably folder trust)." >&2
    echo "Once the user answers it, run:" >&2
    echo "  $SKILL_DIR/scripts/launch.sh prompt $AGENT $PROMPT_FILE" >&2
    exit 3
  fi
  die "failed to start the agent: $START_OUT"
fi

# ---- 4. send the ticket ----------------------------------------------------------
send_prompt "$AGENT" "$PROMPT_FILE"
summary
