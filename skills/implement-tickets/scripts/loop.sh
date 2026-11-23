#!/usr/bin/env bash
# loop.sh — the short loop's one tool: the project coordinator's hands on a
# board that runs without the board session, tk.sh's state machine and gates,
# the launchers, Herdr and the PR creator. See docs/agents/short-loop.md and
# docs/adr/0012-the-short-loop.md.
#
# A board opts in with `.scratch/<board>/loop` holding `short` (loop.sh adopt).
# loop.sh refuses every other board, and tk.sh refuses the verbs that act
# (launch, resume, pr, push, merge, …) on a short-loop board, so the two loops
# never act on the same board.
#
# Nothing here stores a ticket's state. Every verb derives it from facts:
# the ticket file's own lines (Status resolved/dropped, Owner, Blocked by),
# git (the branch, its worktree, has it landed), the forge (the PR and its
# review), the box runner (devbox-run: is the session alive, is it working),
# and two files the ticket's session writes: its report and its questions.
#
# Usage (<board> as tk.sh takes it: a Jira id or slug under .scratch/):
#   loop.sh adopt   <board>                 mark the board as a short-loop board
#   loop.sh status  <board> [NN] [--json]   every ticket's state, derived; `next` lists the startable ones
#   loop.sh start   <board> <NN> [--type feat|fix|...] [--model m] [--effort e] [--note f]
#                                           worktree + branch from the base, the thread brief, a runner
#                                           session; only a ticket that is ready (or stopped)
#   loop.sh resume  <board> <NN> [--note f] the runner's resume of its session; with no session to
#                                           resume, a fresh start in the worktree as it stands
#   loop.sh say     <board> <NN> <file|->   a message to the ticket's session
#   loop.sh log     <board> <NN> [lines]    the session's last lines
#   loop.sh report  <board> <NN>            the ticket's report, as the session saved it
#   loop.sh answer  <board> <NN> <answer.json>   {"id","a"[,"scope":"project"]}: the questions file, the
#                                           ticket's ## Answers, the repo's answers ledger, then the session
#   loop.sh pr      <board> <NN> --title <t> --body-file <f> [--message-file <f>]
#                                           commit the worktree, push the branch, open a DRAFT PR, ask the
#                                           developer to review it; a PR already open gets the new commits
#   loop.sh merge   <board> <NN> [--his-word "<what he said>"]
#                                           on the developer's word only: the PR approved (or his word, where
#                                           the forge can't record his approval), checks not red, not
#                                           conflicting; a draft is marked ready, then the forge merges it
#   loop.sh done    <board> <NN> "<what was done>"   an **Owner:** me ticket (a gate) he says is done
#   loop.sh watch   <board> --inbox <dir>   for the coordinator's inbox watcher: one event file per ticket
#                                           that moved (start, built, question, idle, resume, changes, fixed,
#                                           approved, landed); exit 3 when a lookup failed (nothing recorded)
#
# Any verb takes `-C <repo>` first (loop.sh -C <repo> status …): run as if from that checkout.
#
# Environment:
#   TICKET_RUNNER       the box runner (default devbox-run)
#   TICKET_PR_REVIEWER  who reviews the draft PR: a GitHub login or an Azure DevOps user/email.
#                       Empty: none requested (GitHub refuses a review request from the PR's author)
#   TICKET_PR_ASSIGNEE  GitHub only, default @me
#   TICKET_LOOP_PERMISSION_MODE  the thread session's --permission-mode (default bypassPermissions,
#                       as the old launcher's; commit, push and PR commands stay disallowed)
#
# Exit codes: 0 ok | 1 error/refused | 21 no live session (say/answer: answer written, not sent)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${TICKET_LIB_DIR:-}" ]]; then LIB_DIR="$TICKET_LIB_DIR"; else
  for d in "$(dirname "$SKILL_DIR")" "$(dirname "$(dirname "$SKILL_DIR")")/lib"; do
    [[ -f "$d/ticket-git-repo.sh" ]] && { LIB_DIR="$d"; break; }
  done
fi
for lib in ticket-git-repo.sh ticket-account.sh ticket-launcher.sh; do
  [[ -f "${LIB_DIR:-}/$lib" ]] || { echo "ERROR: shared library $lib not found — re-run install.sh, or set TICKET_LIB_DIR" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$LIB_DIR/$lib"
done
# shellcheck source=/dev/null
source "$SKILL_DIR/scripts/board-lib.sh"
load_ticket_models

RUNNER="${TICKET_RUNNER:-devbox-run}"
# Cross-repo blockers (<repo>:<NN>) are read from the sibling clone first.
export TICKET_XBOARD_SIBLING_FIRST=1
THREAD_TEMPLATE="$SKILL_DIR/templates/thread-prompt.md"
LOOP_MARK=short

# ---- the board ------------------------------------------------------------------

is_short_board() { [[ -f "$BOARD_PATH/loop" ]] && [[ "$(tr -d '[:space:]' <"$BOARD_PATH/loop")" == "$LOOP_MARK" ]]; }

# board_init, then refuse a board that hasn't opted in.
loop_init() {
  board_init "${1:-}"
  is_short_board || die "board $BOARD_ID is not a short-loop board (no $BOARD_PATH/loop) — the board session runs it; loop.sh adopt $BOARD_ID moves it here"
}

# Where a ticket's own files live: brief, report, questions. Outside the repo
# and its worktrees, so nothing here can be committed.
ticket_dir() { local d; d="$(board_state_dir)/loop/$BOARD_SLUG/$1"; mkdir -p "$d"; echo "$d"; }

slugify() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }

# The branch a ticket works on: its **Branch:** line when it has one (a ticket
# the old loop started), else <type>-<NN>-<slug>, the shape tk.sh launch uses.
# A branch of any type for this number that already exists is the ticket's.
ticket_branch() {
  local t="$1" type="${2:-}" b nn slug cand
  b="$(jq -r '.branch // ""' <<<"$t")"
  [[ -n "$b" ]] && { echo "$b"; return; }
  nn="$(jq -r .nn <<<"$t")"
  slug="$(slugify "$(jq -r .title <<<"$t")" | cut -d- -f1-4)"
  if [[ -z "$type" ]]; then
    for cand in feat fix refactor chore docs test perf ci; do
      b="$cand-$nn-$slug"; b="${b:0:40}"; b="${b%-}"; b="${b//--/-}"
      if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$b" \
         || { (( HAS_REMOTE )) && git -C "$ROOT" show-ref --verify --quiet "refs/remotes/$REMOTE/$b"; }; then
        echo "$b"; return
      fi
    done
    type=feat; [[ "$(jq -r .kind <<<"$t")" == doc ]] && type=docs
  fi
  b="$type-$nn-$slug"; b="${b:0:40}"; b="${b%-}"; b="${b//--/-}"
  echo "$b"
}

# Always beside this checkout, whatever a **Worktree:** line says: a board copied
# from another checkout names that checkout's worktrees, where another agent may run.
worktree_of() { echo "$(dirname "$ROOT")/${REPO_NAME}--$1"; }

# The runner's name for a ticket's session: unique per box.
session_name() {
  local n="${REPO_NAME}-${BOARD_SLUG}-$1"
  n="$(sed -E 's/[^A-Za-z0-9_-]+/-/g; s/^[^A-Za-z0-9]+//' <<<"$n")"
  echo "${n:0:63}"
}

# The runner's status object for one session, or {} when it has none (or no runner).
# Inside derive_all, one `devbox-run status` call answers every ticket (RUNNER_ALL);
# RUNNER_FAILED says that call failed, so a watcher can tell "no session" from "no answer".
RUNNER_ALL=""; RUNNER_FAILED=0
runner_status() {
  command -v "$RUNNER" >/dev/null 2>&1 || { echo '{}'; return 0; }
  local out
  if [[ -n "$RUNNER_ALL" ]]; then out="$RUNNER_ALL"
  else out="$("$RUNNER" status "$1" 2>/dev/null)" || { echo '{}'; return 0; }; fi
  jq -c --arg n "$1" '(.sessions // []) | map(select(.name == $n)) | first // {}' <<<"$out" 2>/dev/null || echo '{}'
}

