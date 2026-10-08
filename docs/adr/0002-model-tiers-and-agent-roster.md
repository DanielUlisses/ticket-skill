# 0002 — Tier the roster: an Opus coordinator, a per-ticket implementer, a Haiku swarm

- **Status:** Accepted (smoke test of `--agents` through `herdr agent start` pending — see *Risks*)
- **Date:** 2026-10-08
- **Deciders:** Daniel Ulisses
- **Subject:** which model and effort each role in `/ticket`, `/small-ticket` and `/implement-tickets` runs on, now that Sonnet 5.5 and Haiku 5.5 exist

## Context

Until now the workflows had three roles and, in practice, one setting. `/ticket`'s launched
session implemented *and* reviewed the ticket in one process at one model and one effort, so
choosing Sonnet or `low` for a cheap ticket silently bought a cheaper review with it
(`models.md` called this "a documented asymmetry"). Discovery — finding the code, the callers,
the conventions, the test command — was done by that same Opus session, in its own context.

Three things changed:

| Model | $/MTok in / out | Effort levels | Where it fits |
|---|---|---|---|
| Opus 5.5 | 4 / 20 | `low`–`max`, default `medium` | judgement: planning, design-uncertain code, review |
| Sonnet 5.5 | 2 / 10 | `low`–`max`, default `high` (recalibrated) | well-specified code that follows an existing pattern |
| Haiku 5.5 | 0.10 / 0.50 | `low`–`max`, default `medium` | narrow, factual, parallel: find, run, check |

Haiku is **1/40th** of Opus per token. A fan-out of five Haiku scouts costs less than one Opus
search that reads the same files — and its output lands in the coordinator's context as five
short fact lists rather than as the files themselves.

And Claude Code grew the two features the old design said were impossible:

