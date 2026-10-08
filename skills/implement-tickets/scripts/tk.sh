#!/usr/bin/env bash
# tk.sh — the board session's hands. Every check that has a guard is here, as
# code, so the model driving the board (Haiku, by default) only reads results
# and decides. See docs/adr/0004-haiku-board-session.md.
#
# Usage (<board> is a Jira id or slug under .scratch/, a path, or "" for the only one there):
#   tk.sh digest  <board> [--full]       board, agents and git in one read; prints only what changed
#   tk.sh launch  <board> <NN> --type <feat|fix|...> --model <m> --effort <e> [--account <a>] [--research <file>]
#   tk.sh gates   <board> <NN>           the five merge gates, one line each
#   tk.sh ready   <board>                every in-progress ticket whose PR passes all gates
#   tk.sh merge   <board> <NN>           gates, then merge with the repo's method, then resolve
#   tk.sh resolve <board> <NN>           mark a landed ticket resolved in its home
#   tk.sh say     <board> <NN> <file>    relay a message to the ticket's agent, verbatim
#   tk.sh show    <board> <NN> [lines]   the agent's recent output (on request only)
#   tk.sh view    <board> [--watch [secs]]  the status board for the developer — no model involved;
#                                        --watch is full-screen: q quits, r refreshes (TICKET_VIEW_THEME)
#   tk.sh helpers <board> <NN>...        each ticket's Suggested helpers line (for a wave's shared research)
#   tk.sh retro   <board>                everything ticket-retro reads: reports, transcript extracts, files, skills
#
# Exit codes: 0 ok | 1 error | 3 launched but stopped at a dialog (run the printed command)
#   gates/merge: 10 conflicting (send ticket-merger) | 11 checks pending | 12 another gate failed
#   say: 20 agent at a dialog | 21 no live agent
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

LAUNCHER="${TICKET_LAUNCHER:-$(dirname "$SKILL_DIR")/ticket/scripts/launch.sh}"