need_runner() { command -v "$RUNNER" >/dev/null 2>&1 || die "the box runner '$RUNNER' isn't installed (devboxes' bin/devbox-run; TICKET_RUNNER names another)"; }

# ---- state, from facts ------------------------------------------------------------

# A landed ticket's one stored fact: **Status:** resolved, as tk.sh resolve
# writes it. Other boards read it (a cross-repo blocker <repo>:<NN>), and only
# the file can tell them. Written once; true when it wrote the line.
record_landed() {
  local t="$1" l="$2" f sha="" line tmp
  f="$(jq -r .file <<<"$t")"
  [[ -w "$f" ]] || return 1
  grep -qE '^\*\*Status:\*\*[[:space:]]*resolved' "$f" && return 1
  case "$l" in
    yes:squash:*) sha="${l#yes:squash:}" ;;
    yes:pr#*) sha="$(forge_merge_commit "${l#yes:pr#}" 2>/dev/null || true)"; [[ -n "$sha" ]] || sha="PR #${l#yes:pr#}" ;;
    *) sha="$(landed_tip "$(ticket_branch "$t")" 2>/dev/null || true)" ;;
  esac
  line="**Status:** resolved — merged into $BASE_BRANCH as ${sha:-?} on $(date +%F)"
  tmp="$(mktemp)"
  if grep -q '^\*\*Status:\*\*' "$f"; then
    awk -v line="$line" '/^\*\*Status:\*\*/ { print line; next } /^\*\*Agent:\*\*/ { next } { print }' "$f" >"$tmp"
  else
    awk -v line="$line" '{ print } /^# [0-9]+:/ && !done { print ""; print line; done = 1 }' "$f" >"$tmp"
  fi
  cat "$tmp" >"$f"; rm -f "$tmp"
}

# Does a session that finished its turn still have background subagents? Either
# fact is enough: Claude Code's footer naming running agents ("↓ to manage"),
# or a subagent transcript under the session's folder written in the last
# TICKET_LOOP_SUBAGENT_QUIET_S seconds (default 120).
subagents_running() {
  local rs="$1" sess="$2" tr sid dir quiet="${TICKET_LOOP_SUBAGENT_QUIET_S:-120}"
  "$RUNNER" log "$sess" --lines 8 2>/dev/null | grep -qE 'to manage|agents? running|background (task|agent)' && return 0
  tr="$(jq -r '.transcript // ""' <<<"$rs")"; sid="$(jq -r '.session_id // ""' <<<"$rs")"
  [[ -n "$tr" && -n "$sid" ]] || return 1
  dir="$(dirname "$tr")/$sid"
  [[ -d "$dir" ]] || return 1
  [[ -n "$(find "$dir" -type f -name '*.jsonl' -newermt "-${quiet} seconds" -print -quit 2>/dev/null)" ]]
}

# GitHub leaves reviewDecision empty where no rule requires a review: read the
# latest review of each reviewer instead. Prints the PR object with .review set.
review_decision() {
  local pr="$1" lr
  [[ "$FORGE" == github && -z "$(jq -r '.review // ""' <<<"$pr")" ]] || { echo "$pr"; return; }
  lr="$(gh_ pr view "$(jq -r .number <<<"$pr")" --json latestReviews --jq '[.latestReviews[]?.state]' 2>/dev/null || echo '[]')"
  jq -c --argjson r "${lr:-[]}" '.review = (if ($r | index("CHANGES_REQUESTED")) then "CHANGES_REQUESTED" elif ($r | index("APPROVED")) then "APPROVED" else "" end)' <<<"$pr"
}

