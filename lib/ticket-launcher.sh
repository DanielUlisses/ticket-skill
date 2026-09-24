#!/usr/bin/env bash
# Shared launcher mechanics for /ticket and /small-ticket — Herdr worktree,
# workspace layout, and the Claude Code agent that gets the ticket.
#
# Sourced, never executed. The two launchers have always been near-identical
# siblings, so every change had to be made twice and kept byte-compatible by
# hand. The mechanics live here once and the launchers are parameters, not
# forks; each sets these before calling launcher_main:
#
#   SKILL_DIR         the skill's own directory. Two things hang off it: the
#                     exit-3 hint, which tells the developer to re-run that
#                     skill's scripts/launch.sh, and the default location of
#                     ticket-models.env, one level up from it.
#   TEMPLATE          the prompt template to render
#   RUN_NAME          subdirectory of ${XDG_RUNTIME_DIR:-/tmp} the rendered
#                     prompt is written to
#   PERMISSION_MODE   --permission-mode the agent starts with
#   PERMISSION_LABEL  how the "starting ..." log line names that mode. Separate
#                     from PERMISSION_MODE only because /small-ticket's line has
#                     always read "plan mode" where /ticket's reads the mode
#                     verbatim, and that output is contractual.
#   DISALLOWED_TOOLS  array of --disallowedTools patterns
#
# The caller sets PERMISSION_MODE after calling load_ticket_models, so a value in
# ticket-models.env still reaches it — the order the launchers have always used.
#
# Requires ticket-git-repo.sh to have been sourced first (die/log/need,
# resolve_repo_root, resolve_base_branch, run_git_net) and the caller to be
# running under `set -euo pipefail`.
#
# Installed as ~/.claude/skills/ticket-launcher.sh, one level up from the skill
# directories — see ticket-git-repo.sh for why it can't live inside one.

# The rendering below substitutes arbitrary prose (a ticket body, a hand-written
# memory file) into the template with `${tpl//}`, and bash 5.2+ reads a `&` in a
# replacement as "the whole match" unless this option is off. Turned off here
# rather than in each caller, so a third launcher can't forget it.
shopt -u patsub_replacement 2>/dev/null || true

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

# Takes the placeholder and its value as arguments, but reads and mutates the
# global `tpl` — the template being rendered — which must already be set.
#
# Substitutes EVERY occurrence of a placeholder in $tpl (which it mutates), the
# same as a `${tpl//}` — but without ever rescanning what it just put there. The
# two payloads it is used for are arbitrary prose: a ticket body, and a memory
# file the developer wrote by hand. Either may legitimately contain a `{{...}}`
# token — this very repo's tickets do — and a plain `${tpl//}` would then chew on
# it, or substitute one payload into the other. Walking the template instead
# means each payload lands exactly once, verbatim.
#
# An empty value also takes the blank line that follows its placeholder, so a
# repo with no project memory renders byte-for-byte the prompt it rendered before
# any of this existed.
fill_prose() {
  local ph="$1" val="$2" out="" rest="$tpl" blank=$'\n\n'
  while [[ "$rest" == *"$ph"* ]]; do
    out+="${rest%%"$ph"*}$val"
    rest="${rest#*"$ph"}"
    [[ -n "$val" ]] || rest="${rest#"$blank"}"
  done
  tpl="$out$rest"
}

