#!/usr/bin/env bash
# /ticket implementation launcher — Herdr worktree + Claude Code
#
# Same workspace/worktree/tab mechanics as /small-ticket's launcher, aimed at
# an already-approved ticket instead of a plan to be drafted: the `agent` tab
# runs unattended (no plan mode, no one there to click a permission
# prompt on a Bash call mid-TDD-loop), so the guardrail moves entirely to
# --disallowedTools: git add/commit/push/stash/reset/rebase and branch
# switches are blocked, since this ticket must land unstaged for review.
#
# Usage:
#   launch.sh <tab-label> <branch> <ticket-file> [model]
#   launch.sh prompt <agent-name> <prompt-file>
#
# Model resolution, highest wins: the optional 4th positional arg above →
# TICKET_IMPL_MODEL exported in the environment → config/models.env (installed
# as ticket-models.env next to this skill) → the in-script fallback below. See
# docs/agents/models.md.
#
# Optional variables:
#   TICKET_AGENT_KIND      (default: claude)           — Claude Code kind in Herdr (`herdr agent`)
#   TICKET_IMPL_MODEL       — implementation model; see resolution order above (fallback: opus)
#   TICKET_IMPL_PERMISSION_MODE (default: bypassPermissions) — acceptEdits only covers Edit/Write, not the Bash implement/test loop
#   TICKET_REMOTE          (default: origin)
#   TICKET_BASE_BRANCH     (default: remote's default branch, e.g. main)
#   TICKET_MODELS_CONF     (default: <skills-dir>/ticket-models.env) — override the config file path
#   TICKET_REVIEWR_WAIT    (default: 5) — seconds to wait for the reviewr plugin's pane before opening 'review' as a plain shell tab
#
# Exit codes: 0 = ok | 1 = error | 3 = agent stopped at a dialog (run the `prompt` subcommand afterward)

set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "command '$1' not found in PATH"; }

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SKILL_DIR/templates/ticket-agent-prompt.md"

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
IMPL_PERMISSION_MODE="${TICKET_IMPL_PERMISSION_MODE:-bypassPermissions}"
REMOTE="${TICKET_REMOTE:-origin}"
REVIEWR_WAIT="${TICKET_REVIEWR_WAIT:-5}"
# No leading zeros: `08` clears a bare ^[0-9]+$ and then blows up as octal in
# the arithmetic below.
[[ "$REVIEWR_WAIT" =~ ^(0|[1-9][0-9]*)$ ]] \
  || die "invalid TICKET_REVIEWR_WAIT '$REVIEWR_WAIT' — whole seconds, no leading zeros (0 skips the wait)"

[[ "${HERDR_ENV:-}" == 1 ]] || die "not running inside a Herdr pane (HERDR_ENV != 1)"
need herdr; need git; need jq

# Checks whether a herdr subcommand accepts a flag (via --help, doesn't execute anything)
has_flag() { local flag="$1"; shift; herdr "$@" --help 2>&1 | grep -qE -- "(^|[[:space:],])${flag}([[:space:],=]|$)"; }

# Runs a herdr command and prints its JSON response. Keeps stderr out of that
# JSON: on success herdr writes only the response to stdout, and on failure only
# an {"error":{"message":...}} object to stderr — so a failure here reports
# Herdr's own message rather than a guess about what went wrong. Every caller
# reads the response with jq, so an unparseable one dies here too, as `die`
# (exit 1) rather than letting jq abort the script with its own status, which
# the skills' exit-code contract doesn't cover.
herdr_json() {
  local what="$1"; shift
  local err out rc msg
  err="$(mktemp "${TMPDIR:-/tmp}/ticket-herdr.XXXXXX")"
  set +e
  out="$(herdr "$@" 2>"$err")"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    msg="$(jq -r '.error.message // empty' <"$err" 2>/dev/null || true)"
    [[ -n "$msg" ]] || msg="$(cat "$err")"
    rm -f "$err"
    die "$what failed: ${msg:-exit $rc with no output}"
  fi
  rm -f "$err"
  jq -e . >/dev/null 2>&1 <<<"$out" || die "$what returned unparseable output: $out"
  printf '%s' "$out"
}