# One ticket's facts and state as one JSON object. Needs DONE (a JSON array of
# the numbers already derived done or dropped) for its blockers.
derive() {
  local t="$1" nn status owner branch wt dir sess rs alive turn pr="" prj='null' qf rf q_open=0 report=false
  local landed_ans="-" state why has_branch=false has_wt=false open_blockers
  nn="$(jq -r .nn <<<"$t")"; status="$(jq -r .status <<<"$t")"; owner="$(jq -r .owner <<<"$t")"
  branch="$(ticket_branch "$t")"; wt="$(worktree_of "$branch")"
  dir="$(ticket_dir "$nn")"; sess="$(session_name "$nn")"
  rf="$dir/report.md"; qf="$dir/questions.json"
  [[ -s "$rf" ]] && report=true
  [[ -s "$qf" ]] && q_open="$(jq '[.[]? | select((.a // "") == "" and .blocks == true)] | length' "$qf" 2>/dev/null || echo 0)"
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" && has_branch=true
  (( HAS_REMOTE )) && git -C "$ROOT" show-ref --verify --quiet "refs/remotes/$REMOTE/$branch" && has_branch=true
  [[ -d "$wt" ]] && has_wt=true
  # A report only counts beside work: changes in the worktree or commits on the branch.
  if [[ "$report" == true ]]; then
    if [[ "$has_wt" == true ]] && { [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]] || [[ "$(git -C "$wt" rev-list --count "$BASE_REF..HEAD" 2>/dev/null || echo 0)" -gt 0 ]]; }; then :
    else report=false; fi
  fi
  rs="$(runner_status "$sess")"
  alive="$(jq -r '.alive // false' <<<"$rs")"; turn="$(jq -r '.last_turn // ""' <<<"$rs")"
  local dialog; dialog="$(jq -r '.dialog // ""' <<<"$rs")"
  # The main turn can end while a subagent it dispatched in the background
  # still runs: the runner then says assistant_done. Count it as working.
  if [[ "$alive" == true && "$turn" == assistant_done ]] && subagents_running "$rs" "$sess"; then turn=working; fi
  # A ticket the old loop started in another checkout (a board copied from it):
  # its run-state lines name a worktree that isn't ours. While that worktree
  # exists, or its branch is nowhere we can see (unpushed over there), the work
  # lives there and this loop must not start a second agent on it.
  local elsewhere="" owt
  owt="$(jq -r '.worktree // ""' <<<"$t")"
  if [[ "$status" == in-progress && -n "$owt" && "$owt" != "$wt" && "$has_wt" == false && "$alive" != true ]]; then
    if [[ -d "$owt" ]]; then elsewhere="the old loop works it in $owt — finish it there, or remove that worktree to bring it here"
    elif [[ "$has_branch" == false ]]; then elsewhere="started by the old loop in $owt, and branch $branch is nowhere here (unpushed there?) — push it from there to bring it here"
    fi
  fi
  # A board copied before its ticket started has no run-state lines: look for
  # the old loop's worktree of this number beside the main checkouts (~/work).
  local work="${TICKET_WORK_DIR:-$HOME/work}" d
  if [[ -z "$elsewhere" && "$has_wt" == false && "$alive" != true && "$(dirname "$ROOT")" != "$(readlink -f "$work" 2>/dev/null || echo "$work")" ]]; then
    for d in "$work/$REPO_NAME"--*-"$nn"-*; do
      [[ -d "$d" && "$d" != "$wt" ]] || continue
      elsewhere="the old loop has a worktree for it: $d — finish it there, or remove that worktree to bring it here"; break
    done
  fi
  open_blockers="$(jq -r --argjson fin "$DONE" '[.blockers[] | select(IN($fin[]) | not)] + (.xblockers_open // []) | join(",")' <<<"$t")"

  if [[ "$status" == dropped ]]; then state=dropped; why="the ticket says dropped"
  elif [[ "$status" == resolved ]]; then state="done"; why="the ticket says resolved"
  else
    # Asked even with no branch here: a ticket the old loop worked elsewhere
    # (its branch never fetched, or deleted after the merge) lands by its PR.
    if [[ "$has_branch" == false && -n "$elsewhere" ]] && (( HAS_REMOTE )); then
      run_git_net fetch "$REMOTE" "+refs/heads/$branch:refs/remotes/$REMOTE/$branch" --quiet 2>/dev/null \
        && git -C "$ROOT" show-ref --verify --quiet "refs/remotes/$REMOTE/$branch" && has_branch=true
    fi
    landed_ans="$(landed "$branch" "$(jq -r '.base // ""' <<<"$t")")"
    # The runner asks the forge too (status --pr): a PR it saw merged is landed,
    # whatever git or our own forge call could see from here.
    if [[ "$landed_ans" != yes* && "$has_branch" == true ]] && command -v "$RUNNER" >/dev/null 2>&1; then
      local rpr; rpr="$("$RUNNER" status "$sess" --pr 2>/dev/null | jq -c --arg n "$sess" '(.sessions // []) | map(select(.name == $n)) | first | .pr // empty' 2>/dev/null || true)"
      if [[ -n "$rpr" && "$(jq -r '.state // ""' <<<"$rpr" 2>/dev/null)" == merged ]]; then landed_ans="yes:pr#$(jq -r .number <<<"$rpr")"; fi
    fi
    if [[ "$landed_ans" == yes* ]]; then
      state="done"; why="landed (${landed_ans#yes:})"
      record_landed "$t" "$landed_ans" && why+="; **Status:** resolved written"
      if [[ "$alive" == true && "$turn" == assistant_done ]] && ! subagents_running "$rs" "$sess"; then
        "$RUNNER" stop "$sess" >/dev/null 2>&1 && why+="; its finished session stopped"
      fi
    elif [[ "$owner" == me ]]; then state=yours; why="**Owner:** me — loop.sh done when he says it is"
    elif [[ -n "$open_blockers" ]]; then state=blocked; why="blocked by $open_blockers"
    elif [[ -n "$elsewhere" ]]; then state=elsewhere; why="$elsewhere"
    else
      if [[ "$has_branch" == true ]] && forge_ok; then pr="$(forge_pr_open "$branch" 2>/dev/null || true)"; fi
      [[ -n "$pr" ]] && pr="$(review_decision "$pr")"
      [[ -n "$pr" ]] && prj="$pr"
      if [[ -n "$pr" ]]; then
        case "$(jq -r '.review // ""' <<<"$pr")" in
          APPROVED) state=approved; why="PR approved — merge on his word" ;;
          CHANGES_REQUESTED) state=changes; why="changes requested on the PR" ;;
          *) state=review; why="PR open$( [[ "$(jq -r .isDraft <<<"$pr")" == true ]] && echo " (draft)"), waiting on his review" ;;
        esac
        [[ "$alive" == true && "$turn" == working ]] && why+="; its session is working"
      elif [[ "$alive" == true && -n "$dialog" ]]; then state=idle; why="session $sess shows a $dialog dialog — loop.sh log to see it (devbox-run keys answers it)"
      elif [[ "$alive" == true && "$turn" != assistant_done ]]; then state=working; why="session $sess is working"
      elif (( q_open > 0 )); then state=asking; why="$q_open blocking question(s) in $qf"
      elif [[ "$report" == true ]]; then state=built; why="report written — the coordinator reads it and opens the draft PR"
      elif [[ "$alive" == true ]]; then state=idle; why="session $sess is at its prompt with no report"
      elif [[ "$has_wt" == true || "$has_branch" == true ]]; then state=stopped; why="work exists, no live session — loop.sh resume"
      else state=ready; why="nothing started; every blocker done"
      fi
    fi
  fi
  jq -cn --arg nn "$nn" --arg title "$(jq -r .title <<<"$t")" --arg state "$state" --arg why "$why" \
    --arg branch "$branch" --arg worktree "$wt" --argjson has_branch "$has_branch" --argjson has_worktree "$has_wt" \
    --arg session "$sess" --argjson runner "$rs" --argjson pr "$prj" --arg landed "$landed_ans" \
    --arg report "$rf" --argjson reported "$report" --arg questions "$qf" --argjson asking "$q_open" \
    --arg owner "$owner" --arg smodel "$(jq -r .smodel <<<"$t")" --arg seffort "$(jq -r .seffort <<<"$t")" \
    --argjson blockers "$(jq -c .blockers <<<"$t")" \
    '{nn: $nn, title: $title, state: $state, why: $why, owner: $owner, blockers: $blockers,
      branch: $branch, has_branch: $has_branch, worktree: $worktree, has_worktree: $has_worktree,
      session: $session, alive: ($runner.alive // false), last_turn: ($runner.last_turn // null),
      transcript: ($runner.transcript // null), pr: $pr, landed: $landed,
      report: $report, reported: $reported, questions: $questions, open_questions: $asking,
      suggested_model: $smodel, suggested_effort: $seffort}'
}

# Sets STATES: every ticket derived, in number order. A ticket is derived after
# the ones it can be blocked by, which on a board are lower numbers; a blocker
# with a higher number is found done in a second pass.
derive_all() {
  local pass t row rows done_now
  fetch_board_refs >&2
  forge_cache_begin
  RUNNER_ALL=""; RUNNER_FAILED=0
  if command -v "$RUNNER" >/dev/null 2>&1; then
    if ! RUNNER_ALL="$("$RUNNER" status 2>/dev/null)" || ! jq -e '.sessions | type == "array"' <<<"$RUNNER_ALL" >/dev/null 2>&1; then
      RUNNER_ALL='{"sessions": []}'; RUNNER_FAILED=1
    fi
  fi
  DONE='[]'
  for pass in 1 2; do
    rows=""
    while IFS= read -r t; do
      row="$(derive "$t")"
      rows+="$row"$'\n'
      jq -e '.state | IN("done", "dropped")' <<<"$row" >/dev/null && DONE="$(jq -c --arg n "$(jq -r .nn <<<"$row")" '. + [$n] | unique' <<<"$DONE")"
    done < <(jq -c '.[]' <<<"$BOARD_JSON")
    done_now="$DONE"
    STATES="$(jq -s '.' <<<"$rows")"
    # Only a blocker numbered above the ticket it blocks needs the second pass.
    jq -e 'any(.[]; .nn as $n | .blockers | any(tonumber > ($n | tonumber)))' <<<"$BOARD_JSON" >/dev/null || break
    [[ "$pass" == 1 ]] && DONE="$done_now"
  done
  # A forge listing that failed reads as "no PR" everywhere: say so for watch.
  FORGE_FAILED=0
  compgen -G "$FORGE_CACHE/*.err" >/dev/null && FORGE_FAILED=1
  forge_cache_end
  RUNNER_ALL=""
}

state_of() { jq -c --arg n "$1" 'map(select((.nn | tonumber) == ($n | tonumber))) | first // empty' <<<"$STATES"; }

# ---- verbs --------------------------------------------------------------------------

cmd_adopt() {
  board_init "${1:?usage: loop.sh adopt <board>}"
  if is_short_board; then echo "ALREADY $BOARD_ID is a short-loop board"; return 0; fi
  printf '%s\n' "$LOOP_MARK" >"$BOARD_PATH/loop"
  echo "ADOPTED $BOARD_ID — tk.sh's acting verbs now refuse it; loop.sh runs it"
}