# ---- digest -----------------------------------------------------------------
cmd_digest() {
  board_init "${1:-}"; shift || true
  local full=0; [[ "${1:-}" == --full ]] && full=1
  if (( HAS_REMOTE )); then
    run_git_net fetch "$REMOTE" "$BASE_BRANCH" --quiet 2>/dev/null || echo "WARN fetch of $REMOTE/$BASE_BRANCH failed — landed answers use the last fetch"
  fi
  local agents facts="" t nn status branch base agent st tab l
  local herdr_ok=1
  agents="$(agent_states)" || { herdr_ok=0; echo "WARN Herdr didn't answer — agent states unknown"; }
  while IFS= read -r t; do
    nn="$(jq -r .nn <<<"$t")"; status="$(jq -r .status <<<"$t")"
    branch="$(jq -r .branch <<<"$t")"; base="$(jq -r .base <<<"$t")"; agent="$(jq -r .agent <<<"$t")"
    l="-"; st="-"; tab="-"
    if [[ "$status" == in-progress ]]; then
      l="$(landed "$branch" "$base")"
      if [[ -n "$agent" ]]; then
        st="gone"
        IFS=$'\t' read -r _ st tab < <(awk -F'\t' -v a="$agent" '$1 == a' <<<"$agents") || true
        [[ -n "$st" ]] || st="gone"
        (( herdr_ok )) || st="?"
      fi
    fi
    facts+="$(jq -cn --arg nn "$nn" --arg l "$l" --arg s "$st" --arg tab "${tab:--}" '{nn:$nn, landed:$l, state:$s, tab:$tab}')"$'\n'
  done < <(jq -c '.[]' <<<"$BOARD_JSON")

  local state_file prev="{}"
  state_file="$(board_state_dir)/$BOARD_SLUG.digest.json"
  [[ -f "$state_file" ]] && prev="$(cat "$state_file")"
  local out
  out="$(jq -n --argjson board "$BOARD_JSON" --argjson prev "$prev" --argjson full "$full" \
           --slurpfile facts <(printf '%s' "$facts") \
           --arg id "$BOARD_ID" --arg base "$BASE_REF" '
    ($facts | map({key: .nn, value: .}) | from_entries) as $f |
    ($board | map({key: .nn, value: .status}) | from_entries) as $st |
    def dash: if . == null or . == "" then "-" else . end;
    [ $board[] | . as $t | $f[$t.nn] as $x |
      ($t.blockers | map(select($st[.] != "resolved"))) as $open |
      $t + {landed: $x.landed, state: $x.state, tab: $x.tab, open_blockers: $open,
            line: ([ $t.nn, $t.status, $t.ref,
                     ($t.branch | dash),
                     (if $t.agent != "" then "agent:\($x.state)" else "-" end),
                     "landed:\($x.landed)",
                     "blockers:\($open | join(",") | dash)",
                     "run:\($t.model | dash)/\($t.effort | dash)",
                     "suggests:\($t.smodel | dash)/\($t.seffort | dash)" ] | join(" ")) } ] as $rows |
    ($rows | map({key: .nn, value: .line}) | from_entries) as $now |
    ($prev.lines // {}) as $was |
    [ $rows[] | select($was[.nn] != .line) | .nn ] as $changed |
    { lines: $now,
      text: ([ "BOARD \($id) base \($base)" +
                 (([$board[].parent | select(. != "")] | unique) as $p |
                  if ($p | length) > 0 then " parent \($p | join(","))" else "" end) ]
             + [ $rows[] | select($full == 1 or ($prev.lines == null) or ($was[.nn] != .line)) | .line ]
             + [ "FRONTIER " + ([ $rows[] | select(.status == "open" and (.open_blockers | length) == 0) | .nn ] | join(" ") | dash) ]
             + [ $rows[] | select(.status == "in-progress") |
                 if (.landed | startswith("yes")) then "ACTION resolve \(.nn) — landed (\(.landed | ltrimstr("yes:")))"
                 elif (.landed | startswith("unknown")) then "ACTION check \(.nn) — landed unknown (\(.landed | ltrimstr("unknown:"))); leave it, tell the developer"
                 elif .state == "blocked" then "ACTION dialog \(.nn) — agent waiting at a dialog in tab \(.tab); the developer answers it"
                 elif .state == "gone" then "ACTION orphan \(.nn) — no live agent and not landed; tell the developer"
                 elif ((.state == "idle" or .state == "done") and ($was[.nn] != .line)) then "ACTION review \(.nn) — agent finished; ready for the developer (or: open PR)"
                 else empty end ]
             + [ $rows[] | select((.unknown_refs // []) | length > 0) | "WARN \(.nn) blocked-by names nothing on the board: \(.unknown_refs | join(","))" ]
             + [ "CHANGED " + (if $prev.lines == null then "all (first digest)" else ($changed | join(" ") | dash) end) ]
            ) | join("\n") }')"
  jq -r .text <<<"$out"
  jq '{lines}' <<<"$out" >"$state_file"
  # The line format /sweep-tickets cross-checks against (sweep.sh load_board):
  # <NN> <status> <ref> <branch> <agent-state> <landed> <open-blockers>.
  jq -nr --argjson board "$BOARD_JSON" --slurpfile facts <(printf '%s' "$facts") '
    ($facts | map({key: .nn, value: .}) | from_entries) as $f |
    $board[] | . as $t | $f[$t.nn] as $x |
    if $t.status == "resolved" then "\($t.nn) resolved \($t.ref | split("/") | last) - - - -"
    else [ $t.nn, $t.status, ($t.ref | split("/") | last), ($t.branch | if . == "" then "-" else . end),
           $x.state, ($x.landed | if startswith("yes") then "yes" else . end),
           ($t.blockers | join(",") | if . == "" then "-" else . end) ] | join(" ") end' \
    >"/tmp/implement-tickets-digest-${REPO_NAME}-${BOARD_SLUG}.txt" 2>/dev/null || true
}

# ---- launch -------------------------------------------------------------------
slugify() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }

# Writes the run-state block into the ticket's home.
record_run_state() {
  local t="$1" block="$2" f tmp
  f="$(jq -r .file <<<"$t")"; tmp="$(mktemp)"
  # Old run-state lines go wherever they were; the new block goes under the
  # heading. Blank lines are squeezed only above the body, never inside it.
  awk -v block="$block" '
    /^\*\*(Status|Branch|Base|Model|Effort|Account|Worktree|Agent):\*\*/ { next }
    /^\*\*What to build:\*\*/ { body = 1 }
    !body && /^[[:space:]]*$/ && blank { next }
    { blank = /^[[:space:]]*$/; print }
    /^# [0-9]+:/ && !done { print ""; print block; blank = 0; done = 1 }
    END { exit !done }' "$f" >"$tmp" || { rm -f "$tmp"; die "couldn't record run state in $f — no '# NN:' heading"; }
  mv "$tmp" "$f"
}

cmd_launch() {
  board_init "${1:-}"; shift
  local nn="${1:?usage: tk.sh launch <board> <NN> --type <t> --model <m> --effort <e> [--account <a>] [--research <file>]}"; shift
  local type="" model="" effort="" account="" research=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) type="$2"; shift 2 ;; --model) model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;; --account) account="$2"; shift 2 ;;
      --research) research="$2"; shift 2 ;; *) die "unknown argument: $1" ;;
    esac
  done
  [[ "$type" =~ ^(feat|fix|refactor|chore|docs|test|perf|ci)$ ]] || die "--type must be one of feat fix refactor chore docs test perf ci"
  [[ -n "$model" && -n "$effort" ]] || die "--model and --effort are required (the session's settings, or this ticket's suggestion)"
  local t status open
  t="$(ticket_json "$nn")"
  status="$(jq -r .status <<<"$t")"
  [[ "$status" == open ]] || die "ticket $nn is $status, not open"
  open="$(jq -r --argjson b "$BOARD_JSON" '[.blockers[] as $x | $b[] | select(.nn == $x and .status != "resolved") | .nn] | join(",")' <<<"$t")"
  [[ -z "$open" ]] || die "ticket $nn is blocked by $open — not on the frontier"
  # Run state is written under the `# NN: Title` heading; a file without one
  # would launch and then stay `open` on the board, and launch again.
  grep -qE '^# [0-9]+:' "$(jq -r .file <<<"$t")" || die "ticket $nn has no '# $nn: <Title>' heading — add one, then launch"

  # Names, mechanically: the same shape /ticket documents.
  local title slug branch label nn2
  title="$(jq -r .title <<<"$t")"; nn2="$(jq -r .nn <<<"$t")"
  slug="$(slugify "$title" | cut -d- -f1-4)"
  branch="$type-$nn2-$slug"; branch="${branch:0:40}"; branch="${branch%-}"; branch="${branch//--/-}"
  label="$(slugify "$title" | cut -d- -f1-3 | tr '-' ' ')"; label="${label:0:20}"; label="${label% }"
  [[ -n "$label" ]] || label="ticket $nn2"

  # The brief: the ticket file as written, then the wave's research.
  local brief; brief="$(mktemp -t ticket.XXXXXX.md)"
  cat "$(jq -r .file <<<"$t")" >"$brief"
  if [[ -n "$research" ]]; then
    [[ -s "$research" ]] || die "research file is empty or missing: $research"
    { echo; echo "## Research for this wave"; echo
      echo "Already answered for every ticket in this wave — don't send a researcher after these again."; echo
      cat "$research"; } >>"$brief"
  fi

  local args=() out rc
  [[ -n "$account" ]] && args+=(--account "$account")
  args+=(--effort "$effort" "$label" "$branch" "$brief" "$model")
  out="$(mktemp)"
  set +e; "$LAUNCHER" "${args[@]}" >"$out" 2>&1; rc=$?; set -e
  cat "$out"
  if [[ $rc -eq 0 || $rc -eq 3 ]]; then
    local wt agent base
    wt="$(sed -n 's/^WORKTREE=//p' "$out")"; agent="$(sed -n 's/^AGENT=\([^ ]*\).*/\1/p' "$out")"
    base="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "?")"
    record_run_state "$t" "$(printf '**Status:** in-progress\n**Branch:** %s\n**Base:** %s\n**Model:** %s\n**Effort:** %s\n**Account:** %s\n**Worktree:** %s\n**Agent:** %s' \
      "$branch" "$base" "$(sed -n 's/^MODEL=//p' "$out")" "$(sed -n 's/^EFFORT=//p' "$out")" \
      "$(sed -n 's/^ACCOUNT=\([^ ]*\).*/\1/p' "$out")" "$wt" "$agent")"
    echo "RECORDED $nn2 in-progress on $branch"
  fi
  rm -f "$out" "$brief"
  return $rc
}