- a subagent definition takes an **`effort:`** field (it used to inherit the session's), and
- `claude --agents '<json>'` defines subagents **for one session**, outranking
  `~/.claude/agents/`, with `model` and `effort` per agent.

## Decision

### The roster

| Role | Agent | Model @ effort | Why there |
|---|---|---|---|
| Coordinator (`/ticket`, `/implement-tickets` launches) | the launched session | `opus @ low` | The plan is settled. It dispatches, reads short reports and makes a handful of judgement calls (is this finding blocking? loop again or stop?). Opus at `low` keeps the judgement and drops the cost; nothing it does is long-horizon. |
| Orchestrator (`/small-ticket`) | the launched session | the ticket's | It *plans* with the developer — the one place a coordinator does need to think — so it keeps the ticket's model and effort. Scouts take the legwork off it. |
| Implementer | `ticket-implementer` | per ticket: `opus` @ `low`/`medium`/`high`, or `sonnet` | The only role whose difficulty varies ticket to ticket. |
| Reviewer | `ticket-reviewer` | `opus @ medium` | Fixed, and independent of the implementer — a ticket implemented on Sonnet is reviewed on Opus. |
| Tester | `ticket-tester` | `haiku @ low` | Run commands, read output, classify. One per check, in parallel. |
| Scout | `ticket-scout` (**new**) | `haiku @ low` | One narrow repo question, `path:line` facts, no opinions. Several in parallel. |
| Researcher | `ticket-researcher` (**new**) | `haiku @ medium` | One question about an external dependency, pinned to the repo's version, with a confidence grade. |
| Criteria checker | `ticket-criteria-checker` (**new**) | `haiku @ low` | One acceptance criterion → met / not met / can't tell, with evidence. One per criterion, in parallel. |

All of it lives in `config/models.env`. The launcher re-issues every installed
`agents/ticket-*.md` through `--agents` with the resolved model and effort, so the config is the
source and the frontmatter is a fallback.

### The ticket suggests the implementer

`/ticket` Phase 2 now writes, beside `**Suggested effort:**`:

- **`**Suggested model:**`** — `opus` where the ticket holds design judgement (a new abstraction,
  a cross-cutting change, a subtle bug, an untested seam); `sonnet` where it's well specified and
  follows a pattern the repo already has (the sixth endpoint like the other five, a batch of a
  wide refactor, wiring a settled interface through). Haiku is never the implementer.
- **`**Suggested helpers:**`** — optional; what the coordinator should fan out: the repo
  questions worth a scout, the external API worth a researcher, the checks worth splitting.

The launch question gains a third answer beside "a value" and "the default": **`As each ticket
suggests`**, a policy the session holds like any other setting. It replaces "pre-select the
highest effort in the wave", which only made sense while one effort governed the whole session.

### The `/ticket` coordinator's loop

```
Phase 0  recon     scouts ×N ─┐ researchers ×M (only for external deps)      ← parallel, Haiku
Phase 1  implement            └─▶ ticket-implementer (ticket's model/effort, TDD at named seams)
Phase 2  verify    testers ×K (one per check) + criteria checkers ×C          ← parallel, Haiku
                   then ticket-reviewer, given their tables                   ← Opus @ medium
         fix loop  blocking findings / failures / unmet criteria → implementer, re-run the delta (≤2)
Phase 3  report    + `## Remember` merged from every subagent's
```

`/small-ticket` gets the same swarm around its existing plan → implement → review → test phases.

## Alternatives considered

- **Sonnet as coordinator.** Cheaper, and a coordinator writes no code. Rejected as the default
  because the coordinator's few decisions — whether a review finding blocks, whether a third fix
  cycle is worth it, what to report as unresolved — are exactly the ones a weaker model gets
  wrong silently. It's one line in `config/models.env` to try (`TICKET_COORD_MODEL=sonnet`).
- **Haiku as an implementer option.** Rejected: an unattended ticket that lands wrong code costs a
  developer review cycle, which is worth far more than the tokens saved.
- **Effort-variant agent files** (`ticket-implementer-low`, `-medium`, …). Five near-identical
  files and a coordinator that has to pick one. `--agents` does the same per launch with no files.
- **Writing per-ticket agent files into the worktree's `.claude/agents/`.** Dirties `git status`
  in the one place this workflow promises to leave clean, and collides with repos that track
  `.claude/`.
- **Keeping `mattpocock-skills:code-review` in the `/ticket` coordinator.** It would run its
  subagents at the coordinator's `low` effort and fill the coordinator's context. Its standards
  axis moved into `ticket-reviewer`, its spec axis into `ticket-criteria-checker`.

## Consequences

- The review no longer degrades with a cheap implementer. The asymmetry section of `models.md`
  is gone.
- A ticket costs roughly: Opus-low coordinator context + implementer at the ticket's setting +
  one Opus-medium review + Haiku noise. On a Sonnet ticket the implementer — usually the largest
  line — halves.
- Seven knobs instead of four in `config/models.env`. Mitigated by grouping (one per-ticket,
  one coordinator, the fixed rest) and by `SUBAGENTS=` in every launch summary.
- The frontmatter in `agents/*.md` still has to be kept in step by hand, but now only as a
  fallback.

## Risks

- **`--agents` through Herdr.** The launcher passes ~15 KB of JSON as one argument after
  `herdr agent start ... --`. If Herdr re-quotes or types the command into the pane rather than
  exec'ing it, that can break. Verify on the first real launch (`/agents` in the pane should list
  the `ticket-*` agents with the summary's models); `TICKET_SESSION_AGENTS=0` falls back to the
  frontmatter if it does.
- **Haiku research quality.** A researcher answering about API semantics may be confidently
  wrong. Mitigated by the mandatory confidence grade and a `sonnet` re-ask on *low* for anything
  load-bearing; if it recurs, set `TICKET_RESEARCH_MODEL=sonnet`.
- **Opus at `low` as coordinator** may under-dispatch (skip scouts, accept a thin review). Watch
  the first few reports; `TICKET_COORD_EFFORT=medium` is the dial.

## Further suggestions

Taken up in [0004](0004-haiku-board-session.md): 1, 2 (as scripts rather than an agent), 5 and 6. Dropped: 3 and 4.

1. **`ticket-memory-curator` (Haiku or Sonnet @ low).** Gather the `## Remember` sections of a
   board's resolved tickets, dedupe them against `docs/agents/project-memory.md`, and propose a
   diff for the developer. `/sweep-tickets` is the natural caller. Still never writes the file.
2. **Digest on Haiku in `/implement-tickets`.** The resident coordinator re-reads the board, the
   agents and git every round — pure mechanics. A `ticket-digest` agent could return the
   one-line-per-ticket digest and keep the board's raw JSON out of the long-lived session.
3. **A breakdown sanity-checker in `/ticket` Phase 2** (Sonnet): before presenting the tickets,
   check each is a vertical slice, its blockers are acyclic, its seams exist, and its suggested
   model/effort is consistent with its description.
4. **Cross-model review for Opus tickets.** When the implementer is Opus, a Sonnet `high`
   reviewer brings a different set of blind spots for half the price. Worth an A/B on a few
   tickets before changing the default.
5. **Fable for the rare `xhigh` ticket.** Where a ticket suggests `xhigh`/`max`, the launch
   question could also offer `fable` — the model built for that work — rather than only more
   Opus effort.
6. **A wave-level research pass in `/implement-tickets`.** Tickets on one board often share
   external dependencies; one researcher round before the wave, folded into every brief, beats
   each coordinator re-asking the same question.
