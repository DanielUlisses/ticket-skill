# The short loop

A board the project coordinator runs on its own, through the box runner (`devbox-run`, from devboxes),
with no board session, no `tk.sh` state machine, no gates, no launchers, no Herdr and no PR creator.
Why: [ADR 0012](../adr/0012-the-short-loop.md). The coordinator's instructions for it:
`skills/implement-tickets/templates/short-loop-section.md`.

## Turning a board over

```
cd <repo> && skills/implement-tickets/scripts/loop.sh adopt <board>     # writes .scratch/<board>/loop
```

From then on `tk.sh` refuses to act on it (launch, resume, pr, merge, answer, …) and the coordinator's
next start carries the short-loop section and may run `loop.sh` without a prompt. Delete the file to give
the board back to the old loop; nothing else changes. With tk-hub driving the board, turn its
`night_shift` off, or the hub keeps trying launches the board refuses.

`adopt` refuses while a ticket's `**Agent:**` is still a Herdr agent (`herdr agent list`): once marked,
tk.sh would refuse that agent's PR and merge, and in place (`~/work`) its worktree is this loop's own
path, so the ticket would read `stopped` and a start would put a second agent in it. Let it finish or close
it, then adopt; `--force` adopts anyway. After `adopt`, and in `status`, a ticket whose old agent still
runs reads `elsewhere`.

`loop.sh take <board> <NN>` takes over a ticket the old loop left mid-work once its agent is gone: a start
in its worktree as it stands (the `stopped` path), told that the old loop's phase and report files aren't
its own. The old conversation is not resumed: its brief names the old loop's files and gates, and with the
agent user on its transcript is another user's. A ticket in review needs nothing: the loop reads its PR.

`loop.sh start` writes the ticket's run-state lines as `tk.sh` does (`**Status:** in-progress`,
`**Branch:**`, `**Worktree:**`, …, no `**Agent:**`), so if the board goes back to the old loop,
`tk.sh resume` reads the ticket as in progress with its agent gone and picks it up.

For the pilot, the board runs in a separate clone with only its files copied in, so an old-loop agent
can't share a worktree with a new one (`loop.sh` ignores a copied `**Worktree:**` line and works beside
its own checkout, `../<repo>--<branch>`).

With the box's agent user on (`agent_user`, `lib/ticket-agent.sh`), `loop.sh start` prepares the
worktree for it (`agent_prepare_worktree`: group `tkwork`, git metadata not writable), puts the brief,
report and questions files in the shared state dir (`agent_state_file`, linked from the ticket's
directory, where the loop reads them) and starts the session with the runner's `--agent`, which runs
claude as `<user>-agent` through devboxes' wrapper (needs devbox-run with `--agent`, devboxes #64). The
brief gets the agent-user note. Off, sessions run as the box user, as before.

## States

