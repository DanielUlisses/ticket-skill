# 0009 — The developer's tickets flow through the board's columns, with a helper session

- **Status:** Accepted
- **Date:** 2026-11-04
- **Deciders:** Daniel Ulisses
- **Builds on:** [0007](0007-doc-tickets-on-the-board.md), `docs/agents/contracts.md` (`**Owner:** me`)

`**Owner:** me` marked a ticket the developer does by hand. Until now the board treated it as an
interruption, not as work: once its blockers resolved it sat in **needs you** (`yours to do`) next to
agents' dialogs, `tk.sh launch` refused it outright, and the only way out was
`tk.sh resolve --no-code`. A ticket of the developer's that needs code (Helm values, a pipeline
change they want to make themselves) had no worktree, no checks and no PR path.

## 1. Same columns

A ticket of the developer's moves like an agent's (`board_rows_` in `tk.sh`):

| state | column | note |
|---|---|---|
| open, blockers open | blocked | waiting on … |
| open, ready | backlog | `yours — start it with a helper` |
| in progress, helper working (or closed, or at a dialog) | working | `yours + helper`, `yours — no helper running`, `yours — helper at a dialog` |
| in progress, phase `verifying`/`reviewing`/`fixing`/`reporting` | review | the phase |
| in progress, phase `done` | human | `yours — checked` |
| PR open / landed / resolved | pr / done | as any ticket |

**Needs you** keeps only what an agent or the board asks: an agent's dialog, an agent gone, a landing
that can't be told, a ticket on another repo's board. A helper at a dialog or closed is the
developer's own session, so it stays in working. The digest still leaves these tickets out of
`FRONTIER` and prints `ACTION yours NN` for a ready one; it prints no `review`/`dialog`/`orphan`
action for one in progress, and one `ACTION yours` when its helper closes. The status board draws
them in magenta (tk-hub's plum) with `· yours`.

## 2. Start opens a helper, and only the developer starts it

`tk.sh launch <board> <NN> --helper` is the one way a ticket of the developer's starts. Without
`--helper` it is refused, and `--helper` on an agent's ticket is refused too. The flag stands for
the developer's word: the board session passes it only for a ticket the developer named in their
own message (never in a wave or "start all"), and tk-hub's scheduler and Frontier never pass it, so
nothing starts one alone.

`--helper` reaches the launcher (`lib/ticket-launcher.sh`), which renders
`skills/ticket/templates/ticket-helper-prompt.md` instead of the agent brief. The worktree, tabs,
account, catalog skills and Remote Control are the same as any ticket's. The session differs:

- it runs on the ticket's model and effort (the launch question's answer), not the coordinator's;
  there is no coordinator and no `ticket-implementer` in its roster;
- it starts in `TICKET_HELPER_PERMISSION_MODE` (default `acceptEdits`), since the developer is there;
- it waits: a short summary of the ticket, a suggested first step, a question.

The run-state block is the one every launch writes, so `tk.sh export` carries the ticket's branch,
worktree, agent and transcript, plus `owner: "me"` as before.

## 3. Ready for review, then the normal path

When the developer says it's ready, the helper runs the criteria checkers, the testers and the
reviewer (or doc reviewer) where there is a change, fixes only what the developer agrees to, writes
the report (`## Missing contracts`, `## Remember`) to the report file, and sets the phase to `done`.
A change then ships as any ticket's does (`tk.sh pr`, `push`, `merge`, on the developer's word); a
ticket with no change is resolved with `tk.sh resolve --no-code "<what was done>"`. Resolving
unblocks the tickets waiting on it.

## Consequences

- tk-hub sees these tickets in `backlog`, `working`, `review` and `human` instead of `needs`. Its
  scheduler and Frontier launch `backlog` tickets; `tk.sh launch` refuses them there, and the hub
  side (W8b) has to leave `owner: "me"` tickets out of both, keep the developer's task for them, and
  offer Start (a launch with `--helper`) and resolve-with-a-note from `backlog`. Install this on the
  boxes together with that change.
- A ticket of the developer's done entirely by hand needs no helper: `resolve --no-code` from
  `backlog` works as before.
