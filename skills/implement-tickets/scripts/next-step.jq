# A ticket's one next step, for tk.sh export (docs/agents/next-step.md): who owns it
# and what it is, computed from the row board_rows built, never stored. tk-hub reads
# it and adds what only it knows (a park, a ready batch, a deploy to tick, a refused
# resolve).
#
#   owner   agent   the ticket's agent: build, review (its own review loop), fix (a PR's
#                   changes or failed checks)
#           hub     tk-hub or the board session acts on its own: launch, resume (no live
#                   agent), resolve (landed), pr (night_shift, no human gate, review passed),
#                   merge (auto_merge)
#           daniel  the developer: review (the human gate, a PR awaiting review), merge
#                   (a conflicting PR too: nothing sends the merger until "merge NN" does),
#                   answer (a question, a dialog, a landing nobody can tell, a misfiled
#                   ticket), start / work (a ticket of his own, Owner: me)
#           none    nobody: blocked, wait (checks running, a draft), done
#   step    one of the words above
#   since   when the ticket last changed (its file, phase or questions), ISO UTC, or null
#   reason  one line: why this step, in words
#
# Arguments: $pol (tk.sh policy's object: auto_merge, night_shift, require_human_before_pr),
# $off (true when the forge is off: a pushed branch is merged on the forge by hand) and
# $since ({nn: iso}). Input: the export object; output: it, each ticket with `next`.

def prstate:
  [.checks[]?.s] as $c
  | if .mergeable == "CONFLICTING" then "conflict"
    elif .isDraft then "draft"
    elif .review == "CHANGES_REQUESTED" then "changes requested"
    elif ($c | any(. == "bad")) then "checks failed"
    elif ($c | any(. == "pending")) then "checks running"
    elif .review == "REVIEW_REQUIRED" then "awaiting review"
    else "ready to merge" end;

def ask: .questions | map(select(.a == null and .blocks)) | first;

def step($owner; $step; $reason): {owner: $owner, step: $step, reason: $reason};

def next_of($pol):
  (.owner // "ai") as $who
  | if .col == "done" then
      (if .status == "dropped" then step("none"; "done"; "dropped" + (if (.dropped // "") != "" then ": \(.dropped)" else "" end))
       elif .status == "resolved" then step("none"; "done"; "resolved")
       else step("hub"; "resolve"; "landed (\(.landed | ltrimstr("yes:"))), not resolved yet") end)
    elif .col == "blocked" then step("none"; "blocked"; .note)
    elif .col == "backlog" then
      (if $who == "me" then step("daniel"; "start"; "yours: start it with a helper")
       else step("hub"; "launch"; "ready to launch") end)
    elif .col == "pr" and .pr == null then step("daniel"; "merge"; .note)
    elif .col == "pr" then
      (.pr | prstate) as $s
      | (if $s == "ready to merge" then
           (if $pol.auto_merge == true then step("hub"; "merge"; "PR #\(.pr.number) ready to merge, auto_merge on")
            else step("daniel"; "merge"; "PR #\(.pr.number) ready to merge") end)
         elif $s == "awaiting review" then step("daniel"; "review"; "PR #\(.pr.number) awaiting review")
         elif $s == "conflict" then step("daniel"; "merge"; "PR #\(.pr.number) conflicts with the base: merge \(.nn) sends the merger")
         elif $s == "changes requested" or $s == "checks failed" then step("agent"; "fix"; "PR #\(.pr.number): \($s)")
         else step("none"; "wait"; "PR #\(.pr.number): \($s)") end)
    elif .col == "human" then
      (if $off and .pushed != "" then step("daniel"; "merge"; "pushed \(.pushed): merge it on the forge")
       elif $who == "me" then step("daniel"; "review"; "yours: checked, ship it")
       elif $pol.night_shift == true and $pol.require_human_before_pr == false and (.checks.review // "") == "ok"
         then step("hub"; "pr"; "review passed; night shift ships it with no human gate")
       else step("daniel"; "review"; .note) end)
    elif .col == "review" then step("agent"; "review"; .note)
    elif .col == "working" then
      (if $who == "me" then step("daniel"; "work"; .note) else step("agent"; "build"; .note) end)
    elif .col == "needs" then
      (if (.note | startswith("asks: ")) then step("daniel"; "answer"; "asks: \(ask.q | gsub("\\s+"; " ") | .[0:200])")
       elif .state == "blocked" then step("daniel"; "answer"; "agent at a dialog")
       elif .state == "gone" then step("hub"; "resume"; .note)
       else step("daniel"; "answer"; .note) end)
    else step("none"; "wait"; .note) end;

.tickets |= map(. + {next: (next_of($pol) + {since: ($since[.nn] // null)})})