cmd_status() {
  local board="${1:?usage: loop.sh status <board> [NN] [--json]}"; shift
  local one="" json=0
  for a in "$@"; do case "$a" in --json) json=1 ;; *) one="$a" ;; esac; done
  loop_init "$board"
  derive_all
  local out="$STATES"
  [[ -n "$one" ]] && out="$(jq -c --arg n "$one" '[.[] | select((.nn | tonumber) == ($n | tonumber))]' <<<"$STATES")"
  if (( json )); then
    jq -n --arg board "$BOARD_ID" --arg repo "$ROOT" --arg base "$BASE_BRANCH" --arg forge "$FORGE" \
      --argjson max "$(policy_resolve 2>/dev/null | jq '.max_parallel // 3' 2>/dev/null || echo 3)" --argjson t "$out" \
      '{board: $board, repo: $repo, base: $base, forge: $forge, max_parallel: $max,
        running: ([$t[] | select(.state == "working")] | length),
        next: [$t[] | select(.state == "ready") | .nn], tickets: $t}'
    return
  fi
  echo "BOARD $BOARD_ID  repo $ROOT  base $BASE_BRANCH  forge $FORGE"
  jq -r '.[] | "\(.nn)  \(.state | . + " " * (9 - length))  \(.title)\n      \(.why)\(if .pr then "  " + .pr.url else "" end)"' <<<"$out"
  [[ -n "$one" ]] || echo "NEXT $(jq -r '[.[] | select(.state == "ready") | .nn] | if length == 0 then "none" else join(" ") end' <<<"$STATES")"
}

# The board's other open tickets, one line each, for a thread's brief (from
# STATES, which derive_all set).
other_threads() {
  local lines
  lines="$(jq -r --arg n "$1" '[.[] | select((.nn | tonumber) != ($n | tonumber))
      | select(.state | IN("done", "dropped") | not)]
    | if length == 0 then "- none: this is the board'"'"'s only open ticket"
      else .[] | "- **\(.nn)** \(.title): \(.state)\(if .state == "working" or .state == "idle" or .state == "built" then " (branch `\(.branch)`)" else "" end)" end' <<<"$STATES")"
  printf '%s\n' "$lines"
}

# The thread brief for one ticket, rendered to <dir>/brief.md.
render_brief() {
  local t="$1" branch="$2" wt="$3" base_commit="$4" dir="$5" file tpl untested=0
  file="$(jq -r .file <<<"$t")"
  [[ -f "$THREAD_TEMPLATE" ]] || die "template not found: $THREAD_TEMPLATE"
  tpl="$(cat "$THREAD_TEMPLATE")"
  grep -qiE '^\*\*Seams under test:\*\*[[:space:]]*None' "$file" && untested=1
  local review_effort="$REVIEW_EFFORT"; (( untested )) && review_effort="$REVIEW_EFFORT_UNTESTED"
  # The --agents definition (start_session) reads it: the reviewer of a ticket
  # nothing can test thinks harder, as with the old launcher.
  REVIEW_EFFORT="$review_effort"
  resolve_project_memory
  tpl="${tpl//'{{BRANCH}}'/"$branch"}"
  tpl="${tpl//'{{WORKTREE}}'/"$wt"}"
  tpl="${tpl//'{{BASE_BRANCH}}'/"$BASE_BRANCH"}"
  tpl="${tpl//'{{BASE_COMMIT}}'/"$base_commit"}"
  tpl="${tpl//'{{REPORT_FILE}}'/"${BRIEF_REPORT:-$dir/report.md}"}"
  tpl="${tpl//'{{QUESTIONS_FILE}}'/"${BRIEF_QUESTIONS:-$dir/questions.json}"}"
  tpl="${tpl//'{{MESSAGES_FILE}}'/"${BRIEF_MESSAGES:-$dir/messages.json}"}"
  tpl="${tpl//'{{IMPL_MODEL}}'/"$IMPL_MODEL"}"
  tpl="${tpl//'{{REVIEW_MODEL}}'/"$REVIEW_MODEL"}"
  tpl="${tpl//'{{REVIEW_EFFORT}}'/"$review_effort"}"
  tpl="${tpl//'{{SCOUT_MODEL}}'/"$SCOUT_MODEL"}"
  tpl="${tpl//'{{RESEARCH_MODEL}}'/"$RESEARCH_MODEL"}"
  tpl="${tpl//'{{TEST_MODEL}}'/"$TEST_MODEL"}"
  tpl="${tpl//'{{CHECK_MODEL}}'/"$CHECK_MODEL"}"
  fill_prose '{{PROJECT_MEMORY}}' "${MEMORY_BLOCK:-}"
  fill_prose '{{ANSWERS_LEDGER}}' "$(answers_ledger_block "$BOARD_ID" "$(jq -r .nn <<<"$t")")"
  fill_prose '{{TICKET}}' "$(cat "$file")"
  fill_prose '{{OTHER_THREADS}}' "$(other_threads "$(jq -r .nn <<<"$t")")"
  fill_prose '{{AGENT_USER_NOTE}}' "$(agent_brief_note)"
  printf '%s\n' "$tpl" >"$dir/brief.md"
}

# Starts the thread session for one ticket in <wt> through the runner.
start_session() {
  local sess="$1" wt="$2" brief="$3" first="$4" model="$5" effort="$6"
  local -a cmd agents_arg=() as_agent=()
  # With the box's agent user on, the session runs as that user (the runner's
  # --agent: sudo and devboxes' wrapper), reading its brief from the shared copy.
  agent_on && as_agent=(--agent)
  build_session_agents ticket-implementer ticket-reviewer ticket-scout ticket-researcher ticket-tester ticket-criteria-checker
  [[ -n "$SESSION_AGENTS_JSON" ]] && agents_arg=(--agents "$SESSION_AGENTS_JSON")
  cmd=(claude --model "$COORD_MODEL" --effort "$COORD_EFFORT"
       --permission-mode "${TICKET_LOOP_PERMISSION_MODE:-bypassPermissions}"
       --append-system-prompt-file "$brief"
       ${agents_arg[@]+"${agents_arg[@]}"}
       --disallowedTools "Bash(git add:*)" "Bash(git commit:*)" "Bash(git push:*)" "Bash(git stash:*)"
         "Bash(git reset:*)" "Bash(git rebase:*)" "Bash(git checkout:*)" "Bash(git switch:*)"
         "Bash(gh pr:*)" "Bash(az repos pr:*)")
  # The implementer's model and effort are the ticket's; the session itself
  # coordinates on the configured coordinator setting, as the old launcher's.
  # The first prompt goes to the runner, not into claude's arguments, so its
  # resume doesn't send it again; --trust answers the folder-trust dialog.
  local pf; pf="$(dirname "$brief")/first-prompt.md"; printf '%s\n' "$first" >"$pf"
  "$RUNNER" start "$sess" --dir "$wt" --trust --prompt-file "$pf" ${as_agent[@]+"${as_agent[@]}"} \
    --env "TICKET_IMPL_MODEL=$model" --env "TICKET_IMPL_EFFORT=$effort" -- "${cmd[@]}" >/dev/null
}