# Appends a tab to the worktree's workspace and sets CREATED_TAB to its id.
# It sets a global instead of printing because a `die` inside a command
# substitution only exits that subshell: called as `t="$(create_tab x)"`, a
# failed `herdr tab create` would report Herdr's message and then carry on to
# report a second, empty-JSON error on top of it.
create_tab() {
  local label="$1" cmd json
  cmd=(tab create --workspace "$WORKSPACE_ID" --cwd "$WT" --label "$label")
  has_flag --no-focus tab create && cmd+=(--no-focus)
  json="$(herdr_json "herdr tab create ($label)" "${cmd[@]}")"
  CREATED_TAB="$(jq -r '.result.tab.tab_id // .result.tab.id // empty' <<<"$json")"
  [[ -n "$CREATED_TAB" ]] || die "couldn't read the '$label' tab from the response: $json"
}

# Whether to wait for the reviewr plugin's pane at all — only to skip a wait
# that could not pay off, when no enabled reviewr is there to open one. A
# listing that can't be read or parsed (older herdr without `--json`, say)
# waits anyway: missing reviewr's pane costs more than the wait does.
should_wait_for_reviewr() {
  local list
  list="$(herdr plugin list --json 2>/dev/null)" || return 0
  jq -e '.result.plugins[]? | select(.plugin_id == "persiyanov.reviewr" and .enabled)' \
    >/dev/null 2>&1 <<<"$list" && return 0
  jq -e '.result.plugins' >/dev/null 2>&1 <<<"$list" && return 1
  return 0
}

