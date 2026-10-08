# 0003 — Split the developer's session: an Opus planner, a cheap board session

- **Status:** Accepted
- **Date:** 2026-10-08
- **Deciders:** Daniel Ulisses
- **Builds on:** [0002](0002-model-tiers-and-agent-roster.md), which tiered the *launched* sessions; this tiers the one the developer sits in

## Context

The developer's own session did four jobs, start to finish of a feature:

| Job | What it takes |
|---|---|
| Grill the idea, break it into tickets | judgement, and a shared understanding built over a long interview |
| Launch waves | the digest, the frontier, the launcher — mechanical |
| Merge PRs once reviewed | checking gates, then one command — mechanical |
| Pass messages to ticket agents | routing the developer's words — mechanical |

All four ran on the model the first one needs, in a context that kept growing with the interview
long after the interview mattered. A model set in a skill's frontmatter can't fix that: Claude
Code applies a skill's `model:` for the rest of the invoking turn only, and the board is driven
across many turns ("03 is merged", "tell 05 …").

## Decision

Two sessions:

- **Planner** — `/ticket`, on the planning model (the developer's choice; Opus). Ends after the
  tickets are written, by default: Phase 3 offers **Hand off to a board session** first, which
  prints `claude --model <m> --effort <e> "/implement-tickets <board>"` from the new
  `BOARD=` line of `launch.sh defaults`. *Launch here* is still there for one-offs.
- **Board** — `/implement-tickets`, on `TICKET_BOARD_MODEL`/`TICKET_BOARD_EFFORT`, default
  `sonnet @ low`. It already rebuilt its state from the board every round, so it starts fresh
  with nothing lost. It gains two jobs:
  - **Merging on request** — only when the developer names the ticket, behind five gates (open
    PR on the ticket's branch, not draft and on the board's base, `MERGEABLE`, checks green,
    review approved or not required), with the repo's merge method, never `--admin`, never
    `--delete-branch`. "Merge everything ready" lists the candidates and asks once.
  - **Relaying** — the developer's words to a ticket's agent, verbatim under one provenance
    line, gated on the agent's state (never into a `blocked` dialog).

The board session is told what it is not: when a request needs design judgement, it says so and
points at `/ticket <id> …` in a planner session, which appends to the same board.

## Why Sonnet, not Haiku, for now

Haiku 5.5 would be ~20× cheaper again, and the work is mechanical — but today the mechanics live
in 400+ lines of prose the model has to execute faithfully: the empty-branch guard, the
squash-merge leg, lenient blocker parsing, the merge gates. Those are the steps a low-effort
small model skips, and their failures (closing an unmerged ticket, launching against unmerged
code, merging past a red check) are not cheap. The fix is to take the mechanics out of the model:

## Follow-up: `digest.sh`, then Haiku

Move Phase 1's three reads and the frontier into `skills/implement-tickets/scripts/digest.sh`,
the way `/sweep-tickets` already has `sweep.sh`, printing the one-line-per-ticket digest — and a
`merge-gates.sh <NN>` that prints the five gates as pass/fail. The model then only decides and
talks, and `TICKET_BOARD_MODEL=haiku` becomes a one-line change worth trying. It also makes every
round cheaper and more reliable on any model.