cmd_start() {
  local usage="usage: loop.sh start <board> <NN> [--type feat|fix|...] [--model m] [--effort e] [--note f]"
  local board="${1:?$usage}" nn="${2:?$usage}"; shift 2
  local type="" model="" effort="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) type="$2"; shift 2 ;; --model) model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;; --note) note="$2"; shift 2 ;;
      *) die "unknown argument: $1 — $usage" ;;
    esac
  done
  [[ -z "$type" || "$type" =~ ^(feat|fix|refactor|chore|docs|test|perf|ci)$ ]] || die "--type must be one of feat fix refactor chore docs test perf ci"
  loop_init "$board"; need_runner
  derive_all
  local t s state branch wt dir sess base_commit first brief
  t="$(ticket_json "$nn")"; nn="$(jq -r .nn <<<"$t")"; s="$(state_of "$nn")"
  state="$(jq -r .state <<<"$s")"
  [[ "$state" == ready || "$state" == stopped ]] || die "ticket $nn is $state ($(jq -r .why <<<"$s")) — only a ready or stopped ticket starts"
  grep -qE '^# [0-9]+:' "$(jq -r .file <<<"$t")" || die "ticket $nn has no '# $nn: <Title>' heading — add one, then start"
  model="${model:-$(jq -r '.smodel // ""' <<<"$t")}"; model="${model:-$IMPL_MODEL}"
  effort="${effort:-$(jq -r '.seffort // ""' <<<"$t")}"; effort="${effort:-$IMPL_EFFORT}"
  [[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid model '$model'"
  effort_valid "$effort" || die "invalid effort '$effort'"
  IMPL_MODEL="$model"; IMPL_EFFORT="$effort"

  branch="$(ticket_branch "$t" "$type")"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "branch name rejected by git: $branch"
  wt="$(worktree_of "$branch")"
  dir="$(ticket_dir "$nn")"; sess="$(session_name "$nn")"

  if [[ -d "$wt" ]]; then
    # The worktree as it stands: never pulled, reset or rebased here.
    [[ "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" == "$branch" ]] || die "worktree $wt is not on $branch — not touching it"
    log "worktree $wt exists — starting in it as it stands"
  elif git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$ROOT" worktree add "$wt" "$branch" >&2
  elif (( HAS_REMOTE )) && git -C "$ROOT" show-ref --verify --quiet "refs/remotes/$REMOTE/$branch"; then
    git -C "$ROOT" worktree add -b "$branch" "$wt" "$REMOTE/$branch" >&2
  else
    # fetch_board_refs (derive_all) just fetched the base.
    git -C "$ROOT" worktree add -b "$branch" "$wt" "$BASE_REF" >&2
  fi
  base_commit="$(git -C "$wt" merge-base HEAD "$BASE_REF" 2>/dev/null || git -C "$wt" rev-parse HEAD)"

  # A report or questions from an earlier run would read as this run's: keep
  # them aside. A copy, not a move: with the agent user on they are links to
  # the shared copies, which this run reuses.
  local f stamp; stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  for f in report.md questions.json messages.json; do
    [[ -e "$dir/$f" ]] && cp -L "$dir/$f" "$dir/$f.$stamp"
    rm -f "$dir/$f"
  done
  if [[ -f "$dir/questions.json.$stamp" ]]; then
    jq '[.[]? | select((.a // "") != "")]' "$dir/questions.json.$stamp" >"$dir/questions.json" 2>/dev/null || printf '[]' >"$dir/questions.json"
  fi

  # With the agent user on, the agent can't enter the developer's home: its
  # brief, report and questions are shared copies (agent_state_file), linked
  # from these paths, which are the ones this script reads. Each starts as this
  # run's plain file, which agent_state_file copies over once.
  BRIEF_REPORT="" BRIEF_QUESTIONS="" BRIEF_MESSAGES="" brief="$dir/brief.md"
  printf '[]' >"$dir/messages.json"
  if agent_on; then
    : >"$dir/report.md"
    [[ -f "$dir/questions.json" ]] || printf '[]' >"$dir/questions.json"
    BRIEF_REPORT="$(agent_state_file "$dir/report.md")"
    BRIEF_QUESTIONS="$(agent_state_file "$dir/questions.json" '[]')"
    BRIEF_MESSAGES="$(agent_state_file "$dir/messages.json" '[]')"
    rm -f "$dir/brief.md"
  fi
  render_brief "$t" "$branch" "$wt" "$base_commit" "$dir"
  if agent_on; then
    agent_prepare_worktree "$wt"
    brief="$(agent_state_file "$dir/brief.md")"
  fi
  WT="$wt"; export WT; trust_worktree_mise || true
  first="Start ticket $nn: follow your instructions from Phase 0."
  if [[ "$state" == stopped ]]; then
    first="Ticket $nn: an earlier session worked in this worktree and stopped. Look at what it left (git status, git diff $base_commit), then carry on from the phase that work reaches; don't redo what is done."
  fi
  [[ -n "$note" && -s "$note" ]] && first+=$'\n\n'"$(cat "$note")"
  start_session "$sess" "$wt" "$brief" "$first" "$model" "$effort"
  echo "STARTED $nn as $sess on $branch ($wt) — implementer $model @ $effort, reviewer $REVIEW_MODEL"
  echo "REPORT $dir/report.md"
}

cmd_resume() {
  local usage="usage: loop.sh resume <board> <NN> [--note f]"
  local board="${1:?$usage}" nn="${2:?$usage}" note=""; shift 2
  [[ "${1:-}" == --note ]] && note="${2:?$usage}"
  loop_init "$board"; need_runner
  local t sess rs; t="$(ticket_json "$nn")"; nn="$(jq -r .nn <<<"$t")"; sess="$(session_name "$nn")"
  rs="$(runner_status "$sess")"
  if [[ "$(jq -r '.alive // false' <<<"$rs")" == true ]]; then
    echo "ALIVE $sess is running — loop.sh say to talk to it"; return 0
  fi
  if [[ -n "$(jq -r '.session_id // ""' <<<"$rs")" ]]; then
    "$RUNNER" resume "$sess" >/dev/null
    echo "RESUMED $sess (its last conversation)"
    if [[ -n "$note" && -s "$note" ]]; then sleep "${TICKET_LOOP_RESUME_WAIT:-5}"; "$RUNNER" say "$sess" - <"$note" >/dev/null || true; fi
    return 0
  fi
  echo "no session to resume for $nn — starting fresh in its worktree"
  local -a a=(start "$BOARD_ID" "$nn"); [[ -n "$note" ]] && a+=(--note "$note")
  "$0" "${a[@]}"
}

cmd_say() {
  local usage="usage: loop.sh say <board> <NN> <file|->"
  local board="${1:?$usage}" nn="${2:?$usage}" src="${3:?$usage}"
  loop_init "$board"; need_runner
  local sess; sess="$(session_name "$(jq -r .nn <<<"$(ticket_json "$nn")")")"
  [[ "$(jq -r '.alive // false' <<<"$(runner_status "$sess")")" == true ]] || { echo "NOT SENT — $sess isn't running (loop.sh resume)"; return 21; }
  local rc=0
  if [[ "$src" == - ]]; then "$RUNNER" say "$sess" - >/dev/null || rc=$?; else "$RUNNER" say "$sess" - <"$src" >/dev/null || rc=$?; fi
  (( rc != 5 )) || { echo "NOT SENT — $sess shows a dialog or its pane is dead (loop.sh log)"; return 21; }
  (( rc == 0 )) || die "devbox-run say failed (exit $rc)"
  echo "SENT to $sess"
}

cmd_log() {
  local board="${1:?usage: loop.sh log <board> <NN> [lines]}" nn="${2:?usage: loop.sh log <board> <NN> [lines]}"
  loop_init "$board"; need_runner
  "$RUNNER" log "$(session_name "$(jq -r .nn <<<"$(ticket_json "$nn")")")" --lines "${3:-60}"
}

cmd_report() {
  local board="${1:?usage: loop.sh report <board> <NN>}" nn="${2:?usage: loop.sh report <board> <NN>}" f
  loop_init "$board"
  f="$(ticket_dir "$(jq -r .nn <<<"$(ticket_json "$nn")")")/report.md"
  [[ -s "$f" ]] || die "no report yet for $nn ($f)"
  cat "$f"
}

append_answer() {
  local file="$1" id="$2" q="$3" ans="$4" at="$5"
  grep -q '^## Answers$' "$file" || printf '\n## Answers\n\nWhat the developer answered while this ticket ran. Where an answer and the text above disagree, the answer wins.\n' >>"$file"
  {
    printf '\n- **%s** (%s) %s\n' "${id:-note}" "$at" "${q//$'\n'/ }"
    printf '  Answer: %s\n' "${ans//$'\n'/$'\n'  }"
  } >>"$file"
}

cmd_answer() {
  local usage="usage: loop.sh answer <board> <NN> <answer.json>   ({\"id\": \"q1\", \"a\": \"...\"}; \"scope\": \"project\" when it holds for every ticket)"
  local board="${1:?$usage}" nn="${2:?$usage}" file="${3:?$usage}"
  loop_init "$board"
  local t id q a qf now scope sess msg
  t="$(ticket_json "$nn")"; nn="$(jq -r .nn <<<"$t")"
  jq -e 'type == "object" and (.a | type) == "string" and (.a | gsub("\\s"; "") | length) > 0' "$file" >/dev/null 2>&1 || die "$usage"
  id="$(jq -r '.id // "" | tostring' "$file")"; q="$(jq -r '.q // "" | tostring' "$file")"; a="$(jq -r .a "$file")"
  secret_like "$a" && die "the answer looks like it holds a secret — answer with where it lives, never its value"
  qf="$(ticket_dir "$nn")/questions.json"
  if [[ -n "$id" ]]; then
    q="$(jq -r --arg id "$id" '[.[]? | select((.id // "" | tostring) == $id)] | first | .q // empty' "$qf" 2>/dev/null || true)"
    [[ -n "$q" ]] || die "ticket $nn's session asked no question $id ($qf)"
  fi
  [[ -n "$q" ]] || die "name the question: an id the session asked, or q"
  now="$(date -u +%Y-%m-%dT%H:%MZ)"
  append_answer "$(jq -r .file <<<"$t")" "$id" "$q" "$a" "$now"
  scope="$(jq -r 'if .scope == "project" then "project" else "ticket" end' "$file")"
  answers_ledger_append "$BOARD_ID" "$nn" "$id" "$q" "$a" "$now" "$scope"
  if [[ -n "$id" ]]; then
    jq --arg id "$id" --arg a "$a" --arg at "$now" 'map(if (.id // "" | tostring) == $id then . + {a: $a, at: $at} else . end)' "$qf" >"$qf.tmp" && mv "$qf.tmp" "$qf"
  fi
  echo "WRITTEN under ticket $nn's ## Answers and in the answers ledger ($scope)"
  sess="$(session_name "$nn")"
  if ! command -v "$RUNNER" >/dev/null 2>&1 || [[ "$(jq -r '.alive // false' <<<"$(runner_status "$sess")")" != true ]]; then
    echo "NOT SENT — $sess isn't running; its next start or resume reads the answer"; return 21
  fi
  msg="$(printf 'The developer answered%s:\n\n> %s\n\n%s\n\nIt is also in the ticket'"'"'s ## Answers. Carry on from where you stopped.' "${id:+ your question $id}" "${q//$'\n'/ }" "$a")"
  "$RUNNER" say "$sess" - <<<"$msg" >/dev/null || { echo "NOT SENT — $sess shows a dialog or its pane is dead; its next resume reads the answer"; return 21; }
  echo "SENT to $sess"
}

# ---- the draft PR -------------------------------------------------------------------

# Lines of <file> that name a model or an AI tool: commits and PRs carry none.
model_names() { grep -iE '(^|[^[:alnum:]])(claude|anthropic|opus|sonnet|haiku|fable|chatgpt|gpt-[0-9]|copilot)([^[:alnum:]]|$)' "$1" || true; }

cmd_pr() {
  local usage="usage: loop.sh pr <board> <NN> --title <t> --body-file <f> [--message-file <f>] [--paths-file <f>]"
  local board="${1:?$usage}" nn="${2:?$usage}"; shift 2
  local title="" body="" msgf="" pathsf=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;; --body-file) body="$2"; shift 2 ;;
      --message-file) msgf="$2"; shift 2 ;; --paths-file) pathsf="$2"; shift 2 ;;
      *) die "unknown argument: $1 — $usage" ;;
    esac
  done
  loop_init "$board"
  local_mode && die "$(local_mode_reason long) — no PR to open here"
  forge_off && die "forge is none ($(forge_off_why)) — no PR to open"
  forge_need
  derive_all
  local t s state branch wt pr changed risky_paths tmp_msg tmp_body=""
  t="$(ticket_json "$nn")"; nn="$(jq -r .nn <<<"$t")"; s="$(state_of "$nn")"; state="$(jq -r .state <<<"$s")"
  branch="$(jq -r .branch <<<"$s")"; wt="$(jq -r .worktree <<<"$s")"; pr="$(jq -c .pr <<<"$s")"
  case "$state" in
    built|idle|review|changes) ;;
    *) die "ticket $nn is $state ($(jq -r .why <<<"$s")) — a PR is opened from built work (its report written), or updated while one is open" ;;
  esac
  [[ "$state" == idle ]] && log "ticket $nn has no report — opening the PR on your word anyway"
  [[ -d "$wt" ]] || die "no worktree at $wt"
  [[ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" == "$branch" ]] || die "worktree $wt is not on $branch"
  [[ "$(jq -r '.last_turn // ""' <<<"$s")" == working ]] && die "ticket $nn's session is still working — wait for it"

  # The PR's words are checked before anything is committed or pushed.
  if [[ "$pr" == null ]]; then
    [[ -n "$title" && -n "$body" && -s "$body" ]] || die "--title and --body-file are needed to open the PR — $usage"
    tmp_body="$(mktemp)"; strip_attribution "$body" >"$tmp_body"
    [[ -z "$(internal_ticket_refs "$tmp_body")$(internal_ticket_refs <(printf '%s\n' "$title"))" ]] \
      || die "the PR title or body names an internal ticket number — the client reads it; use the Jira id or nothing"
    secret_like "$(cat "$tmp_body")" && die "the PR body has something that looks like a key or token"
    [[ -z "$(model_names "$tmp_body")$(model_names <(printf '%s\n' "$title"))" ]] \
      || die "the PR title or body names a model or AI tool — leave them out: $( { model_names <(printf '%s\n' "$title"); model_names "$tmp_body"; } | head -1)"
  fi

  # What would be committed: every change in the worktree, guarded.
  changed="$(git -C "$wt" status --porcelain=v1 --untracked-files=all | cut -c4- | sed 's/^.* -> //')"
  if [[ -n "$pathsf" ]]; then
    # Only the paths named (a tester's leftovers stay out); each must be a change.
    local p; while IFS= read -r p; do
      [[ -z "$p" ]] || grep -qxF -- "$p" <<<"$changed" || die "$p (in $pathsf) is not a change in $wt"
    done <"$pathsf"
    changed="$(grep -v '^$' "$pathsf" || true)"
  fi
  risky_paths="$(risky <<<"$changed")"
  [[ -z "$risky_paths" ]] || die "refusing: these paths may hold secrets — remove them or add them to .gitignore: $(tr '\n' ' ' <<<"$risky_paths")"
  if [[ -n "$changed" ]]; then
    if [[ -n "$pathsf" ]]; then xargs -d '\n' git -C "$wt" add -A -- <<<"$changed"; else git -C "$wt" add -A; fi
    secret_like "$(git -C "$wt" diff --cached)" && { git -C "$wt" reset -q; die "refusing: the change has something that looks like a key or token — nothing committed"; }
    tmp_msg="$(mktemp)"
    if [[ -n "$msgf" ]]; then strip_attribution "$msgf" >"$tmp_msg"; else printf '%s\n' "${title:?--title is needed for the commit}" >"$tmp_msg"; fi
    [[ -z "$(internal_ticket_refs "$tmp_msg")" ]] || { git -C "$wt" reset -q; die "the commit message names an internal ticket number: $(internal_ticket_refs "$tmp_msg" | head -1)"; }
    [[ -z "$(model_names "$tmp_msg")" ]] || { git -C "$wt" reset -q; die "the commit message names a model or AI tool: $(model_names "$tmp_msg" | head -1)"; }
    [[ -s "$tmp_msg" ]] || { git -C "$wt" reset -q; die "empty commit message"; }
    git -C "$wt" -c core.hooksPath=/dev/null commit -q -F "$tmp_msg" || { git -C "$wt" reset -q; die "commit failed"; }
    rm -f "$tmp_msg"
    log "committed $(grep -c . <<<"$changed") path(s) on $branch"
  fi
  [[ "$(git -C "$wt" rev-list --count "$BASE_REF..HEAD")" -gt 0 ]] || die "nothing to ship: $branch has no commits over $BASE_REF and no changes"
  run_git_net -C "$wt" push -u "$REMOTE" "$branch" >&2 || die "push failed — nothing forced; see above"

  if [[ "$pr" != null ]]; then
    echo "UPDATED $(jq -r .url <<<"$pr") — the new commits are on the open PR"; return 0
  fi
  local url reviewer="${TICKET_PR_REVIEWER:-}"
  case "$FORGE" in
    github)
      url="$(cd "$wt" && gh_ pr create --draft --base "$BASE_BRANCH" --head "$branch" --title "$title" --body-file "$tmp_body")" || die "gh pr create failed — the branch is pushed; run loop.sh pr again"
      (cd "$wt" && gh_ pr edit "$url" --add-assignee "${TICKET_PR_ASSIGNEE:-@me}" >/dev/null 2>&1) || log "couldn't assign ${TICKET_PR_ASSIGNEE:-@me} (left as is)"
      if [[ -n "$reviewer" ]]; then
        (cd "$wt" && gh_ pr edit "$url" --add-reviewer "$reviewer" >/dev/null 2>&1) || log "couldn't request a review from $reviewer (GitHub refuses the PR's own author) — tell him the link"
      fi ;;
    azure)
      local desc out id; desc="$(cat "$tmp_body")"
      (( ${#desc} <= 4000 )) || desc="${desc:0:3950}"$'\n\n'"… (truncated at Azure DevOps' 4000-character limit)"
      local -a rv=(); [[ -n "$reviewer" ]] && rv=(--reviewers "$reviewer")
      out="$(az_ repos pr create --project "$AZ_PROJECT" --repository "$AZ_REPO" --draft true \
               --source-branch "$branch" --target-branch "$BASE_BRANCH" --title "$title" --description "$desc" ${rv[@]+"${rv[@]}"})" \
        || die "az repos pr create failed — the branch is pushed; run loop.sh pr again"
      id="$(jq -r '.pullRequestId // empty' <<<"$out")"; [[ -n "$id" ]] || die "az repos pr create returned no PR id"
      url="$(forge_pr_get "$id" | jq -r .url)" ;;
    *) die "no forge to open a PR on" ;;
  esac
  rm -f "$tmp_body"
  echo "DRAFT PR $url — waiting on his review${reviewer:+ (review requested from $reviewer)}"
}

cmd_merge() {
  local usage="usage: loop.sh merge <board> <NN> [--his-word \"<what he said>\"]"
  local board="${1:?$usage}" nn="${2:?$usage}" word=""; shift 2
  [[ "${1:-}" == --his-word ]] && word="${2:?$usage}"
  loop_init "$board"; forge_need
  derive_all
  local s state pr id review bad pending
  s="$(state_of "$(jq -r .nn <<<"$(ticket_json "$nn")")")"; state="$(jq -r .state <<<"$s")"; pr="$(jq -c .pr <<<"$s")"
  [[ "$pr" != null ]] || die "ticket $nn has no open PR ($(jq -r .why <<<"$s"))"
  id="$(jq -r .number <<<"$pr")"; review="$(jq -r '.review // ""' <<<"$pr")"
  [[ "$review" != CHANGES_REQUESTED ]] || die "NOT MERGED — changes are requested on #$id"
  if [[ "$review" != APPROVED ]]; then
    [[ -n "$word" ]] || die "NOT MERGED — #$id has no approval on $(forge_name). Ask him to approve it there, or, where the forge can't take his approval (he opened it), pass his words with --his-word"
    log "#$id: merging on his word, not a forge approval: $word"
  fi
  [[ "$(jq -r .mergeable <<<"$pr")" != CONFLICTING ]] || die "NOT MERGED — #$id conflicts with $BASE_BRANCH: resume the ticket's session to merge $BASE_BRANCH into its branch, then loop.sh pr again"
  bad="$(jq -r '[.checks[] | select(.s == "bad") | .n] | join(", ")' <<<"$pr")"
  pending="$(jq -r '[.checks[] | select(.s == "pending") | .n] | join(", ")' <<<"$pr")"
  [[ -z "$bad" ]] || die "NOT MERGED — red checks on #$id: $bad"
  [[ -z "$pending" ]] || die "NOT MERGED — checks still running on #$id: $pending"
  if [[ "$(jq -r .isDraft <<<"$pr")" == true ]]; then
    case "$FORGE" in
      github) gh_ pr ready "$id" >&2 ;;
      azure)  az_ repos pr update --id "$id" --draft false >/dev/null ;;
    esac
    log "#$id marked ready for review"
  fi
  local method; method="$(forge_merge "$id")"
  echo "MERGED $nn #$id ($method)${word:+ — on his word: $word}"
}