# ---- gates and merge ---------------------------------------------------------------
# Sets PR_NUMBER. Prints one GATE line per gate; returns 0 / 10 / 11 / 12.
run_gates() {
  local t="$1" branch pr json fail=0 conflicting=0 pending=0
  branch="$(jq -r .branch <<<"$t")"
  PR_NUMBER=""
  [[ -n "$branch" ]] || { echo "GATE pr FAIL ticket has no branch recorded"; return 12; }
  pr="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty')"
  [[ -n "$pr" ]] || { echo "GATE pr FAIL no open PR on $branch — not pushed, or no PR opened yet"; return 12; }
  PR_NUMBER="$pr"; echo "GATE pr PASS #$pr"
  json="$(gh pr view "$pr" --json isDraft,baseRefName,mergeable,reviewDecision,statusCheckRollup)"
  if [[ "$(jq -r .mergeable <<<"$json")" == UNKNOWN ]]; then
    sleep 3; json="$(gh pr view "$pr" --json isDraft,baseRefName,mergeable,reviewDecision,statusCheckRollup)"
  fi
  if [[ "$(jq -r .isDraft <<<"$json")" == true ]]; then echo "GATE ready FAIL draft"; fail=1
  elif [[ "$(jq -r .baseRefName <<<"$json")" != "$BASE_BRANCH" ]]; then echo "GATE ready FAIL base is $(jq -r .baseRefName <<<"$json"), not $BASE_BRANCH"; fail=1
  else echo "GATE ready PASS"; fi
  case "$(jq -r .mergeable <<<"$json")" in
    MERGEABLE)   echo "GATE mergeable PASS" ;;
    CONFLICTING) echo "GATE mergeable FAIL conflicts with $BASE_BRANCH — send ticket-merger"; conflicting=1 ;;
    *)           echo "GATE mergeable FAIL GitHub hasn't computed it yet — ask again in a minute"; fail=1 ;;
  esac
  local checks
  checks="$(jq -r '[.statusCheckRollup[]? |
      if .__typename == "StatusContext" then {n: .context, s: (if .state == "SUCCESS" then "ok" elif (.state == "PENDING" or .state == "EXPECTED") then "pending" else "bad" end)}
      else {n: .name, s: (if .status != "COMPLETED" then "pending"
                          elif (.conclusion == "SUCCESS" or .conclusion == "SKIPPED" or .conclusion == "NEUTRAL") then "ok" else "bad" end)} end]' <<<"$json")"
  if [[ "$(jq '[.[] | select(.s == "bad")] | length' <<<"$checks")" -gt 0 ]]; then
    echo "GATE checks FAIL failed: $(jq -r '[.[] | select(.s == "bad") | .n] | join(", ")' <<<"$checks")"; fail=1
  elif [[ "$(jq '[.[] | select(.s == "pending")] | length' <<<"$checks")" -gt 0 ]]; then
    echo "GATE checks FAIL still running: $(jq -r '[.[] | select(.s == "pending") | .n] | join(", ")' <<<"$checks")"; pending=1
  else echo "GATE checks PASS ($(jq length <<<"$checks") checks)"; fi
  case "$(jq -r '.reviewDecision // ""' <<<"$json")" in
    APPROVED|"") echo "GATE review PASS" ;;
    *) echo "GATE review FAIL $(jq -r .reviewDecision <<<"$json")"; fail=1 ;;
  esac
  (( fail )) && return 12; (( pending )) && return 11; (( conflicting )) && return 10; return 0
}