# ---- per-repo project memory ------------------------------------------------
# Sets MEMORY_BLOCK (what the prompt's {{PROJECT_MEMORY}} becomes) and
# MEMORY_STATUS (the summary's PROJECT_MEMORY= line).
#
# Read from $ROOT, the MAIN checkout, never from the worktree: the base branch is
# what the developer has already reviewed and merged, so a lesson reaches future
# tickets only once it has landed there — that merge is the developer gate on
# capture. It also puts the file somewhere /sweep-tickets can never take with it,
# since that skill removes worktrees and branches and leaves the checkout alone.
# Absent, unreadable or blank means the launch is exactly what it was before this
# existed: no heading, no placeholder, nothing said to the agent.
resolve_project_memory() {
  local memory
  MEMORY_WARN_BYTES=8192   # 8 KiB; memory is paid for on every launch, so warn past a page or so
  MEMORY_FILE="${TICKET_MEMORY_FILE:-docs/agents/project-memory.md}"
  [[ "$MEMORY_FILE" == /* ]] || MEMORY_FILE="$ROOT/$MEMORY_FILE"
  MEMORY_REL="${MEMORY_FILE#"$ROOT"/}"
  MEMORY_BLOCK=""
  MEMORY_STATUS="none ($MEMORY_REL)"
  if [[ -f "$MEMORY_FILE" && -r "$MEMORY_FILE" ]]; then
    memory="$(cat "$MEMORY_FILE")"
    if [[ -z "${memory//[[:space:]]/}" ]]; then
      MEMORY_STATUS="blank ($MEMORY_REL)"
      log "project memory: $MEMORY_REL is blank — launching without it"
    else
      MEMORY_BYTES="$(wc -c <"$MEMORY_FILE" | tr -d ' ')"
      MEMORY_STATUS="$MEMORY_REL (${MEMORY_BYTES} bytes)"
      if (( MEMORY_BYTES > MEMORY_WARN_BYTES )); then
        log "warning: $MEMORY_REL is ${MEMORY_BYTES} bytes — every ticket launch pays for it; keep it short and factual (see docs/agents/memory.md)"
      fi
      MEMORY_BLOCK="## Project memory

Accumulated knowledge about this repo, hand-curated by the developer and read at
launch from \`$MEMORY_REL\` in the main checkout. It is starting knowledge, not
orders: it never overrides the ticket below, and where it disagrees with the code
in front of you the code wins — say so in your report when it does. Don't edit
that file; report durable lessons under \`## Remember\` instead.

$memory"
      log "project memory: $MEMORY_STATUS"
    fi
  elif [[ -e "$MEMORY_FILE" ]]; then
    MEMORY_STATUS="unreadable ($MEMORY_REL)"
    log "warning: $MEMORY_REL exists but can't be read — launching without project memory"
  else
    log "project memory: none at $MEMORY_REL — launching without it"
  fi
}

# ---- shared model config (config/models.env, installed as ticket-models.env) ----
# Called by the caller before it sets its own parameters, never from
# launcher_main: the config file may set any TICKET_* variable, so anything
# resolved from the environment — PERMISSION_MODE among them — has to be
# resolved after this has run, which is the order both launchers have always had.
load_ticket_models() {
  MODELS_CONF="${TICKET_MODELS_CONF:-$(dirname "$SKILL_DIR")/ticket-models.env}"
  if [[ -f "$MODELS_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$MODELS_CONF" || die "failed to load model config: $MODELS_CONF"
  fi
  IMPL_MODEL="${TICKET_IMPL_MODEL:-opus}"
  REVIEW_MODEL="${TICKET_REVIEW_MODEL:-opus}"
  TEST_MODEL="${TICKET_TEST_MODEL:-haiku}"
}

# ---- the launch ---------------------------------------------------------------
launcher_main() {
  AGENT_KIND="${TICKET_AGENT_KIND:-claude}"
  REMOTE="${TICKET_REMOTE:-origin}"
  REVIEWR_WAIT="${TICKET_REVIEWR_WAIT:-5}"
  # No leading zeros: `08` clears a bare ^[0-9]+$ and then blows up as octal in
  # the arithmetic below.
  [[ "$REVIEWR_WAIT" =~ ^(0|[1-9][0-9]*)$ ]] \
    || die "invalid TICKET_REVIEWR_WAIT '$REVIEWR_WAIT' — whole seconds, no leading zeros (0 skips the wait)"

  [[ "${HERDR_ENV:-}" == 1 ]] || die "not running inside a Herdr pane (HERDR_ENV != 1)"
  need herdr; need git; need jq

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
  resolve_repo_root
  WT="$(dirname "$ROOT")/${REPO_NAME}--${BRANCH}"

  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" && die "branch '$BRANCH' already exists"
  [[ -e "$WT" ]] && die "worktree path already exists: $WT"

  # ---- update the base branch before creating the worktree -------------------------
  # `herdr worktree create --base` branches from the root's ref, so the root
  # needs to be on the base branch and up to date with the remote.
  git -C "$ROOT" remote get-url "$REMOTE" >/dev/null 2>&1 || die "remote '$REMOTE' doesn't exist in $ROOT"
  resolve_base_branch

  CURRENT="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  [[ "$CURRENT" == "$BASE_BRANCH" ]] \
    || die "root $ROOT is on branch '$CURRENT', not '$BASE_BRANCH'. The worktree branches off the root's '$BASE_BRANCH'; check out '$BASE_BRANCH' there and run again."

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

  resolve_project_memory

  # ---- render the prompt (outside the worktree, so it doesn't dirty git status) -------
  RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/$RUN_NAME"; mkdir -p "$RUN_DIR"
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
  # The two prose payloads go last, so the replacements above can't reach inside
  # them — and TICKET before PROJECT_MEMORY, because the memory placeholder sits
  # above the ticket in the template, so filling it first would let a `{{TICKET}}`
  # written inside the memory file win over the template's own.
  fill_prose '{{TICKET}}' "$ticket"
  fill_prose '{{PROJECT_MEMORY}}' "$MEMORY_BLOCK"
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

  # ---- 3. start Claude Code in the 'agent' tab -------------------------------
  # PERMISSION_MODE and DISALLOWED_TOOLS are where the two launchers part company
  # and must not be flattened: /small-ticket starts in plan mode with only
  # commit/push blocked, because a developer approves the plan in the pane;
  # /ticket starts unattended, so the guardrail moves entirely to the tool blocks.
  sleep 1
  log "starting '$AGENT' ($AGENT_KIND, $IMPL_MODEL, $PERMISSION_LABEL) in pane $AGENT_PANE"
  set +e
  START_OUT="$(herdr agent start "$AGENT" --kind "$AGENT_KIND" --pane "$AGENT_PANE" -- \
    --model "$IMPL_MODEL" --permission-mode "$PERMISSION_MODE" \
    --disallowedTools "${DISALLOWED_TOOLS[@]}" 2>&1)"
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
PROJECT_MEMORY=$MEMORY_STATUS
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
}