cmd_done() {
  local usage="usage: loop.sh done <board> <NN> \"<what was done>\""
  local board="${1:?$usage}" nn="${2:?$usage}" what="${3:?$usage}"
  loop_init "$board"
  local t file; t="$(ticket_json "$nn")"; file="$(jq -r .file <<<"$t")"
  [[ "$(jq -r .owner <<<"$t")" == me ]] || die "ticket $nn is an agent's: it is done when its PR merges"
  [[ "$(jq -r .status <<<"$t")" != resolved ]] || { echo "ALREADY resolved"; return 0; }
  local at; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if grep -q '^\*\*Status:\*\*' "$file"; then
    sed -i -E "s|^\*\*Status:\*\*.*|**Status:** resolved ($at, no code: ${what//|/\\|})|" "$file"
  else
    awk -v line="**Status:** resolved ($at, no code: $what)" '{ print } /^# [0-9]+:/ && !done { print ""; print line; done = 1 }' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  fi
  echo "RESOLVED $(jq -r .nn <<<"$t") — $what"
}

# -C <repo>: run as if from that checkout, so one allowed command shape
# (`loop.sh -C <repo> …`) serves every repo of a project.
if [[ "${1:-}" == -C ]]; then
  cd "${2:?usage: loop.sh -C <repo> <verb> ...}" || die "no such checkout: $2"; shift 2