# PRs need a remote. Without one there is nothing to gate: the developer merges
# the branch locally and the next digest sees it by ancestry.
need_pr_remote() {
  (( HAS_REMOTE )) || die "no '$REMOTE' remote in $ROOT — no PRs here; merge the branch locally and the next digest resolves it"
  need gh
}

cmd_gates() {
  board_init "${1:-}"; local t; t="$(ticket_json "${2:?usage: tk.sh gates <board> <NN>}")"
  need_pr_remote; run_gates "$t"
}

cmd_ready() {
  board_init "${1:-}"; need_pr_remote
  local t nn any=0
  while IFS= read -r t; do
    nn="$(jq -r .nn <<<"$t")"
    if run_gates "$t" >/dev/null 2>&1; then echo "READY $nn #$PR_NUMBER"; any=1; fi
  done < <(jq -c '.[] | select(.status == "in-progress")' <<<"$BOARD_JSON")
  (( any )) || echo "READY none"
}

cmd_merge() {
  board_init "${1:-}"; need_pr_remote
  local nn="${2:?usage: tk.sh merge <board> <NN>}" t rc method
  t="$(ticket_json "$nn")"
  set +e; run_gates "$t"; rc=$?; set -e
  [[ $rc -eq 0 ]] || { echo "NOT MERGED — a gate failed"; return $rc; }
  method="$(gh repo view --json viewerDefaultMergeMethod --jq .viewerDefaultMergeMethod | tr '[:upper:]' '[:lower:]')"
  [[ "$method" =~ ^(merge|squash|rebase)$ ]] || method=squash
  # Never --admin (it would skip the gates GitHub enforces), never --delete-branch
  # (the branch is still checked out in the ticket's worktree; /sweep-tickets owns it).
  gh pr merge "$PR_NUMBER" "--$method"
  echo "MERGED $nn #$PR_NUMBER ($method)"
  resolve_ticket "$t"
}