# The workspace's reviewr pane, or nothing. Identified by its foreground
# process, the way the plugin identifies its own panes: the `reviewr` pane label
# is a display-only, rewritable title and never what decides. The agent's own
# pane is excluded, so this can only ever name a pane the plugin opened.
reviewr_pane() {
  local panes p
  panes="$(herdr pane list --workspace "$WORKSPACE_ID" 2>/dev/null \
    | jq -r '.result.panes[].pane_id // empty' 2>/dev/null)" || return 0
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "$AGENT_PANE" ]] || continue
    herdr pane process-info --pane "$p" 2>/dev/null | jq -e '
        def base: split("/") | last;
        any(.result.process_info.foreground_processes[];
            ((((.argv0 // "") | base) == "herdr-reviewr")
              or ((((.argv // [])[0] // "") | base) == "herdr-reviewr"))
            and (((.argv // []) | index("--resolve-plugin-config")) == null))' >/dev/null 2>&1 \
      && { printf '%s' "$p"; return 0; }
  done <<<"$panes"
  return 0
}

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
RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/ticket"; mkdir -p "$RUN_DIR"
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
# pins it to ../<repo>--<branch>, the convention /sweep-tickets reports against
# (and that `gd <repo>--<branch>` still removes by hand).
log "creating the worktree $WT (branch '$BRANCH' off '$BASE_BRANCH')"
create=(worktree create --cwd "$ROOT" --branch "$BRANCH" --base "$BASE_BRANCH" --path "$WT" --label "$LABEL")
has_flag --no-focus worktree create && create+=(--no-focus)
WT_JSON="$(herdr_json "herdr worktree create" "${create[@]}")"

# `--label` above labels the WORKSPACE; the tab that comes with it is labelled
# by number ("1"), and section 2 renames it. All three ids are load-bearing
# from here on, so read each one and say which was missing.
WORKSPACE_ID="$(jq -r '.result.workspace.workspace_id // .result.workspace.id // empty' <<<"$WT_JSON")"
AGENT_TAB="$(jq -r '.result.tab.tab_id // .result.tab.id // empty' <<<"$WT_JSON")"
AGENT_PANE="$(jq -r '.result.root_pane.pane_id // .result.root_pane.id // empty' <<<"$WT_JSON")"
[[ -n "$WORKSPACE_ID" ]] || die "couldn't read the worktree's workspace from the response: $WT_JSON"
[[ -n "$AGENT_TAB" ]] || die "couldn't read the worktree's tab from the response: $WT_JSON"
[[ -n "$AGENT_PANE" ]] || die "couldn't read the worktree's root pane from the response: $WT_JSON"
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

# ---- 2. the workspace's tabs: agent, review, shell --------------------------
# The worktree's own tab is renamed rather than replaced: that keeps the agent
# on the root pane, which already has the worktree as its cwd. The other two are
# appended, so the workspace's bar reads agent | review | shell.
log "renaming the worktree's tab to 'agent'"
herdr_json "herdr tab rename" tab rename "$AGENT_TAB" agent >/dev/null

# The review pane is the persiyanov.reviewr plugin's, not ours. It auto-opens on
# Herdr's `worktree.created` event and places itself from its own config file
# (~/.config/herdr/plugins/config/persiyanov.reviewr/config.toml, keys
# `toggle_placement` / `toggle_direction`): no launcher flag or event payload
# reaches that choice, and the event path always attaches to the workspace's
# *first* pane, so with the defaults (`split`, `right`) it lands as a split on
# top of the agent. Its placement can't be directed — but the pane it opens can
# be relocated afterwards, so wait briefly for it and move it into a tab of its
# own. If it never appears (plugin absent or disabled, `auto_open = false`, or
# simply slower than the wait), open `review` as a plain shell tab and say so in
# the summary rather than fighting the plugin for the slot.
REVIEW_PANE=""
if [[ "$REVIEWR_WAIT" -gt 0 ]] && should_wait_for_reviewr; then
  log "waiting up to ${REVIEWR_WAIT}s for the reviewr plugin's pane"
  # A wall-clock deadline, not an iteration count: each probe costs a `pane
  # list` plus a `process-info` per pane, so counting iterations would overrun
  # the seconds the variable promises.
  REVIEWR_DEADLINE=$((SECONDS + REVIEWR_WAIT))
  while :; do
    REVIEW_PANE="$(reviewr_pane)"
    [[ -n "$REVIEW_PANE" ]] && break
    (( SECONDS < REVIEWR_DEADLINE )) || break
    sleep 0.1
  done
fi

if [[ -n "$REVIEW_PANE" ]]; then
  log "moving the reviewr pane $REVIEW_PANE into its own 'review' tab"
  move=(pane move "$REVIEW_PANE" --new-tab --label review)
  has_flag --no-focus pane move && move+=(--no-focus)
  MOVE_JSON="$(herdr_json "herdr pane move" "${move[@]}")"
  REVIEW_TAB="$(jq -r '.result.move_result.created_tab.tab_id // .result.move_result.created_tab.id // empty' <<<"$MOVE_JSON")"
  [[ -n "$REVIEW_TAB" ]] || die "couldn't read the new 'review' tab from the response: $MOVE_JSON"
  # Report the pane as it stands after the move, not the id we passed in.
  MOVED_PANE="$(jq -r '.result.move_result.pane.pane_id // .result.move_result.pane.id // empty' <<<"$MOVE_JSON")"
  REVIEW_SOURCE="reviewr pane ${MOVED_PANE:-$REVIEW_PANE}"
else
  log "no reviewr pane to move; opening 'review' as a plain shell tab"
  create_tab review; REVIEW_TAB="$CREATED_TAB"
  REVIEW_SOURCE="empty shell (no reviewr pane appeared; run 'herdr-reviewr' in that tab)"
fi

log "creating the 'shell' tab"
create_tab shell; SHELL_TAB="$CREATED_TAB"

# ---- 3. start Claude Code unattended in the 'agent' tab, blocked from staging/committing/pushing ------
sleep 1
log "starting '$AGENT' ($AGENT_KIND, $IMPL_MODEL, $IMPL_PERMISSION_MODE) in pane $AGENT_PANE"
set +e
START_OUT="$(herdr agent start "$AGENT" --kind "$AGENT_KIND" --pane "$AGENT_PANE" -- \
  --model "$IMPL_MODEL" --permission-mode "$IMPL_PERMISSION_MODE" \
  --disallowedTools "Bash(git add:*)" "Bash(git commit:*)" "Bash(git push:*)" \
    "Bash(git stash:*)" "Bash(git reset:*)" "Bash(git rebase:*)" \
    "Bash(git checkout:*)" "Bash(git switch:*)" 2>&1)"
START_RC=$?
set -e

summary() {
  cat <<SUMMARY
WORKSPACE=${WORKSPACE_ID:-?} (labelled '$LABEL')
BRANCH=$BRANCH (base: $BASE_BRANCH @ $BASE_SHORT, updated via pull)
WORKTREE=$WT
TABS=agent:${AGENT_TAB:-?} review:${REVIEW_TAB:-?} shell:${SHELL_TAB:-?}
REVIEW=${REVIEW_SOURCE:-?}
AGENT=$AGENT (pane ${AGENT_PANE:-?})
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