fi
# ---- watch: news for the project coordinator ----------------------------------------

# loop.sh watch <board> --inbox <dir>: derive every ticket, compare with what the
# last pass saw, and drop one JSON event per change the coordinator acts on into
# <dir>/inbox/ (coordinator-inbox.sh announces them). seen.json is a notification
# cursor, not ticket state: delete it and the next pass only records again.
#
# A pass whose runner or forge lookup failed records nothing and sends nothing,
# since a failed lookup reads as "no session" or "no PR". idle and stopped must
# hold for two passes in a row before they are news (a subagent's quiet spell, a
# reboot the boot unit is already resuming). The first pass on a board records only.
# Threads talk through the coordinator: each ticket's session appends
# {to, text} to its messages.json (the brief's "The other threads"); a watch
# pass delivers the new ones (`devbox-run say` into the target's session, as
# "From thread NN (<title>): …") and hands every one to the coordinator as a
# `message` event. seen.json counts what each file had, so a message goes once;
# a file shorter than the count (a fresh start) counts from zero. The first pass
# only counts. Prints <out> with the message events and counts added.
deliver_messages() {
  local seen="$1" out="$2" row nn title mf len prev i m to text tgt sess alive why line rc
  while IFS= read -r row; do
    nn="$(jq -r .nn <<<"$row")"; title="$(jq -r .title <<<"$row")"
    mf="$(ticket_dir "$nn")/messages.json"; len=0
    [[ -s "$mf" ]] && len="$(jq 'if type == "array" then length else 0 end' "$mf" 2>/dev/null || echo 0)"
    prev="$(jq -r --arg n "$nn" '.tickets[$n].msgs // 0' <<<"$seen" 2>/dev/null || echo 0)"
    [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
    (( len < prev )) && prev=0
    if [[ "$seen" != null ]]; then
      for (( i = prev; i < len; i++ )); do
        m="$(jq -c --argjson i "$i" '.[$i]' "$mf")"
        to="$(jq -r '.to // "" | tostring' <<<"$m")"; text="$(jq -r '.text // "" | tostring' <<<"$m")"
        [[ -n "$text" ]] || continue
        why="for the coordinator"
        if [[ "$to" != coordinator ]]; then
          tgt="$(state_of "$to")"
          if [[ -z "$tgt" ]]; then why="not delivered: no ticket $to on this board"
          else
            sess="$(jq -r .session <<<"$tgt")"; alive="$(jq -r .alive <<<"$tgt")"
            if [[ "$alive" != true ]]; then why="not delivered: $to has no live session ($(jq -r .state <<<"$tgt")) — deliver it when it starts, or answer it yourself"
            else
              line="From thread $nn ($title): $text"
              rc=0; printf '%s' "$line" | "$RUNNER" say "$sess" - >/dev/null 2>&1 || rc=$?
              case "$rc" in
                0) why="delivered to $to" ;;
                5) why="not delivered: $to's screen shows a dialog — loop.sh say it once that is answered" ;;
                *) why="not delivered: devbox-run say failed (exit $rc)" ;;
              esac
            fi
          fi
        fi
        out="$(jq -c --arg nn "$nn" --arg title "$title" --arg to "$to" --arg text "$text" --arg why "$why" \
          --arg board "$BOARD_ID" --arg repo "$REPO_NAME" \
          '.events += [{kind: "message", text: "\($nn) → \($to) (\($why)): \($text)", board: $board, repo: $repo,
                        nn: $nn, title: $title, to: $to, delivered: ($why | startswith("delivered"))}]' <<<"$out")"
      done
    fi
    out="$(jq -c --arg nn "$nn" --argjson len "$len" '.seen.tickets[$nn].msgs = $len' <<<"$out")"
  done < <(jq -c '.[]' <<<"$STATES")
  printf '%s\n' "$out"
}

