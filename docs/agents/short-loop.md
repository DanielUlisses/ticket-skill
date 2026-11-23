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

For the pilot, the board runs in a separate clone with only its files copied in, so an old-loop agent
can't share a worktree with a new one (`loop.sh` ignores a copied `**Worktree:**` line and works beside
its own checkout, `../<repo>--<branch>`). The agent user must be off: the runner runs sessions as the box
user.

## States

Derived on every call, in this order: `dropped`, `done` (the ticket says resolved, or the branch landed),
`yours` (`**Owner:** me`), `blocked` (a `Blocked by` ticket not done, cross-board refs included), `elsewhere` (in progress in another checkout: its `**Worktree:**` exists there, or its branch is nowhere here),
`approved` / `changes` / `review` (an open PR, by its review; GitHub's latest reviews when no rule makes
`reviewDecision` say), `working` (the runner session is working), `asking` (a blocking question with no
answer), `built` (a report beside real work: changes or commits), `idle` (a live session at its prompt
with no report), `stopped` (a worktree or branch, no live session), `ready`.

`loop.sh status <board> --json` gives `{board, repo, base, forge, max_parallel, running, next, tickets}`;
each ticket carries its state, why, branch, worktree, session, PR, report and questions paths. It is
what the new daemon reports to the hub.

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
