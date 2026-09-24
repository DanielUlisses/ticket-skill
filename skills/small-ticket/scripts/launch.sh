#!/usr/bin/env bash
# /small-ticket launcher — Herdr + Omarchy `ga` + Claude Code
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
#   TICKET_GA_TIMEOUT  (default: 90)      — seconds to wait for the worktree
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
GA_TIMEOUT="${TICKET_GA_TIMEOUT:-90}"
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
[[ -n "${HERDR_WORKSPACE_ID:-}" ]] || die "HERDR_WORKSPACE_ID is empty"
[[ -s "$TICKET_FILE" ]] || die "ticket file is empty or missing: $TICKET_FILE"
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"

[[ "$BRANCH" =~ ^[a-z][a-z0-9-]{2,39}$ && "$BRANCH" != *--* && "$BRANCH" != *- ]] \
  || die "invalid branch '$BRANCH' — use kebab-case without '/' or '--', up to 40 chars (e.g. fix-webhook-retry)"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "branch name rejected by git: $BRANCH"
[[ "$IMPL_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid model '$IMPL_MODEL'"

# ---- main repo (ga uses the basename of $PWD) ---------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "the current directory is not a git repository"
ROOT="$(git worktree list --porcelain | awk 'NR==1 && /^worktree /{ sub(/^worktree /, ""); print }')"
[[ -n "$ROOT" && -d "$ROOT" ]] || die "couldn't determine the main repo root"
REPO_NAME="$(basename "$ROOT")"
WT="$(dirname "$ROOT")/${REPO_NAME}--${BRANCH}"

git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" && die "branch '$BRANCH' already exists"
[[ -e "$WT" ]] && die "worktree path already exists: $WT"

# ---- update the base branch before creating the worktree -------------------------
# ga does `git worktree add -b <branch>` from the root's HEAD, so the root
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
  || die "root $ROOT is on branch '$CURRENT', not '$BASE_BRANCH'. ga creates the worktree from the root's HEAD; check out '$BASE_BRANCH' there and run again."

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

# ---- 1. new tab in the current workspace -------------------------------------------
log "creating tab '$LABEL' in workspace $HERDR_WORKSPACE_ID"
args=(tab create --label "$LABEL")
has_flag --workspace tab create && args+=(--workspace "$HERDR_WORKSPACE_ID")
has_flag --no-focus  tab create && args+=(--no-focus)
TAB_JSON="$(herdr "${args[@]}")" || die "failed to create the tab"
TAB_ID="$(jq -r '.result.tab.tab_id // .result.tab.id // empty' <<<"$TAB_JSON")"
LEFT="$(jq -r '.result.root_pane.pane_id // .result.root_pane.id // empty' <<<"$TAB_JSON")"
[[ -n "$LEFT" ]] || die "couldn't read the root pane from the response: $TAB_JSON"

# ---- 2. worktree via ga (Omarchy bash function -> needs the pane's interactive shell)
sleep 1
log "running 'ga $BRANCH' in pane $LEFT"
herdr pane run "$LEFT" "cd $(printf '%q' "$ROOT") && ga $BRANCH" >/dev/null || die "failed to run ga in pane $LEFT"

for ((i = 0; i < GA_TIMEOUT; i++)); do
  if [[ -d "$WT" && "$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" == "$BRANCH" ]]; then
    break
  fi
  sleep 1
done
if [[ ! -d "$WT" ]]; then
  herdr pane read "$LEFT" --source recent-unwrapped --lines 30 >&2 || true
  die "the worktree didn't show up within ${GA_TIMEOUT}s ($WT). Is 'ga' available in the Herdr shell?"
fi
WT_COMMIT="$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)"
[[ "$WT_COMMIT" == "$BASE_COMMIT" ]] \
  || die "worktree was created at $WT_COMMIT, but the updated '$BASE_BRANCH' is at $BASE_COMMIT"
sleep 2   # let the cd + mise trust finish

# ---- 3. split: terminal on the left, Claude Code on the right -----------------------
log "splitting the tab (Claude Code on the right)"
split=(pane split "$LEFT" --direction right --cwd "$WT")
has_flag --no-focus pane split && split+=(--no-focus)
if ! SPLIT_JSON="$(herdr "${split[@]}" 2>/dev/null)"; then
  split=(pane split --pane "$LEFT" "${split[@]:3}")
  SPLIT_JSON="$(herdr "${split[@]}")" || die "failed to split pane $LEFT"
fi
RIGHT="$(jq -r '.result.pane.pane_id // .result.pane.id // empty' <<<"$SPLIT_JSON")"
[[ -n "$RIGHT" ]] || die "couldn't read the new pane from the response: $SPLIT_JSON"

# ---- 4. start Claude Code in plan mode --------------------------------------
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
TAB=${TAB_ID:-?} ($LABEL)
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

# ---- 5. send the ticket ----------------------------------------------------------
send_prompt "$AGENT" "$PROMPT_FILE"
summary