cmd_watch() {
  local usage="usage: loop.sh watch <board> --inbox <dir>"
  local board="${1:?$usage}" inbox=""; shift
  [[ "${1:-}" == --inbox ]] && inbox="${2:?$usage}"
  [[ -n "$inbox" && -d "$inbox" ]] || die "$usage (an existing inbox directory)"
  loop_init "$board"
  local sd; sd="$(board_state_dir)/loop/$BOARD_SLUG"; mkdir -p "$sd"
  exec 9>"$sd/watch.lock"
  flock -n 9 || { echo "BUSY another watch of $BOARD_ID is running"; return 0; }
  derive_all 2>/dev/null
  if (( RUNNER_FAILED || FORGE_FAILED )); then
    echo "SKIPPED $BOARD_ID — the $( (( RUNNER_FAILED )) && echo runner || echo forge ) lookup failed; nothing recorded"
    return 3
  fi
  local seen='null'
  [[ -s "$sd/seen.json" ]] && seen="$(jq -c . "$sd/seen.json" 2>/dev/null || echo null)"
  local now; now="$(jq -c '[.[] | {nn, state, why, title, report, reported, questions, open_questions, pr: (.pr.url // null)}]' <<<"$STATES")"
  # Each report's mtime: a new report under an open PR is a fix round finished.
  local rows="" row rf mt
  while IFS= read -r row; do
    rf="$(jq -r .report <<<"$row")"; mt=0
    [[ "$(jq -r .reported <<<"$row")" == true && -f "$rf" ]] && mt="$(stat -c %Y "$rf" 2>/dev/null || echo 0)"
    rows+="$(jq -c --argjson mt "$mt" '. + {report_at: $mt}' <<<"$row")"$'\n'
  done < <(jq -c '.[]' <<<"$now")
  now="$(jq -s . <<<"$rows")"
  local out
  out="$(jq -n --argjson seen "$seen" --argjson now "$now" --arg board "$BOARD_ID" --arg repo "$REPO_NAME" '
    def confirm: IN("idle", "stopped");
    def kind($from; $to):
      if $to == "ready" and ($from == "blocked" or $from == null) then "start"
      elif $to == "built" then "built"
      elif $to == "idle" then "idle"
      elif $to == "stopped" and ($from | IN("working", "idle", "asking", "built")) then "resume"
      elif $to == "changes" then "changes"
      elif $to == "approved" then "approved"
      elif $to == "done" and $from != "dropped" and $from != null then "landed"
      else null end;
    ($seen == null) as $first
    | reduce $now[] as $t ({seen: {}, events: []};
        ($seen.tickets[$t.nn] // null) as $old
        | ($old.state // null) as $from
        # idle/stopped: news only on the second pass in a row.
        | (($t.state | confirm) and $t.state != $from and ($old.pending // null) != $t.state) as $hold
        | .seen[$t.nn] = (if $hold then ($old // {}) + {pending: $t.state}
                          else {state: $t.state, report_at: $t.report_at, open_questions: $t.open_questions, pending: null} end)
        | if $first or $hold then . else
            (if $t.state != $from then kind($from; $t.state) else null end) as $k
            | ([if $k then {kind: $k, text: $t.why} else empty end]
               + [if $old != null and $t.open_questions > ($old.open_questions // 0)
                  then {kind: "question", text: "\($t.open_questions) blocking question(s) in \($t.questions)"} else empty end]
               + [if ($t.state | IN("changes", "review", "built")) and $t.state == $from
                     and ($old.report_at // 0) > 0 and $t.report_at > $old.report_at
                  then {kind: (if $t.state == "built" then "built" else "fixed" end),
                        text: "a new report: \($t.report)\(if $t.state == "built" then "" else " — read it; loop.sh pr pushes the fix to the open PR" end)"}
                  else empty end]) as $evs
            | .events += [$evs[] | . + {board: $board, repo: $repo, nn: $t.nn, title: $t.title, state: $t.state, from: $from, pr: $t.pr}]
          end)
    | {seen: {tickets: .seen}, events: .events}')" || die "watch: could not compare states"
  out="$(deliver_messages "$seen" "$out")"
  local at n=0 ev f
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  while IFS= read -r ev; do
    [[ -n "$ev" ]] || continue
    f="$inbox/$(date -u +%Y%m%dT%H%M%S)-${BOARD_SLUG}-$(jq -r .nn <<<"$ev")-$(jq -r .kind <<<"$ev")-$n.json"
    jq --arg at "$at" '{at: $at} + .' <<<"$ev" >"$f.tmp" && mv "$f.tmp" "$f"
    n=$((n + 1))
  done < <(jq -c '.events[]' <<<"$out")
  jq '.seen' <<<"$out" >"$sd/seen.json.tmp" && mv "$sd/seen.json.tmp" "$sd/seen.json"
  if [[ "$seen" == null ]]; then echo "RECORDED $BOARD_ID — first pass, $(jq length <<<"$now") ticket(s), no events"
  else echo "WATCHED $BOARD_ID — $n event(s)"; fi
}

verb="${1:-}"; shift || true
case "$verb" in
  adopt|status|start|resume|say|log|report|answer|pr|merge|done|watch) "cmd_$verb" "$@" ;;
  *) sed -n '2,52p' "$0"; exit 1 ;;
esac
