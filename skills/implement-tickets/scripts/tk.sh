#!/usr/bin/env bash
# tk.sh — the board session's hands. Every check that has a guard is here, as
# code, so the model driving the board (Haiku, by default) only reads results
# and decides. See docs/adr/0004-haiku-board-session.md.
#
# Usage (<board> is a Jira id or slug under .scratch/, a path, or "" for the only one there):
#   tk.sh digest  <board> [--full]       board, agents and git in one read; prints only what changed
#   tk.sh launch  <board> <NN> --type <feat|fix|...> --model <m> --effort <e> [--account <a>] [--research <file>]
#                                        (a **Kind:** doc ticket launches as a document, branch type docs)
#   tk.sh gates   <board> <NN>           the five merge gates, one line each
#   tk.sh ready   <board>                every in-progress ticket whose PR passes all gates
#   tk.sh pr      <board> <NN>           commit the ticket's work, push, open its PR — the words by the Cursor CLI
#   tk.sh push    <board> <NN>           commit the ticket's work and push its branch, no PR (TICKET_FORGE=none)
#   tk.sh merge   <board> <NN>           gates, then merge the PR on the forge (GitHub or Azure DevOps), then resolve
#   tk.sh resolve <board> <NN>           mark a landed ticket resolved in its home
#   tk.sh resolve <board> <NN> --no-code "<reason>"   resolve a ticket that delivers nothing committable
#   tk.sh why     <board> <NN>           every step of "has it landed?" for one ticket
#   tk.sh say     <board> <NN> <file>    relay a message to the ticket's agent, verbatim
#   tk.sh show    <board> <NN> [lines]   the agent's recent output (on request only)
#   tk.sh view    <board> [--watch [secs]]  the status board for the developer — no model involved;
#                                        --watch is full-screen: q quits, r refreshes (TICKET_VIEW_THEME)
#   tk.sh boards                         every board under the main checkout's .scratch/, as one JSON array
#                                        [{slug, path, tickets}] — machine-readable, nothing else on stdout
#   tk.sh export  <board>                one JSON object: board info, board.md, retro-results.md and every
#                                        ticket as the status board sees it (tickets = board_rows) — for tk-hub
#   tk.sh help                           every command: board session, tickets tab, shell aliases
#   tk.sh helpers <board> <NN>...        each ticket's Suggested helpers line (for a wave's shared research)
#   tk.sh retro   <board>                everything ticket-retro reads: reports, transcript extracts, files, skills
#   tk.sh retro-save <board>             save ticket-retro's output (stdin) as retro/proposals.md; the previous one is archived
#   tk.sh retro-apply <board> [approve|reject|defer <id>...]...  mark proposals by id, regenerate retro-results.md
#   tk.sh policy  <board>                the resolved policy as JSON: defaults < box < repo < board, env TICKET_FORGE wins
#   tk.sh policy-set <board> key=value...  write the board's .scratch/<board>/policy.json (typed; key= removes)
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
  local t0=$SECONDS t1 t2
  fetch_board_refs
  t1=$SECONDS
  forge_cache_begin
  local agents facts="" t nn status branch base agent st tab l pushed ps
  local herdr_ok=1
  export LANDED_ERRS; LANDED_ERRS="$(mktemp)"
  agents="$(agent_states)" || { herdr_ok=0; echo "WARN Herdr didn't answer — agent states unknown"; }
  while IFS= read -r t; do
    nn="$(jq -r .nn <<<"$t")"; status="$(jq -r .status <<<"$t")"
    branch="$(jq -r .branch <<<"$t")"; base="$(jq -r .base <<<"$t")"; agent="$(jq -r .agent <<<"$t")"
    l="-"; st="-"; tab="-"; pushed=""
    if [[ "$status" == in-progress ]]; then
      l="$(landed "$branch" "$base")"
      ps="$(pushed_sha "$branch" "$base" "$(jq -r .worktree <<<"$t")")"
      # Fully pushed: "<sha>", or "<sha>+<n>untracked" with untracked files beside it;
      # pushed with more tracked work beside it: "<sha>+unpushed".
      if [[ "$ps" == *" more "* ]]; then pushed="${ps%% *}+unpushed"
      elif [[ -n "$ps" && "${ps##* }" != 0 ]]; then pushed="${ps%% *}+${ps##* }untracked"
      else pushed="${ps%% *}"; fi
      if [[ -n "$agent" ]]; then
        st="gone"
        IFS=$'\t' read -r _ st tab < <(awk -F'\t' -v a="$agent" '$1 == a' <<<"$agents") || true
        [[ -n "$st" ]] || st="gone"
        (( herdr_ok )) || st="?"
      fi
    fi
    facts+="$(jq -cn --arg nn "$nn" --arg l "$l" --arg s "$st" --arg tab "${tab:--}" --arg p "$pushed" '{nn:$nn, landed:$l, state:$s, tab:$tab, pushed:$p}')"$'\n'
  done < <(jq -c '.[]' <<<"$BOARD_JSON")
  # The forge failing makes a squash merge whose content changed in review look
  # unmerged — say so once, with its own words, rather than per ticket or never.
  [[ -s "$LANDED_ERRS" ]] && echo "WARN $(forge_name) couldn't be asked whether PRs merged: $(grep -v '^[[:space:]]*$' "$LANDED_ERRS" | sort -u | tail -1)"
  rm -f "$LANDED_ERRS"; unset LANDED_ERRS
  forge_cache_end
  t2=$SECONDS
  # Every board turn starts here, so a slow one says where the time went.
  (( t2 - t0 < 15 )) || echo "WARN digest took $((t2 - t0))s: fetch $((t1 - t0))s, landing checks and $(forge_name) $((t2 - t1))s"

  # The policy as of this digest, so the board session needn't ask every turn.
  local policy; policy="$(policy_digest_lines)"
  local state_file prev="{}"
  state_file="$(board_state_dir)/$BOARD_SLUG.digest.json"
  [[ -f "$state_file" ]] && prev="$(cat "$state_file")"
  local out
  out="$(jq -n --argjson board "$BOARD_JSON" --argjson prev "$prev" --argjson full "$full" \
           --slurpfile facts <(printf '%s' "$facts") \
           --arg id "$BOARD_ID" --arg base "$BASE_REF" --arg remote "$REMOTE" --argjson off "$(forge_off && echo true || echo false)" --arg policy "$policy" '
    ($facts | map({key: .nn, value: .}) | from_entries) as $f |
    ($board | map({key: .nn, value: .status}) | from_entries) as $st |
    def dash: if . == null or . == "" then "-" else . end;
    [ $board[] | . as $t | $f[$t.nn] as $x |
      (($t.blockers | map(select($st[.] != "resolved"))) + ($t.xblockers_open // [])) as $open |
      $t + {landed: $x.landed, state: $x.state, tab: $x.tab, pushed: ($x.pushed // ""), open_blockers: $open,
            line: ([ $t.nn, $t.status, $t.ref,
                     ($t.branch | dash),
                     (if $t.agent != "" then "agent:\($x.state)" else "-" end),
                     "landed:\($x.landed)",
                     "blockers:\($open | join(",") | dash)",
                     "run:\($t.model | dash)/\($t.effort | dash)",
                     "suggests:\($t.smodel | dash)/\($t.seffort | dash)" ]
                   + (if $off and ($x.pushed // "") != "" then ["pushed:\($x.pushed)"] else [] end) | join(" ")) } ] as $rows |
    ($rows | map({key: .nn, value: .line}) | from_entries) as $now |
    ($prev.lines // {}) as $was |
    [ $rows[] | select($was[.nn] != .line) | .nn ] as $changed |
    { lines: $now,
      text: ([ "BOARD \($id) base \($base)" +
                 (([$board[].parent | select(. != "")] | unique) as $p |
                  if ($p | length) > 0 then " parent \($p | join(","))" else "" end) ]
             + ($policy | split("\n"))
             + [ $rows[] | select($full == 1 or ($prev.lines == null) or ($was[.nn] != .line)) | .line ]
             + [ "FRONTIER " + ([ $rows[] | select(.status == "open" and (.open_blockers | length) == 0 and (.foreign // "") == "") | .nn ] | join(" ") | dash) ]
             + [ $rows[] | select(.status == "in-progress") |
                 if (.landed | startswith("yes")) then "ACTION resolve \(.nn) — landed (\(.landed | ltrimstr("yes:")))"
                 elif (.landed | startswith("unknown")) then "ACTION check \(.nn) — landed unknown (\(.landed | ltrimstr("unknown:"))); leave it, tell the developer"
                 elif .state == "blocked" then "ACTION dialog \(.nn) — agent waiting at a dialog in tab \(.tab); the developer answers it"
                 elif .state == "gone" then "ACTION orphan \(.nn) — no live agent and not landed; tell the developer"
                 elif ((.state == "idle" or .state == "done") and ($was[.nn] != .line) and $off and (.pushed | test("^[0-9a-f]+(\\+[0-9]+untracked)?$"))) then "ACTION pushed \(.nn) — \(.pushed | split("+") | .[0]) is on \($remote)/\(.branch), not landed yet\(.pushed | capture("\\+(?<n>[0-9]+)untracked$").n // "" | if . != "" then " (\(.) untracked file(s) left in its worktree)" else "" end); the next digest resolves it once it is merged"
                 elif ((.state == "idle" or .state == "done") and ($was[.nn] != .line)) then "ACTION review \(.nn) — agent finished; ready for the developer (or: \(if $off then "push" else "open PR" end))"
                 else empty end ]
             + [ $rows[] | select((.unknown_refs // []) | length > 0) | "WARN \(.nn) blocked-by names nothing on the board: \(.unknown_refs | join(","))" ]
             + [ $rows[] | select((.xblockers_open // []) | any(endswith("(not found)"))) | "WARN \(.nn) blocked by a ticket on another repo'"'"'s board that can'"'"'t be found: \(.xblockers_open | map(select(endswith("(not found)"))) | join(", ")) — counted as open" ]
             + [ $rows[] | select(.foreign != "") | "WARN \(.nn) changes \(.foreign), not this repo — it can'"'"'t launch here; move its file to that repo'"'"'s .scratch/\($id)/issues/ and run the board there" ]
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
  [[ -z "$type" || "$type" =~ ^(feat|fix|refactor|chore|docs|test|perf|ci)$ ]] || die "--type must be one of feat fix refactor chore docs test perf ci"
  [[ -n "$model" && -n "$effort" ]] || die "--model and --effort are required (the session's settings, or this ticket's suggestion)"
  local t status open kind doc_args=()
  t="$(ticket_json "$nn")"
  # **Kind:** picks the brief. No line is `code` and launches exactly as before;
  # `doc` is a document — /ticket's doc brief, the doc reviewer, branch type
  # `docs` whatever --type said, and **Doc type:** (default `other`) for the
  # launcher to check. Anything else is refused before anything is created.
  kind="$(jq -r '.kind // ""' <<<"$t")"; kind="${kind:-code}"
  case "$kind" in
    code) ;;
    doc)  type="docs"; doc_args=(--doc --doc-type "$(jq -r '.doc_type // "" | if . == "" then "other" else . end' <<<"$t")") ;;
    *)    die "ticket $nn has an unknown **Kind:** '$kind' — known kinds: $TICKET_KINDS (no line means code)" ;;
  esac
  [[ -n "$type" ]] || die "--type is required for a code ticket — one of feat fix refactor chore docs test perf ci"
  status="$(jq -r .status <<<"$t")"
  [[ "$status" == open ]] || die "ticket $nn is $status, not open"
  local foreign; foreign="$(foreign_repo "$t")"
  [[ -z "$foreign" ]] || die "ticket $nn changes $foreign, not $REPO_NAME — its worktree, branch and PR belong there. Move its file to that repo's .scratch/$BOARD_ID/issues/ and launch it from the board there (board.sh $BOARD_ID, run in that repo)"
  open="$(jq -r --argjson b "$BOARD_JSON" '[.blockers[] as $x | $b[] | select(.nn == $x and .status != "resolved") | .nn] + (.xblockers_open // []) | join(",")' <<<"$t")"
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
  args+=(${doc_args[@]+"${doc_args[@]}"} --effort "$effort" "$label" "$branch" "$brief" "$model")
  out="$(mktemp)"
  set +e; "$LAUNCHER" "${args[@]}" >"$out" 2>&1; rc=$?; set -e
  cat "$out"
  if [[ $rc -eq 0 && "${TICKET_DRY_RUN:-0}" == 1 ]]; then
    echo "DRY RUN $nn2 — nothing launched, nothing recorded"
  elif [[ $rc -eq 0 || $rc -eq 3 ]]; then
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
  local t="$1" branch json fail=0 conflicting=0 pending=0 forge
  branch="$(jq -r .branch <<<"$t")"
  PR_NUMBER=""; forge="$(forge_name)"
  [[ -n "$branch" ]] || { echo "GATE pr FAIL ticket has no branch recorded"; return 12; }
  json="$(forge_pr_open "$branch")" || { echo "GATE pr FAIL couldn't ask $forge about $branch"; return 12; }
  [[ -n "$json" ]] || { echo "GATE pr FAIL no open PR on $branch — not pushed, or no PR opened yet"; return 12; }
  PR_NUMBER="$(jq -r .number <<<"$json")"; echo "GATE pr PASS #$PR_NUMBER"
  if [[ "$(jq -r .mergeable <<<"$json")" == UNKNOWN ]]; then
    sleep 3; json="$(forge_pr_get "$PR_NUMBER")" || { echo "GATE pr FAIL couldn't re-read #$PR_NUMBER from $forge"; return 12; }
  fi
  if [[ "$(jq -r .isDraft <<<"$json")" == true ]]; then echo "GATE ready FAIL draft"; fail=1
  elif [[ "$(jq -r .base <<<"$json")" != "$BASE_BRANCH" ]]; then echo "GATE ready FAIL base is $(jq -r .base <<<"$json"), not $BASE_BRANCH"; fail=1
  else echo "GATE ready PASS"; fi
  case "$(jq -r .mergeable <<<"$json")" in
    MERGEABLE)   echo "GATE mergeable PASS" ;;
    CONFLICTING) echo "GATE mergeable FAIL conflicts with $BASE_BRANCH — send ticket-merger"; conflicting=1 ;;
    *)           echo "GATE mergeable FAIL $forge hasn't computed it yet — ask again in a minute"; fail=1 ;;
  esac
  local checks; checks="$(jq -c .checks <<<"$json")"
  if [[ "$(jq '[.[] | select(.s == "bad")] | length' <<<"$checks")" -gt 0 ]]; then
    echo "GATE checks FAIL failed: $(jq -r '[.[] | select(.s == "bad") | .n] | join(", ")' <<<"$checks")"; fail=1
  elif [[ "$(jq '[.[] | select(.s == "pending")] | length' <<<"$checks")" -gt 0 ]]; then
    echo "GATE checks FAIL still running: $(jq -r '[.[] | select(.s == "pending") | .n] | join(", ")' <<<"$checks")"; pending=1
  else echo "GATE checks PASS ($(jq length <<<"$checks") checks)"; fi
  case "$(jq -r .review <<<"$json")" in
    APPROVED|"") echo "GATE review PASS" ;;
    *) echo "GATE review FAIL $(jq -r .review <<<"$json")"; fail=1 ;;
  esac
  (( fail )) && return 12; (( pending )) && return 11; (( conflicting )) && return 10; return 0
}

# PRs need a remote. Without one there is nothing to gate: the developer merges
# the branch locally and the next digest sees it by ancestry.
need_pr_remote() {
  (( HAS_REMOTE )) || die "no '$REMOTE' remote in $ROOT (forge: none) — no PRs here; merge the branch locally and the next digest resolves it"
  forge_need
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
  # The forge's own merge: GitHub's default method for the repo, Azure's
  # TICKET_AZURE_MERGE. Never bypassing the rules the forge enforces, never
  # deleting the branch (it's still checked out in the ticket's worktree).
  method="$(forge_merge "$PR_NUMBER")"
  echo "MERGED $nn #$PR_NUMBER ($method)"
  resolve_ticket "$t"
}

# ---- opening a PR ---------------------------------------------------------------------
# The Cursor CLI writes the words and pr-open.sh does the git (pr-cursor.sh): no
# Claude agent, no Claude tokens. TICKET_PR_RUNNER=claude keeps the Claude agent:
# exit 5 tells the board session to dispatch ticket-pr-creator instead.
cmd_pr() {
  load_models_env
  # Refuse up front (git-only mode, no remote, no forge CLI) so no agent is dispatched for nothing.
  board_init "${1:-}"; need_pr_remote
  if [[ "${TICKET_PR_RUNNER:-cursor}" == claude ]]; then
    echo "RUNNER claude — dispatch ticket-pr-creator for ticket ${2:-?}"; return 5
  fi
  "$SKILL_DIR/scripts/pr-cursor.sh" "$@"
}

# ---- push: forge=none's way to ship ------------------------------------------------
# The same guarded commit and push as a PR — Cursor's message, the named paths,
# the risky-file guard, no attribution — and no PR: the developer merges on the
# forge, and the landing check moves the ticket to done. Any forge; the only
# shipping verb when TICKET_FORGE=none.
cmd_push() {
  load_models_env
  board_init "${1:-}"
  (( HAS_REMOTE )) || die "no '$REMOTE' remote in $ROOT — nowhere to push; merge the branch locally and the next digest resolves it"
  "$SKILL_DIR/scripts/pr-cursor.sh" "${1:-}" "${2:?usage: tk.sh push <board> <NN>}" --push
}

# ---- resolve ----------------------------------------------------------------------
resolve_ticket() {
  local t="$1" nn branch l sha line
  nn="$(jq -r .nn <<<"$t")"; branch="$(jq -r .branch <<<"$t")"
  (( HAS_REMOTE )) && { run_git_net fetch "$REMOTE" "$BASE_BRANCH" --quiet 2>/dev/null || true; }
  (( HAS_REMOTE )) && [[ -n "$branch" ]] && { run_git_net fetch "$REMOTE" "+refs/heads/$branch:refs/remotes/$REMOTE/$branch" --quiet 2>/dev/null || true; }
  local base err; base="$(jq -r .base <<<"$t")"
  l="$(landed "$branch" "$base")"
  if [[ "$l" != yes:* ]]; then
    # Say why the forge didn't settle it, rather than a bare "no": a merge done
    # outside the board is only visible to git once it has been fetched, and to
    # the forge only when its CLI can be asked.
    if forge_ok && ! err="$(forge_merged_pr "$branch" 2>&1 >/dev/null)"; then
      die "ticket $nn hasn't landed by git ($l), and $(forge_name) couldn't be asked: $(tail -1 <<<"$err")"
    fi
    die "ticket $nn hasn't landed ($l): $branch isn't in $BASE_REF by ancestry or content, and $(forge_off && echo "the forge was not asked ($(forge_off_why))" || echo "$(forge_name) reports no merged PR from it") — not resolving it (tk.sh why $BOARD_ID $nn shows each check)"
  fi
  if [[ "$l" == yes:pr#* ]]; then
    sha="$(forge_merge_commit "${l#yes:pr#}" 2>/dev/null || true)"
  elif [[ "$l" == yes:squash:* ]]; then
    sha="${l#yes:squash:}"
  else
    sha="$(git -C "$ROOT" rev-parse --short "$branch")"
  fi
  line="**Status:** resolved — merged into $BASE_BRANCH as ${sha:-?} on $(date +%F)"
  local f tmp; f="$(jq -r .file <<<"$t")"; tmp="$(mktemp)"
  awk -v line="$line" '/^\*\*Status:\*\*/ { print line; next } /^\*\*Agent:\*\*/ { next } { print }' "$f" >"$tmp"
  mv "$tmp" "$f"
  echo "RESOLVED $nn ($l) — /sweep-tickets lists its worktree and branch for cleanup"
}

# Every step landed() takes for one ticket, for when the board disagrees with
# what the developer merged.
cmd_why() {
  board_init "${1:-}"; local t nn="${2:?usage: tk.sh why <board> <NN>}" branch l
  t="$(ticket_json "$nn")"; branch="$(jq -r .branch <<<"$t")"
  if (( HAS_REMOTE )); then
    run_git_net fetch "$REMOTE" "$BASE_BRANCH" --quiet 2>/dev/null || echo "  fetch of $REMOTE/$BASE_BRANCH failed — using the last fetch"
    [[ -n "$branch" ]] && { run_git_net fetch "$REMOTE" "+refs/heads/$branch:refs/remotes/$REMOTE/$branch" --quiet 2>/dev/null \
      || echo "  $REMOTE has no branch $branch (deleted after the merge, or pushed under another name)"; }
  fi
  if forge_off; then echo "ticket $nn: $(jq -r .status <<<"$t"), forge: none ($(forge_off_why)) — git log only"
  else echo "ticket $nn: $(jq -r .status <<<"$t"), forge $(forge_name)$([[ $FORGE == azure ]] && echo " ($AZ_ORG / $AZ_PROJECT / $AZ_REPO)")"; fi
  local errs; errs="$(mktemp)"
  # The trace goes to stderr, straight through; only the verdict is captured.
  l="$(LANDED_TRACE=1 LANDED_ERRS="$errs" landed "$branch" "$(jq -r .base <<<"$t")")"
  [[ -s "$errs" ]] && echo "  $(forge_name) said: $(grep -v '^[[:space:]]*$' "$errs" | tail -1)"
  rm -f "$errs"
  echo "LANDED $l"
  # The open PR, as the status board reads it — or why it can't.
  if forge_ok && [[ -n "$branch" ]]; then
    local pr perr; perr="$(mktemp)"
    if pr="$(forge_pr_open "$branch" 2>"$perr")"; then
      if [[ -n "$pr" ]]; then echo "OPEN PR $(jq -c '{number, base, isDraft, mergeable, review, checks: [.checks[] | "\(.n)=\(.s)"]}' <<<"$pr")"
      else echo "OPEN PR none — $(forge_name) lists no active PR from $branch"; fi
    else echo "OPEN PR unknown — $(forge_name) said: $(grep -v '^[[:space:]]*$' "$perr" | tail -1)"; fi
    rm -f "$perr"
  elif forge_off; then echo "OPEN PR not asked — forge: none ($(forge_off_why)) — git log only"
  else echo "OPEN PR not asked — $(forge_name) CLI unavailable"; fi
}

# A ticket whose deliverable is not code (gitignored files, say): resolved on the
# developer's word, but never over lost work — commits ahead of the base mean the
# normal PR/merge path, tracked changes in the worktree would be thrown away.
resolve_no_code() {
  local t="$1" reason="$2" nn branch wt ref n f tmp line st l ign
  nn="$(jq -r .nn <<<"$t")"; branch="$(jq -r .branch <<<"$t")"; wt="$(jq -r '.worktree // ""' <<<"$t")"
  st="$(jq -r .status <<<"$t")"
  case "$st" in
    in-progress) ;;
    resolved) die "ticket $nn is already resolved" ;;
    *) die "ticket $nn was never launched (status $st) — nothing to resolve" ;;
  esac
  require_agent_quiet "$(jq -r .agent <<<"$t")" "resolving it with --no-code"
  (( HAS_REMOTE )) && [[ -n "$branch" ]] && { run_git_net fetch "$REMOTE" "$BASE_BRANCH" --quiet 2>/dev/null || true; }
  (( HAS_REMOTE )) && [[ -n "$branch" ]] && { run_git_net fetch "$REMOTE" "+refs/heads/$branch:refs/remotes/$REMOTE/$branch" --quiet 2>/dev/null || true; }
  l="$(landed "$branch" "$(jq -r .base <<<"$t")")"
  [[ "$l" == yes:* ]] && die "ticket $nn landed ($l) — it has code; use plain resolve, not --no-code"
  if [[ -n "$branch" ]]; then
    for ref in "$branch" "$REMOTE/$branch"; do
      git -C "$ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue
      [[ "$ref" == "$branch" ]] && ! git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" && continue
      n="$(git -C "$ROOT" rev-list --count "$BASE_REF..$ref" 2>&1)" || die "ticket $nn: can't compare $ref with $BASE_REF: $n"
      (( n > 0 )) && die "ticket $nn has code: $ref has $n commit(s) not on $BASE_REF — send it through the normal PR/merge path, not --no-code"
    done
  fi
  if [[ -n "$wt" && -d "$wt" ]]; then
    n="$(git -C "$wt" status --porcelain --untracked-files=no 2>&1)" || die "ticket $nn: can't read the worktree $wt: $n"
    [[ -z "$n" ]] || die "ticket $nn has uncommitted tracked changes in $wt — resolving would lose them (commit them, or discard them first):"$'\n'"$n"
  fi
  line="**Status:** resolved — no code ($reason) on $(date +%F)"
  f="$(jq -r .file <<<"$t")"; tmp="$(mktemp)"
  LINE="$line" awk '/^\*\*Status:\*\*/ { print ENVIRON["LINE"]; next } /^\*\*Agent:\*\*/ { next } { print }' "$f" >"$tmp"
  mv "$tmp" "$f"
  grep -qF -- "$line" "$f" || die "ticket $nn: the status line was not written to $f"
  echo "RESOLVED $nn (no code) — /sweep-tickets lists its worktree and branch for cleanup"
  if [[ -n "$wt" && -d "$wt" ]]; then
    ign="$(git -C "$wt" status --porcelain --ignored 2>/dev/null | grep '^!!' || true)"
    [[ -z "$ign" ]] || echo "WARN ignored files in $wt are deleted when /sweep-tickets removes the worktree — move what you want to keep:"$'\n'"$ign"
  fi
}

cmd_resolve() {
  local usage='usage: tk.sh resolve <board> <NN> [--no-code "<reason>"]'
  board_init "${1:-}"; local nn="${2:?$usage}" mode="${3:-}"
  case "$mode" in
    "") resolve_ticket "$(ticket_json "$nn")" ;;
    --no-code)
      (( $# <= 4 )) || die "quote the reason: $usage"
      [[ -n "${4:-}" && -n "${4//[[:space:]]/}" ]] || die "--no-code needs a reason: $usage"
      [[ "$4" != *$'\n'* && "$4" != *$'\r'* ]] || die "the reason must be one line"
      resolve_no_code "$(ticket_json "$nn")" "$4" ;;
    *) die "$usage" ;;
  esac
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
  forge_cache_begin
  board_rows_
  local rc=$?; forge_cache_end; return $rc
}

board_rows_() {
  local t nn status branch agent agents herdr_ok=1 st l phase round checks tab pr pushed ppart ps untracked phase_dir rows=""
  phase_dir="$(board_state_dir)/phase"
  agents="$(agent_states)" || herdr_ok=0
  while IFS= read -r t; do
    nn="$(jq -r .nn <<<"$t")"; status="$(jq -r .status <<<"$t")"
    branch="$(jq -r .branch <<<"$t")"; agent="$(jq -r .agent <<<"$t")"
    st="-"; l="-"; phase="-"; round=""; checks=""; tab="-"; pr="null"; pushed=""; ppart=""; untracked=0
    if [[ "$status" == in-progress ]]; then
      l="$(landed "$branch" "$(jq -r .base <<<"$t")")"
      ps="$(pushed_sha "$branch" "$(jq -r .base <<<"$t")" "$(jq -r .worktree <<<"$t")")"
      if [[ "$ps" == *" more "* ]]; then ppart="${ps%% *}"; else pushed="${ps%% *}"; fi
      [[ -z "$ps" ]] || untracked="${ps##* }"
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
      if forge_ok && [[ -n "$branch" ]]; then
        # A failed lookup leaves the card where git and Herdr put it, so the
        # forge's own error goes to the view's footer instead of nowhere.
        pr="$(forge_pr_open "$branch" 2>>"${VIEW_ERRS:-/dev/null}" || true)"
        jq -e 'type == "object"' <<<"${pr:-null}" >/dev/null 2>&1 || pr="null"
      fi
    fi
    rows+="$(jq -cn --argjson t "$t" --arg st "$st" --arg l "$l" --arg ph "$phase" --arg rd "$round" --arg ck "$checks" --arg tab "$tab" --argjson pr "$pr" --arg pushed "$pushed" --arg ppart "$ppart" --argjson untracked "${untracked:-0}" \
      '$t + {state:$st, landed:$l, phase:$ph, round:$rd, tab:$tab, pr:$pr, pushed:$pushed, pushed_partial:$ppart, untracked:$untracked,
             checks: ($ck | split(" ") | map(select(test("^[a-z]+=")) | split("=") | {key: .[0], value: .[1]}) | from_entries)}')"$'\n'
  done < <(jq -c '.[]' <<<"$BOARD_JSON")
  printf '%s' "$rows" | jq -s --argjson off "$(forge_off && echo true || echo false)" '
    (map({key: .nn, value: .status}) | from_entries) as $st |
    map(. as $t | (($t.blockers | map(select($st[.] != "resolved"))) + ($t.xblockers_open // [])) as $open |
      $t + {open_blockers: $open} +
      (if $t.status == "resolved" then {col: "done", note: ""}
       elif ($t.foreign // "") != "" and $t.status == "open" then {col: "needs", note: "belongs on \($t.foreign | split(" ")[0])'"'"'s board"}
       elif $t.status == "open" then
         (if ($open | length) > 0 then {col: "blocked", note: "waiting on \($open | join(", "))"}
          else {col: "backlog", note: "ready to launch"} end)
       elif ($t.landed | startswith("yes")) then {col: "done", note: "landed — resolve it"}
       elif $t.pr != null then
         ($t.pr | [.checks[]?.s] as $c |
          {col: "pr", note: ("#\(.number) " +
            (if .isDraft then "draft"
             elif .mergeable == "CONFLICTING" then "conflict"
             elif .review == "CHANGES_REQUESTED" then "changes requested"
             elif ($c | any(. == "bad")) then "checks failed"
             elif ($c | any(. == "pending")) then "checks running"
             elif .review == "REVIEW_REQUIRED" then "awaiting review"
             else "ready to merge" end))})
       elif ($t.landed | startswith("unknown")) then {col: "needs", note: "landed? \($t.landed | ltrimstr("unknown:"))"}
       elif $t.state == "blocked" then {col: "needs", note: "agent at a dialog"}
       elif $t.state == "gone" then {col: "needs", note: "no live agent"}
       elif ($t.state == "idle" or $t.state == "done") then {col: "human", note: (if $t.pushed != "" then "pushed \($t.pushed)" + (if $t.untracked > 0 then " · \($t.untracked) untracked" else "" end)
                                                                     elif $t.pushed_partial != "" then "agent finished (pushed \($t.pushed_partial), more unpushed)"
                                                                     else "agent finished" end)}
       elif ($t.phase | IN("verifying", "reviewing", "fixing", "reporting")) then {col: "review", note: $t.phase}
       else {col: "working", note: (if $t.phase != "-" then $t.phase else $t.state end)} end))
    # What to type into the board session to move the card on, where there is something.
    | map(. + {hint: (
        if .col == "backlog" then "start \(.nn)"
        elif .col == "human" and $off and .pushed != "" then "merge it on the forge"
        elif .col == "human" and $off then "push \(.nn)"
        elif .col == "human" then "open a PR for \(.nn)"
        elif .col == "pr" and (.note | test("ready to merge")) then "merge \(.nn)"
        elif .col == "pr" and (.note | test("conflict")) then "merge \(.nn) — sends the merger"
        elif .col == "needs" and .state == "blocked" then (if .tab != "-" then "answer it in tab \(.tab)" else "answer its dialog" end)
        elif .col == "needs" and .state == "gone" then "show \(.nn)"
        elif .col == "needs" and (.note | test("belongs on")) then "move it to the board of its repo"
        elif .col == "done" and (.note | test("resolve")) then "resolve \(.nn)"
        else "" end)})'
}

# ---- boards, export: the board as JSON, for tk-hub ------------------------------
# Machine-readable and nothing else on stdout (jq -e must parse it); logs and
# errors go to stderr. No fetch (fetch_board_refs, which prints WARNs to stdout,
# is not called). PR state comes from the forge (gh/az) for in-progress tickets,
# as the status board does; TICKET_FORGE=none keeps it offline. Forge errors go
# to stderr.
cmd_boards() {
  need git; need jq
  resolve_repo_root
  local d slug n out=""
  if [[ -d "$ROOT/.scratch" ]]; then
    while IFS= read -r slug; do
      [[ -n "$slug" ]] || continue
      d="$ROOT/.scratch/$slug"
      # load_file_board dies on a directory with no ticket files — that is a count of 0.
      n="$(BOARD_PATH="$d" load_file_board 2>/dev/null | jq 'length' 2>/dev/null)" || n=0
      out+="$(jq -cn --arg slug "$slug" --arg path "$d" --argjson n "${n:-0}" '{slug:$slug, path:$path, tickets:$n}')"$'\n'
    done < <(find "$ROOT/.scratch" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  fi
  printf '%s' "$out" | jq -s '.'
}

cmd_export() {
  (( $# == 1 )) && [[ -n "$1" ]] || die "usage: tk.sh export <board>   (a slug or boards[].path from tk.sh boards)"
  need git; need jq
  resolve_repo_root
  # A board name wins over a repo directory of the same name (a board called
  # `docs`), and is not lowercased like a Jira id: .scratch/ITM-12 is ITM-12.
  local arg="$1"
  [[ -d "$ROOT/.scratch/$arg" ]] && arg="$ROOT/.scratch/$arg"
  board_init "$arg" allow-empty
  local md="$BOARD_PATH/board.md" rr="$BOARD_PATH/retro-results.md"
  [[ -f "$md" ]] || md=""; [[ -f "$rr" ]] || rr=""
  errs="$(mktemp)"   # global, not local: the EXIT trap runs after the function returns
  trap 'rm -f "${errs:-}"' EXIT
  # Forge complaints go to a file, then to stderr once: a 2>>/dev/stderr
  # reopen fails when stderr is a socket.
  VIEW_ERRS="$errs" LANDED_ERRS="$errs" board_rows | jq \
    --arg board_id "$BOARD_ID" --arg slug "$BOARD_SLUG" --arg repo "$REPO_NAME" --arg root "$ROOT" \
    --arg base "$BASE_BRANCH" --arg forge "$FORGE" --argjson has_remote "$( ((HAS_REMOTE)) && echo true || echo false )" \
    --arg board_path "$BOARD_PATH" \
    '{board_id:$board_id, slug:$slug, repo:$repo, root:$root, base:$base, has_remote:$has_remote, forge:$forge, board_path:$board_path,
      board_md: null, retro_results_md: null, tickets: .}' \
    | if [[ -n "$md" ]]; then jq --rawfile v "$md" '.board_md = $v'; else cat; fi \
    | if [[ -n "$rr" ]]; then jq --rawfile v "$rr" '.retro_results_md = $v'; else cat; fi
  local rc=$?   # the pipeline's: pipefail makes a failed board_rows fail the export
  [[ -s "$errs" ]] && sort -u "$errs" >&2
  return "$rc"
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
    local errs; errs="$(mktemp)"
    VIEW_ERRS="$errs" board_rows | jq -r --argjson W "$cols" --arg mode "$mode" --arg theme "$theme" \
      --arg board "$BOARD_ID" --arg base "$BASE_REF" --arg clock "$(date +%H:%M:%S)" \
      --arg dm "$dm" --arg de "$de" --arg forge "$(case $FORGE in azure) echo azure ;; github) echo github ;; *) forge_off && echo none || echo local ;; esac)" -f "$SKILL_DIR/scripts/board-view.jq"
    # The forge's last error, once, so a PR that never reaches the PR column says why.
    [[ -s "$errs" ]] && printf '%s(%s: %s)%s\n' "${dim:-}" "$(forge_name)" "$(grep -v '^[[:space:]]*$' "$errs" | sort -u | tail -1 | cut -c1-$(( cols > 20 ? cols - 20 : 60 )))" "${off:-}"
    rm -f "$errs"
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
      fetch_board_refs >/dev/null
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

# Saves ticket-retro's output (stdin) to <board>/retro/proposals.md, so the
# proposals outlive the board session's context and can be answered by id. A
# previous proposals.md is moved to proposals.<timestamp>.md first, never lost.
cmd_retro_save() {
  local dir out ts text
  [[ -t 0 ]] && die "retro-save: stdin is a terminal — pipe ticket-retro's whole output in (tk.sh retro-save <board> < file); nothing written"
  text="$(cat)"   # before board_init: its jq calls would otherwise eat stdin
  [[ -n "${text//[[:space:]]/}" ]] || die "retro-save: empty input — pipe ticket-retro's whole output in on stdin; nothing written"
  grep -qE '^### [ME][0-9]+' <<<"$text" || echo "WARN: no '### M<n>' / '### E<n>' heading in the input — saving anyway; the proposals can't be answered by id" >&2
  board_init "${1:-}"
  [[ -d "$BOARD_PATH" ]] || die "board path is not a directory: $BOARD_PATH"
  dir="$BOARD_PATH/retro"
  out="$dir/proposals.md"
  mkdir -p "$dir"
  if [[ -e "$out" ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    while [[ -e "$dir/proposals.$ts.md" ]]; do ts="${ts}x"; done
    mv "$out" "$dir/proposals.$ts.md"
    echo "ARCHIVED $dir/proposals.$ts.md"
  fi
  printf '%s\n' "$text" > "$out"
  echo "SAVED $out"
}

# Records the developer's answers to the saved proposals and regenerates
# <board>/retro-results.md from them. Args are mark words, each followed by ids:
#   approve E1 M2 reject E2 defer M1
# Each named block in retro/proposals.md gets one **Mark:** line (replacing an
# earlier one); no args reads the marks already there, so marking by hand works
# too. Everything is validated before any file is written. Never touches
# docs/agents/project-memory.md: an approved M item is a todo for the developer.
cmd_retro_apply() {
  board_init "${1:-}"; shift || true
  local props="$BOARD_PATH/retro/proposals.md" out="$BOARD_PATH/retro-results.md"
  [[ -f "$props" ]] || die "retro-apply: no $props — run the retro and tk.sh retro-save first; nothing written"
  local known="" mark="" a id assign="" marked bad="" multi="" kind rest
  local -A seen=()
  # Every awk pass below treats a ``` or ~~~ line as a fence toggle: inside a
  # fenced block (code in a **Change:**, say) nothing is a heading or a field.
  # One scan of the file: its ids, mark words this script doesn't know, and
  # blocks with more than one **Mark:** line.
  while read -r kind rest; do
    case "$kind" in
      ID)    known+=" $rest" ;;
      BAD)   bad+="$rest"$'\n' ;;
      MULTI) multi+="$rest"$'\n' ;;
    esac
  done < <(awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^##/ { id = "" }
    /^### [ME][0-9]+ / { id = $2; print "ID " id; next }
    id && /^\*\*Mark:\*\*/ {
      cnt[id]++; m = tolower($0); sub(/^\*\*mark:\*\*[ \t]*/, "", m); sub(/[ \t]+$/, "", m)
      if (m !~ /^(approved?|reject(ed)?|defer(red)?)$/) print "BAD " id " (\"" m "\")"
    }
    END { for (i in cnt) if (cnt[i] > 1) print "MULTI " i " " cnt[i] }' "$props")
  known+=" "
  [[ -n "${known// /}" ]] || die "retro-apply: no '### M<n>' / '### E<n>' block in $props — nothing to mark; nothing written"
  for a in "$@"; do
    while [[ "$a" == *[,.\;] ]]; do a="${a%?}"; done   # "approve E1 M2, reject E2."
    [[ -n "$a" ]] || continue
    case "${a,,}" in
      approve|approved) mark=approved; continue ;;
      reject|rejected)  mark=rejected; continue ;;
      defer|deferred)   mark=deferred; continue ;;
    esac
    id="${a^^}"
    [[ "$id" =~ ^[ME][0-9]+$ ]] || die "retro-apply: unknown mark word or id '$a' — use approve|reject|defer followed by ids (M1, E2…); nothing written"
    [[ -n "$mark" ]] || die "retro-apply: '$a' comes before any mark word — say approve, reject or defer first; nothing written"
    [[ "$known" == *" $id "* ]] || die "retro-apply: unknown id '$id' — $props has:${known% }; nothing written"
    [[ -z "${seen[$id]:-}" || "${seen[$id]}" == "$mark" ]] || die "retro-apply: $id is marked both ${seen[$id]} and $mark; nothing written"
    seen[$id]="$mark"; assign+="$id=$mark "
  done
  [[ $# -eq 0 || -n "$assign" ]] || die "retro-apply: '$*' names no id; nothing written"

  # Marks already in the file must be words this script knows, one per block, or
  # the results lie. A block named in the args has all its marks replaced, so
  # only the others count.
  local -a left=()
  for a in bad multi; do
    left=()
    while IFS= read -r rest; do
      [[ -n "$rest" && " $assign" != *" ${rest%% *}="* ]] && left+=("$rest")
    done <<<"${!a}"
    printf -v "$a" '%s' "${left[*]:+$(printf '%s; ' "${left[@]}")}"
  done
  [[ -z "$bad" ]] || die "retro-apply: unknown mark word in $props: ${bad%; } — use approve(d), reject(ed) or defer(red); nothing written"
  if [[ -n "$multi" ]]; then
    multi="$(sed -E 's/([ME][0-9]+) ([0-9]+)/\1 has \2 **Mark:** lines/g' <<<"${multi%; }")"
    die "retro-apply: $multi in $props — keep one; nothing written"
  fi

  if [[ -n "$assign" ]]; then
    # One **Mark:** line right under each named heading; any earlier one goes.
    marked="$(awk -v assign="$assign" '
      BEGIN { n = split(assign, a, " "); for (i = 1; i <= n; i++) { split(a[i], kv, "="); want[kv[1]] = kv[2] } }
      /^[ \t]*(```|~~~)/ { fence = !fence; print; next }
      fence { print; next }
      /^##/ { id = "" }
      /^### [ME][0-9]+ / { print; id = $2; if (id in want) print "**Mark:** " want[id]; next }
      id in want && /^\*\*Mark:\*\*/ { next }
      { print }' "$props")"
    write_atomic "$props" <<<"$marked"
    echo "MARKED $assign"
  fi

  local results pending
  results="$(awk -v board="$BOARD_ID" -v when="$(date '+%Y-%m-%d %H:%M')" '
    function flush() {
      if (!id) return
      n++; ids[n] = id; ttl[n] = title; src[n] = f["Source"]; why[n] = f["Why"]; chg[n] = f["Change"]
      mk[n] = (m ~ /^approve/) ? "approved" : (m ~ /^reject/) ? "rejected" : (m ~ /^defer/) ? "deferred" : ""
      id = ""
    }
    # Continuation lines go under a list item: indent them, but leave blank ones blank.
    function indent(s,   k, p, r, i) {
      k = split(s, p, "\n"); r = p[1]
      for (i = 2; i <= k; i++) r = r "\n" (p[i] == "" ? "" : "    " p[i])
      return r
    }
    # Fenced lines (and the fences) are kept verbatim, blank lines and indentation included.
    /^[ \t]*(```|~~~)/ { fence = !fence; if (id && cur) f[cur] = f[cur] "\n" $0; next }
    fence { if (id && cur) f[cur] = f[cur] "\n" $0; next }
    /^##/ { flush() }
    /^### [ME][0-9]+ / {
      id = $2; title = $0; sub(/^### [ME][0-9]+[ \t]*(—|--?)?[ \t]*/, "", title)
      m = ""; cur = ""; split("", f); next
    }
    !id { next }
    /^\*\*[A-Za-z]+:\*\*/ {
      k = $0; sub(/^\*\*/, "", k); sub(/:\*\*.*/, "", k)
      v = $0; sub(/^\*\*[A-Za-z]+:\*\*[ \t]*/, "", v)
      if (k == "Mark") { m = tolower(v); cur = ""; next }
      cur = k; f[k] = v; next
    }
    cur && NF { l = $0; sub(/^[ \t]+/, "", l); f[cur] = f[cur] "\n" l }
    END {
      flush()
      print "# Retro results — " board
      print ""
      print "Generated by `tk.sh retro-apply` from `retro/proposals.md` (" when "), and regenerated from its"
      print "`**Mark:**` lines on every run — change a mark there, not here. Guidance for every ticket and a"
      print "todo for the developer, who turns open items into work. Agents never tick these boxes; project"
      print "memory is applied by hand (docs/agents/memory.md)."
      print ""
      print "## Approved"
      print ""
      c = 0
      for (i = 1; i <= n; i++) if (mk[i] == "approved") {
        c++
        head = (ids[i] ~ /^M/) ? "add to docs/agents/project-memory.md: " ttl[i] : ttl[i]
        print "- [ ] " ids[i] " " head
        if (chg[i] != "") print "  - Change: " indent(chg[i])
        if (src[i] != "") print "  - Source: " indent(src[i])
        if (why[i] != "") print "  - Reason: " indent(why[i])
      }
      if (!c) print "None."
      for (s = 1; s <= 2; s++) {
        want = (s == 1) ? "deferred" : "rejected"
        print ""
        print (s == 1) ? "## Deferred" : "## Rejected"
        print ""
        print (s == 1) ? "Not now — a later retro may pick these up again." : "Declined — the next retro should not propose these again."
        print ""
        c = 0
        for (i = 1; i <= n; i++) if (mk[i] == want) { c++; print "- " ids[i] " — " ttl[i] }
        if (!c) print "None."
      }
      for (i = 1; i <= n; i++) if (mk[i] == "") pend = pend " " ids[i]
      print "\x1fPENDING" pend
    }' "$props")"
  pending="${results##*$'\x1f'}"; results="${results%$'\n'$'\x1f'*}"

  # The results file is read like any other in the repo: write_atomic keeps its mode.
  write_atomic "$out" <<<"$results"
  echo "WROTE $out"
  if [[ "$pending" == PENDING ]]; then echo "PENDING none"
  else echo "$pending — unmarked, not in the results; mark them (args or by hand) and run again"; fi
}

# ---- policy ------------------------------------------------------------------------
# How a board behaves, read by tk-hub and the board session alike
# (docs/agents/policy.md). Not board_init: it needs only the repo and the board
# directory, so it answers on a repo with no remote, no base branch or no tickets.
policy_init() {
  repo_init
  resolve_board "${1:-}"
}

cmd_policy() {
  policy_init "${1:-}"
  policy_resolve
  jq . <<<"$POLICY_JSON"
}

# key=value... into the board's own policy.json. A value is JSON when it parses
# (true, 5, "x", {"a":1}), else a string; an empty value removes the key. A dotted
# key sets inside an object (synthesis.timeout=600). Every known key is checked
# before anything is written, and the file is replaced through a temp file. The
# read-merge-write holds a lock (flock on <board>/.policy.lock, when flock is
# installed) so two writers — tk-hub and the session, say — don't lose a change.
cmd_policy_set() {
  local usage="usage: tk.sh policy-set <board> key=value..."
  policy_init "${1:?$usage}"; shift
  (( $# )) || die "$usage"
  [[ -d "$BOARD_PATH" ]] || die "board $BOARD_ID is not a directory ($BOARD_PATH) — no place for its policy.json"
  local f arg key val obj errs lock lockfd
  f="$(policy_board_file)"
  if command -v flock >/dev/null 2>&1; then
    lock="$BOARD_PATH/.policy.lock"
    exec {lockfd}>>"$lock" || die "can't open the lock file $lock"
    flock -w 10 "$lockfd" || die "another policy-set has held $lock for 10s — nothing written; try again"
  fi
  # Only malformed JSON stops it here: a bad value already in the file is
  # checked with the result below, so policy-set can also be what fixes it.
  policy_read_layer "$f" -; obj="$POLICY_LAYER"
  for arg in "$@"; do
    [[ "$arg" == *=* ]] || die "'$arg' is not key=value — $usage"
    key="${arg%%=*}"; val="${arg#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)*$ ]] || die "'$key' is not a policy key"
    obj="$(jq -c --arg k "$key" --arg v "$val" '($k | split(".")) as $p
      | if $v == "" then delpaths([$p]) else setpath($p; ($v | try fromjson catch $v)) end' <<<"$obj" 2>&1)" \
      || die "can't set '$arg': ${obj#jq: error (at <stdin>:*): }"
  done
  errs="$(jq -r --arg only "" "$POLICY_CHECK" <<<"$obj")"
  [[ -z "$errs" ]] || die "not written — ${errs//$'\n'/; }"
  obj="$(jq "$POLICY_NORM" <<<"$obj")" || die "couldn't write $f"
  write_atomic "$f" <<<"$obj"
  echo "WROTE $f"
}

# ---- help ----------------------------------------------------------------------
# One reference for both ways in: what to type in the board session, and the
# shell aliases. Static on purpose — the board session prints it verbatim, so
# it costs no reasoning and can't drift from what's built.
cmd_help() {
  cat <<'HELP'
TICKET BOARD — commands

In the board session (Haiku) — type these as plain messages; there are no slash commands
  help                          this list
  start 07 / start 07 and 09    launch frontier tickets (blocked ones are refused); a ticket whose
                                  body says **Kind:** doc launches as a document (branch docs)
  status / what changed?        re-read the board, agents and git; report what moved
  open a PR for 04 / PR 04      commit the ticket's files, push, open the PR on GitHub or Azure
                                  DevOps — the Cursor CLI writes message and body (no Claude
                                  tokens, no attribution); TICKET_PR_RUNNER=claude: the Sonnet agent
  push 04                       the same commit and push, and no PR — how a ticket ships under
                                  TICKET_FORGE=none: merge it on the forge yourself; the card
                                  says "pushed <sha>" until it lands, then the next status
                                  resolves it. Any forge; always the Cursor CLI
  merge 05                      five gates, then merges the PR ON THE FORGE (GitHub/Azure — what
                                  the merge button does; your local main is untouched until you
                                  pull), resolve, offer what it unblocked. No remote: refused —
                                  merge the branch locally, the next status check resolves it
                                  conflict -> Sonnet merger merges main INTO the ticket branch and
                                  resolves it; you choose Commit (pushes the branch) / Abort / Leave
  merge everything ready        list what passes every gate, ask once, merge in order
  tell 03 <message>             relay your words to ticket 03's agent, verbatim
  ask 03 <question>             the same, as a question
  show 03                       summarise what ticket 03's agent is doing
  resolve 02                    mark a ticket resolved (only if it really landed)
  resolve 02 --no-code "<reason>"
                                for a ticket that delivers nothing committable (gitignored
                                  files, say) — only on the developer's word. Refused if its
                                  branch has commits not on the base (use the PR path) or its
                                  worktree has uncommitted tracked changes. Ignored files do not
                                  block it, but /sweep-tickets DELETES them with the worktree:
                                  keep the deliverable OUTSIDE the worktree (the root checkout,
                                  or a path the ticket names); a WARN lists any ignored files left
  why 02                        every step of "has 02 landed?" — when a merge you did isn't seen
  retro                         mattpocock retro over the board: id'd memory (M1..) and environment (E1..)
                                  proposals, saved to <board>/retro/proposals.md (tk.sh retro-save)
  approve E1 M2, reject E2, defer M1
                                mark the saved proposals (tk.sh retro-apply) and regenerate
                                  <board>/retro-results.md: approved items as a checklist for you
                                  and future tickets, then Deferred and Rejected. Unmarked ids are
                                  reported as pending; project-memory.md is never written
  policy / set auto_merge true  show this board's policy (tk.sh policy), or change it for this
                                  board only (tk.sh policy-set): forge, require_human_before_pr,
                                  auto_merge, night_shift, autonomy, max_parallel, usage_gate_pct
  change the plan (split, re-scope, new ticket)
                                -> /ticket <board> ... in an Opus planning session; it appends here

In the tickets tab (status board)
  q quit   r refresh now   resize redraws   card hints (-> merge 05) say what to type next

In a shell (aliases: ~/.claude/skills/ticket-aliases.sh, sourced from ~/.bashrc)
  tkuse <board>      set this shell's board (TK_BOARD); tkuse alone shows it
  tkb  [board]       start the board session (opens the tickets tab)
  tkbp [board]       print the board session's claude command, start nothing
  tkv  [board] [s]   status board, full-screen, refresh every s seconds (default 30)
  tkvv [board]       status board, printed once
  tkd  [board]       digest: board, agents, git in one read
  tkr  [board]       every ticket whose PR passes all gates
  tkg  [board] NN    the five merge gates for one ticket
  tks  [board] NN    what one ticket's agent is doing
  tkw  [board] NN    why the board thinks a ticket has (or hasn't) landed
  tkp  [board] NN    open one ticket's PR (Cursor writes message and body)
  tkpu [board] NN    commit and push one ticket's branch, no PR (TICKET_FORGE=none)
  tk <verb> ...      tk.sh directly (digest, view, gates, ready, why, push, helpers, retro,
                     retro-save, retro-apply, policy, policy-set, boards, export, help)
  tkhelp             this list

For tools (JSON on stdout, logs on stderr — tk-hub reads these)
  tk.sh boards            every board under .scratch/: [{slug, path, tickets}]
  tk.sh export <board>    board info, board.md, retro-results.md and every ticket as the status
                          board sees it, as one object (slug or boards[].path; `base` is the base
                          branch name, not a sha; `has_remote` tells forge none from no remote).
                          No fetch; in-progress tickets ask the forge for PR state — TICKET_FORGE=none
                          keeps it offline

Forges (PRs, gates, merge) — picked from the remote URL
  GitHub         gh, logged in
  Azure DevOps   az + az extension add --name azure-devops; az devops login (or AZURE_DEVOPS_EXT_PAT)
  TICKET_FORGE=github|azure       override the detection
  TICKET_FORGE=none               git only: no gh/az call; digest/view/why/resolve read the git log,
                                  pr/gates/ready/merge refuse — push, then merge on the forge yourself
  TICKET_AZURE_MERGE=squash|merge Azure's merge strategy (default squash; GitHub uses the repo's)
  TICKET_PR_RUNNER=cursor|claude  who writes PR words: the Cursor CLI (default; cursor-agent login)
                                  or the Claude ticket-pr-creator agent
  TICKET_NET_TIMEOUT=90           seconds before a push or forge call gives up (they never prompt;
                                  a timeout usually means: sign in once in a shell — az devops login)
  policy "forge": "none"          the same as TICKET_FORGE=none, set per repo or board in policy.json;
                                  TICKET_FORGE, when set, beats it

Policy (tk.sh policy <board>) — later wins: defaults < box < repo < board
  box    $TICKET_BOX_POLICY, default ~/.config/tk-daemon/policy.json
  repo   <main checkout>/.scratch/policy.json
  board  .scratch/<board>/policy.json — what policy-set writes (key=value, typed; key= removes)
  docs/agents/policy.md lists the keys and their defaults

Elsewhere
  /ticket [jira-id] <task>   plan a board (Opus); ends by printing the tkb command
  /small-ticket <task>       one ad-hoc ticket (a document deliverable launches in --doc mode)
  /sweep-tickets             after the retro: list and remove leftover worktrees and branches
HELP
}

verb="${1:-}"; shift || true
case "$verb" in
  digest|launch|gates|ready|pr|push|merge|resolve|why|say|show|helpers|retro|view|boards|export|help) "cmd_$verb" "$@" ;;
  retro-save) cmd_retro_save "$@" ;;
  retro-apply) cmd_retro_apply "$@" ;;
  policy) cmd_policy "$@" ;;
  policy-set) cmd_policy_set "$@" ;;
  *) sed -n '2,36p' "$0"; exit 1 ;;
esac