# ---- resolve ----------------------------------------------------------------------
resolve_ticket() {
  local t="$1" nn branch l sha line
  nn="$(jq -r .nn <<<"$t")"; branch="$(jq -r .branch <<<"$t")"
  (( HAS_REMOTE )) && { run_git_net fetch "$REMOTE" "$BASE_BRANCH" --quiet 2>/dev/null || true; }
  l="$(landed "$branch" "$(jq -r .base <<<"$t")")"
  [[ "$l" == yes:* ]] || die "ticket $nn hasn't landed ($l) — not resolving it"
  if [[ "$l" == yes:pr#* ]]; then
    sha="$(gh pr view "${l#yes:pr#}" --json mergeCommit --jq '.mergeCommit.oid // ""' | cut -c1-7)"
  else
    sha="$(git -C "$ROOT" rev-parse --short "$branch")"
  fi
  line="**Status:** resolved — merged into $BASE_BRANCH as ${sha:-?} on $(date +%F)"
  local f tmp; f="$(jq -r .file <<<"$t")"; tmp="$(mktemp)"
  awk -v line="$line" '/^\*\*Status:\*\*/ { print line; next } /^\*\*Agent:\*\*/ { next } { print }' "$f" >"$tmp"
  mv "$tmp" "$f"
  echo "RESOLVED $nn ($l) — /sweep-tickets lists its worktree and branch for cleanup"
}

cmd_resolve() {
  board_init "${1:-}"; resolve_ticket "$(ticket_json "${2:?usage: tk.sh resolve <board> <NN>}")"
}

# ---- talking to a ticket ------------------------------------------------------------
agent_of() {
  local t="$1" agent st
  agent="$(jq -r .agent <<<"$t")"
  [[ -n "$agent" ]] || die "ticket $(jq -r .nn <<<"$t") has no agent recorded"
  st="$( (agent_states || true) | awk -F'\t' -v a="$agent" '$1 == a {print $2}')"
  AGENT="$agent"; AGENT_STATE="${st:-gone}"
}

cmd_say() {
  board_init "${1:-}"; need herdr
  local t file="${3:?usage: tk.sh say <board> <NN> <message-file>}"
  t="$(ticket_json "$2")"; [[ -s "$file" ]] || die "message file is empty: $file"
  agent_of "$t"
  case "$AGENT_STATE" in
    idle|done|working) ;;
    gone) echo "NOT SENT — $AGENT isn't running"; return 21 ;;
    *)    echo "NOT SENT — $AGENT is '$AGENT_STATE'; a message typed at a dialog could answer it"; return 20 ;;
  esac
  herdr agent prompt "$AGENT" "$(printf 'Message from the developer, via the board session:\n\n%s' "$(cat "$file")")" >/dev/null
  [[ "$AGENT_STATE" == working ]] && echo "SENT to $AGENT — it's working; Claude Code queues the message until its current step ends" \
                                  || echo "SENT to $AGENT ($AGENT_STATE)"
}

cmd_show() {
  board_init "${1:-}"; need herdr
  local t; t="$(ticket_json "${2:?usage: tk.sh show <board> <NN> [lines]}")"
  agent_of "$t"
  [[ "$AGENT_STATE" != gone ]] || { echo "$AGENT isn't running"; return 21; }
  herdr agent read "$AGENT" --source recent-unwrapped --lines "${3:-60}"
}