A ticket that has landed (its branch is in the base by git, or a merged PR from it, asked of the forge here and of the runner's `status --pr`) is `done`, and `status` then records the one fact other boards need: `**Status:** resolved — merged into <base> as <sha or PR> on <date>` in the ticket file, as `tk.sh resolve` writes it, because a cross-repo blocker (`<repo>:<NN>`) is read from that line. It also stops the ticket's finished session (`devbox-run stop`), unless that session is still working.

Derived on every call, in this order: `dropped`, `done` (the ticket says resolved, or the branch landed),
`yours` (`**Owner:** me`), `blocked` (a `Blocked by` ticket not done, cross-board refs included), `elsewhere` (in progress in another checkout: its `**Worktree:**` exists there, or its branch is nowhere here),
`approved` / `changes` / `review` (an open PR, by its review; GitHub's latest reviews when no rule makes
`reviewDecision` say), `working` (the runner session is working, or its turn ended while a subagent it started still runs: the pane footer names one, or a subagent transcript changed in the last two minutes), `asking` (a blocking question with no
answer), `built` (a report beside real work: changes or commits), `idle` (a live session at its prompt
with no report), `stopped` (a worktree or branch, no live session), `ready`.

`loop.sh status <board> --json` gives `{board, repo, base, forge, max_parallel, running, next, tickets}`;
each ticket carries its state, why, branch, worktree, session, PR, report and questions paths. It is
what the new daemon reports to the hub.

## Watching

No daemon writes events for a short-loop board. The coordinator's inbox watcher (`coordinator-inbox.sh wait`)
runs `loop.sh -C <repo> watch <board> --inbox <folder>/inbox` on each of its project's short-loop boards every
`TICKET_PCOORD_LOOP_POLL_S` seconds (default 120), and the events land in the inbox like the daemon's. `watch`
derives every ticket as `status` does and compares with the last pass (`seen.json` beside the tickets' files: a
notification cursor, not ticket state; deleting it only makes the next pass record again):

| Event | When |
|---|---|
| `start` | a ticket becomes `ready` from `blocked`, or a new ticket appears `ready` |
| `built` | it becomes `built`, or its report is rewritten while `built` |
| `question` | its count of open blocking questions rises |
| `idle` | `idle` two passes in a row |
| `resume` | `stopped` two passes in a row, coming from working, idle, asking or built |
| `changes`, `approved` | the PR's review says so |
| `fixed` | a newer report while the PR is in `review` or `changes` |
| `landed` | `done` from anything but dropped |
| `message` | a thread added a message to its `messages.json` (below) |

Threads talk to each other through it. Each thread's brief (`templates/thread-prompt.md`, *The other threads*)
lists the board's other open tickets as it started, and a thread that depends on another appends
`{"to": "<NN>|coordinator", "text": …}` to its own `messages.json` (beside its report; a shared copy with the agent
user on). A pass delivers each new entry into the target's session through `tk-relay` (the slim daemon's,
`TICKET_RELAY` overrides) with `TK_RELAY_FROM` set to the sender's session, as `Thread NN (<title>): …`, so the hub
shows it on both threads; without tk-relay it falls back to `devbox-run say` under the same first line,
`[relay from <session>]`, which only the receiver's thread shows. `loop.sh say` and `answer` relay the same way, the
sender being the session whose folder the caller runs in (the coordinator's, before `-C`). A pass hands every one to the coordinator as a `message` event saying whether it was
delivered (a target with no live session, or at a dialog, is not: the coordinator passes it on). `seen.json` counts
each file's entries, so a message goes once; a fresh start keeps the old file aside and counts from zero. No thread
ever edits another's worktree.

The first pass on a board records only. A pass whose `devbox-run status` or forge listing failed records and
sends nothing (exit 3), since a failed lookup reads as "no session" or "no PR"; the watcher notes a failure in
`journal.log` at most hourly. One pass per board at a time (`flock`). The runner is asked once per pass for
every session, not once per ticket.

## The coordinator under the runner

`coordinator.sh --runner <project>` starts the coordinator as the runner session `pc-<project>` in its folder:
detached, no Herdr, no terminal, the folder-trust dialog answered and the first prompt typed in by the runner.
`--runner --resume` resumes its conversation with a note to start the inbox watcher again; a reboot brings it
back through devboxes' `devbox-run-resume.service` (no note: the inbox hook then reminds it, on his next
message, that the watcher is not running). Nothing recycles it. The inbox hook goes in the folder's
`.claude/settings.local.json`, not `--settings`, because the runner gives a command that passes its own
`--settings` none of its hooks (turn, notice, session id after `/clear`). `--json --runner` prints what tk-hub's
slim daemon needs to start it itself: `{project, dir, prompt, session, resume_note, args}`.

## Files

Per ticket, outside the repo: `~/.local/state/ticket-skill/<repo>/loop/<board>/<NN>/` holds `brief.md`
(the rendered `templates/thread-prompt.md`), `report.md` and `questions.json`. A start moves an earlier
report and questions aside (answered questions are kept). Answers still go to the ticket's `## Answers`
and the repo's answers ledger.

## Settings

`TICKET_RUNNER` (default `devbox-run`), `TICKET_PR_REVIEWER` (the reviewer requested on the draft PR;
GitHub refuses the PR's own author), `TICKET_PR_ASSIGNEE` (GitHub, default `@me`),
`TICKET_LOOP_PERMISSION_MODE` (default `bypassPermissions`; commit, push, stash, reset, rebase, checkout,
switch and gh/az PR commands stay disallowed). Models and efforts come from `config/models.env` as for
the old loop: the session coordinates on `TICKET_COORD_*`, its implementer on the ticket's Suggested
lines, the reviewer on `TICKET_REVIEW_*` (`_UNTESTED` for a Seams `None` ticket).

## Checking it

No suite: exercise it on a throwaway repo with a fake `devbox-run` and `gh` on PATH (the PR that added
it lists the runs).
