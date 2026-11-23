# 0012 — The short loop: the project coordinator runs a board through the box runner

- **Status:** Accepted for a pilot on one board, beside the old loop
- **Date:** 2026-11-23
- **Deciders:** Daniel Ulisses
- **Replaces, on a board that opts in:** [0003](0003-planner-and-board-sessions.md) (the board session), [0004](0004-haiku-board-session.md) (tk.sh as its hands), the five merge gates, the launchers, Herdr and the PR creator

## Context

The friction of the last weeks came from the execution layer, not the hub: Herdr failing to start
sessions, tickets in a wrong status, script bugs on merge and PR, and the ticket's own agent doing the
PR agent's work. The tk-hub rebuild (decision of 2026-11-23) keeps the on-box project coordinator as
the one thing the developer talks to and cuts the rest down.

## Decision

- **Opt in per board.** `.scratch/<board>/loop` holding `short` (`loop.sh adopt`). `loop.sh` refuses
  any other board; `tk.sh`'s acting verbs (launch, resume, rebase, pr, push, merge, resolve, say,
  answer, batch, deployed, rescope) refuse a marked one. Reading verbs still work. The two loops never
  act on the same board, so the old one keeps running everywhere else unchanged.
- **State is derived, never stored.** `loop.sh status` reads the ticket file (resolved, dropped,
  `**Owner:** me`, `Blocked by`), git (branch, worktree, landed), the forge (the PR, its review) and the
  box runner (`devbox-run status`: alive, working), plus the report and questions files the ticket's
  session writes. The one line written is `**Status:** resolved` for the developer's own ticket (a gate),
  on his word, because no fact shows it.
- **Sessions through the runner.** `loop.sh start` makes the worktree and starts one detached Claude
  Code session per ticket with `devbox-run start`; say, log and resume go through it too. The session
  keeps the old per-ticket shape (Haiku scouts and testers, the implementer at the ticket's model, the
  reviewer, at most two fix rounds) and never commits, pushes or opens a PR.
- **The coordinator opens a draft PR.** `loop.sh pr` commits the worktree, pushes the branch and opens a
  draft PR with the developer as reviewer, refusing attribution lines, model names, internal ticket
  numbers, risky paths and secret-looking text. `loop.sh merge` runs only on his word: approved on the
  forge (or his words, where the forge cannot take his approval because he authored the PR), checks
  green, no conflict.
- **The coordinator's brief is derived too.** `coordinator.sh` appends the short-loop section to the
  brief when any of the project's boards is marked, and pre-allows `loop.sh`; the hub's daemon starts it
  unchanged.

## Consequences

- The five gates are gone on a short-loop board. The reviewer subagent and the developer's review of the
  draft PR replace them; a gate comes back as a check `loop.sh merge` runs if the pilot shows a need.
- No phase file: the hub sees `working`, `idle` (at its prompt with no report: a limit or a dialog) or
  `built`, not the session's own phase.
- A board copied from another checkout can name that checkout's worktrees in `**Worktree:**` lines:
  `loop.sh` ignores them and always works beside its own checkout.
- Removing the old loop is a later phase, after the pilot passes.
- Nothing pushes events for a short-loop board: the coordinator's own inbox watcher runs `loop.sh watch`, which
  turns state changes into inbox events (docs/agents/short-loop.md, Watching). The coordinator itself runs as a
  runner session (`coordinator.sh --runner`), so the box needs neither Herdr nor the old daemon for the loop.