# ---- the board, for the developer's eyes -----------------------------------------
# A status board in the terminal — no model, no tokens. Columns:
#   backlog       open, nothing blocking it: ready to launch
#   blocked       open, waiting on unresolved tickets
#   working       its agent is scouting or implementing
#   agent review  its agent is verifying, reviewing or fixing review findings
#   needs you     at a dialog, no live agent, or its landing can't be told
#   human review  the agent finished; the developer reviews (or asks for a PR)
#   pr            a PR is open — checks running/failed, conflict, changes requested, ready to merge
#   done          resolved
# The phase comes from the file each ticket's coordinator writes as it moves
# through its brief ({{PHASE_FILE}}); Herdr alone can't tell implementing from
# reviewing, since the agent is "working" either way.
board_rows() {
  local t nn status branch agent agents herdr_ok=1 st l phase round checks tab pr phase_dir rows=""
  phase_dir="$(board_state_dir)/phase"
  agents="$(agent_states)" || herdr_ok=0
  while IFS= read -r t; do
    nn="$(jq -r .nn <<<"$t")"; status="$(jq -r .status <<<"$t")"
    branch="$(jq -r .branch <<<"$t")"; agent="$(jq -r .agent <<<"$t")"
    st="-"; l="-"; phase="-"; round=""; checks=""; tab="-"; pr="null"
    if [[ "$status" == in-progress ]]; then
      l="$(landed "$branch" "$(jq -r .base <<<"$t")")"
      if [[ -n "$agent" ]]; then
        if (( herdr_ok )); then
          st="$(awk -F'\t' -v a="$agent" '$1 == a {print $2}' <<<"$agents")"; st="${st:-gone}"
          tab="$(awk -F'\t' -v a="$agent" '$1 == a {print $3}' <<<"$agents")"; tab="${tab:--}"
        else st="?"; fi
      fi
      if [[ -s "$phase_dir/$branch" ]]; then
        # Line 1 "<phase> [rN]", line 2 "tests=… criteria=m/n review=…" — both written by
        # the ticket's coordinator; anything unexpected is dropped, not trusted.
        read -r phase round < <(head -1 "$phase_dir/$branch" | tr -cd 'a-z0-9 -'; echo)
        [[ "$round" =~ ^r[0-9]+$ ]] || round=""
        checks="$(sed -n 2p "$phase_dir/$branch" | tr -cd 'a-z0-9=/ -')"
        phase="${phase:--}"
      fi
      if (( HAS_REMOTE )) && command -v gh >/dev/null 2>&1 && [[ -n "$branch" ]]; then
        pr="$(gh pr list --head "$branch" --state open --json number,isDraft,mergeable,reviewDecision,statusCheckRollup --jq '.[0] // null' 2>/dev/null || echo null)"
        [[ -n "$pr" ]] || pr="null"
      fi
    fi
    rows+="$(jq -cn --argjson t "$t" --arg st "$st" --arg l "$l" --arg ph "$phase" --arg rd "$round" --arg ck "$checks" --arg tab "$tab" --argjson pr "$pr" \
      '$t + {state:$st, landed:$l, phase:$ph, round:$rd, tab:$tab, pr:$pr,
             checks: ($ck | split(" ") | map(select(test("^[a-z]+=")) | split("=") | {key: .[0], value: .[1]}) | from_entries)}')"$'\n'
  done < <(jq -c '.[]' <<<"$BOARD_JSON")
  printf '%s' "$rows" | jq -s '
    (map({key: .nn, value: .status}) | from_entries) as $st |
    map(. as $t | ($t.blockers | map(select($st[.] != "resolved"))) as $open |
      $t + {open_blockers: $open} +
      (if $t.status == "resolved" then {col: "done", note: ""}
       elif $t.status == "open" then
         (if ($open | length) > 0 then {col: "blocked", note: "waiting on \($open | join(", "))"}
          else {col: "backlog", note: "ready to launch"} end)
       elif ($t.landed | startswith("yes")) then {col: "done", note: "landed — resolve it"}
       elif $t.pr != null then
         ($t.pr | [.statusCheckRollup[]? | if .__typename == "StatusContext" then .state
                   elif .status != "COMPLETED" then "PENDING" else .conclusion end] as $c |
          {col: "pr", note: ("#\(.number) " +
            (if .isDraft then "draft"
             elif .mergeable == "CONFLICTING" then "conflict"
             elif .reviewDecision == "CHANGES_REQUESTED" then "changes requested"
             elif ($c | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED")) then "checks failed"
             elif ($c | any(. == "PENDING" or . == "EXPECTED" or . == "QUEUED" or . == "IN_PROGRESS")) then "checks running"
             elif .reviewDecision == "REVIEW_REQUIRED" then "awaiting review"
             else "ready to merge" end))})
       elif ($t.landed | startswith("unknown")) then {col: "needs", note: "landed? \($t.landed | ltrimstr("unknown:"))"}
       elif $t.state == "blocked" then {col: "needs", note: "agent at a dialog"}
       elif $t.state == "gone" then {col: "needs", note: "no live agent"}
       elif ($t.state == "idle" or $t.state == "done") then {col: "human", note: "agent finished"}
       elif ($t.phase | IN("verifying", "reviewing", "fixing", "reporting")) then {col: "review", note: $t.phase}
       else {col: "working", note: (if $t.phase != "-" then $t.phase else $t.state end)} end))
    # What to type into the board session to move the card on, where there is something.
    | map(. + {hint: (
        if .col == "backlog" then "start \(.nn)"
        elif .col == "human" then "open a PR for \(.nn)"
        elif .col == "pr" and (.note | test("ready to merge")) then "merge \(.nn)"
        elif .col == "pr" and (.note | test("conflict")) then "merge \(.nn) — sends the merger"
        elif .col == "needs" and .state == "blocked" then (if .tab != "-" then "answer it in tab \(.tab)" else "answer its dialog" end)
        elif .col == "needs" and .state == "gone" then "show \(.nn)"
        elif .col == "done" and (.note | test("resolve")) then "resolve \(.nn)"
        else "" end)})'
}

cmd_view() {
  board_init "${1:-}"; shift || true
  local watch=0 every=30
  [[ "${1:-}" == --watch ]] && { watch=1; every="${2:-30}"; [[ "$every" =~ ^[1-9][0-9]*$ ]] || every=30; }
  # What a ticket that suggests nothing would launch on, for its card: the
  # launcher's own defaults, read from the same ticket-models.env.
  local dm de
  read -r dm de < <(conf="${TICKET_MODELS_CONF:-$(dirname "$SKILL_DIR")/ticket-models.env}"
    # shellcheck source=/dev/null
    [[ -f "$conf" ]] && source "$conf" 2>/dev/null
    echo "${TICKET_IMPL_MODEL:-opus} ${TICKET_IMPL_EFFORT:-medium}")
  # The colour mode is settled here, while stdout is still the terminal — each
  # frame is rendered into a variable, where it no longer is. 24-bit where the
  # terminal says so (COLORTERM), 16 colours otherwise, none under NO_COLOR or
  # when not a terminal. TICKET_VIEW_THEME picks the palette: tokyonight
  # (default), catppuccin, gruvbox, nord — or ansi / mono to force a mode.
  local theme="${TICKET_VIEW_THEME:-tokyonight}" mode=none
  if [[ -z "${NO_COLOR:-}" ]] && { [[ -t 1 ]] || [[ "${TICKET_VIEW_COLOR:-}" == 1 ]]; }; then
    case "${COLORTERM:-}" in truecolor|24bit) mode=true ;; *) mode=ansi ;; esac
  fi
  case "$theme" in ansi) [[ "$mode" == none ]] || mode=ansi ;; mono) mode=none ;; esac
  frame() {
    local cols
    # Fit the pane it's in.
    cols="${COLUMNS:-}"; [[ "$cols" =~ ^[0-9]+$ ]] || cols="$(tput cols 2>/dev/null || echo 120)"
    board_rows | jq -r --argjson W "$cols" --arg mode "$mode" --arg theme "$theme" \
      --arg board "$BOARD_ID" --arg base "$BASE_REF" --arg clock "$(date +%H:%M:%S)" \
      --arg dm "$dm" --arg de "$de" -f "$SKILL_DIR/scripts/board-view.jq"
  }
  if (( ! watch )); then frame; return; fi

  # A full-screen app, like htop: the alternate screen (the scrollback comes back
  # on exit), no cursor, a redraw in place instead of a clear (no flicker), keys
  # read between refreshes — q quits, r refreshes now — and an immediate redraw
  # when the pane is resized.
  local dim="" off=""
  [[ "$mode" != none ]] && { dim=$'\e[2m'; off=$'\e[0m'; }
  printf '\e[?1049h\e[?25l'
  trap 'printf "\e[?25h\e[?1049l"' EXIT
  trap 'exit 0' INT TERM
  trap ':' WINCH   # interrupts the read below, so a resize redraws at once
  local next=0 out key
  while :; do
    if (( SECONDS >= next )); then
      (( HAS_REMOTE )) && { run_git_net fetch "$REMOTE" "$BASE_BRANCH" --quiet 2>/dev/null || true; }
      load_board
      next=$(( SECONDS + every ))
    fi
    out="$(frame)"
    # Home, every line with its tail cleared, then everything below cleared.
    printf '\e[H%s\n%s q quit · r refresh · ~ suggested model/effort · every %ss%s\e[K\e[J' \
      "$(sed $'s/$/\e[K/' <<<"$out")" "$dim" "$every" "$off"
    key=""
    if [[ -t 0 ]]; then read -rsn1 -t "$(( next - SECONDS > 0 ? next - SECONDS : 1 ))" key || true
    else sleep "$every"; fi
    case "$key" in q|Q) break ;; r|R) next=0 ;; esac
  done
}

# Each ticket's **Suggested helpers:** line — what the board scans for research a
# whole wave shares, before launching it. Read from the body, so it's here and
# not in the digest.
cmd_helpers() {
  board_init "${1:-}"; shift
  local nn t line
  for nn in "$@"; do
    t="$(ticket_json "$nn")"
    line="$(sed -n 's/^\*\*Suggested helpers:\*\* *//p' "$(jq -r .file <<<"$t")" | head -1)"
    echo "$(jq -r .nn <<<"$t") ${line:--}"
  done
}

# Everything ticket-retro reads, gathered so the agent reasons over a few
# hundred lines instead of raw transcripts (one ticket's can run to megabytes).
# Per ticket: its saved report, the Claude Code transcripts its worktree left
# (found under every config root, since an --account ticket logs under its own),
# and a cheap extract of each — the tool calls that errored, and which tools ran
# how often. Then the files a retro proposes changes to, and the skills it follows.
cmd_retro() {
  board_init "${1:-}"
  local reports="$(board_state_dir)/reports" t nn branch wt enc f roots=() root
  roots=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
  [[ -d "$HOME/.claude" ]] && roots+=("$HOME/.claude")
  for root in "$HOME"/.claude-switch/accounts/*; do [[ -d "$root" ]] && roots+=("$root"); done
  echo "RETRO board $BOARD_ID — $(jq length <<<"$BOARD_JSON") tickets"
  while IFS= read -r t; do
    nn="$(jq -r .nn <<<"$t")"; branch="$(jq -r .branch <<<"$t")"
    [[ -n "$branch" ]] || continue
    wt="$(jq -r .worktree <<<"$t")"; [[ -n "$wt" ]] || wt="$(dirname "$ROOT")/${REPO_NAME}--${branch}"
    echo; echo "TICKET $nn $(jq -r .status <<<"$t") $branch — $(jq -r .title <<<"$t")"
    if [[ -s "$reports/$branch.md" ]]; then echo "  REPORT $reports/$branch.md"; else echo "  REPORT none"; fi
    enc="$(sed 's/[^A-Za-z0-9]/-/g' <<<"$wt")"
    for f in $(for root in "${roots[@]}"; do ls "$root/projects/$enc"/*.jsonl 2>/dev/null; done | sort -u); do
      echo "  TRANSCRIPT $f ($(du -h "$f" | cut -f1))"
      echo "    tools: $(jq -r 'select(.type=="assistant") | .message.content[]? | select(type=="object" and .type=="tool_use") | .name' "$f" 2>/dev/null \
                         | sort | uniq -c | sort -rn | awk '{printf "%s×%s ", $2, $1}')"
      jq -r 'select(.type=="user") | .message.content[]? | select(type=="object" and .type=="tool_result" and .is_error==true)
             | (.content | tostring | gsub("\\s+"; " "))[0:160]' "$f" 2>/dev/null \
        | sort | uniq -c | sort -rn | head -12 | sed 's/^ *\([0-9]*\) /    error×\1: /'
    done
  done < <(jq -c '.[]' <<<"$BOARD_JSON")
  echo
  for f in docs/agents/project-memory.md CLAUDE.md AGENTS.md CODING_STANDARDS.md; do
    [[ -f "$ROOT/$f" ]] && echo "FILE $ROOT/$f" || echo "FILE $f none"
  done
  for f in retro writing-for-agents; do
    root="$(find "${roots[@]}" -path '*mattpocock*' -path "*/$f/SKILL.md" 2>/dev/null | head -1 || true)"
    echo "SKILL $f ${root:-none found — update mattpocock-skills to v1.3 or later}"
  done
}

verb="${1:-}"; shift || true
case "$verb" in
  digest|launch|gates|ready|merge|resolve|say|show|helpers|retro|view) "cmd_$verb" "$@" ;;
  *) sed -n '2,25p' "$0"; exit 1 ;;
esac
