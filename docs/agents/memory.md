# Project memory

A per-repo file of accumulated, hand-curated knowledge, folded into the brief of every
ticket the skills launch — so a ticket starts knowing the repo instead of rediscovering
it. Repos here are long-running and tickets are feature-shaped requests against them,
which is what makes the knowledge compound on the ordinary path rather than only on big
efforts (ADR `0001-herdr-projects-evaluation.md`, *What we take*, item 2).

Two halves, and they are deliberately asymmetric:

- **Injection is automatic.** Every launch reads the file and puts it in the prompt.
- **Capture is not.** An agent *reports* durable lessons; a human decides what the repo
  remembers. Nothing an agent writes reaches memory on its own.

## Where it lives

```
<main repo root>/docs/agents/project-memory.md
```

One file, per repo, in the repo — plain Markdown, no schema, read and edited by hand.

Three things follow from that path, and each was the reason for choosing it:

- **It is read from the *main checkout*, never from the ticket's worktree.** The
  launchers already resolve the main repo root (`git worktree list --porcelain`, first
  entry) to decide where to branch from, and memory is read from the same place. So every
  ticket — including one launched from inside another ticket's worktree — is briefed with
  the same, canonical memory.
- **`/sweep-tickets` cannot take it with it.** That skill removes worktrees and branches.
  The main checkout is not either of those, so memory survives every sweep by
  construction rather than by a rule someone has to remember.
- **The developer gate is the merge.** The file is tracked by git like anything else, so
  a lesson only reaches future tickets once it has been reviewed and merged into the base
  branch. That is the same gate every other change in these repos passes through, which
  is why capture needs no gate of its own.

`TICKET_MEMORY_FILE` overrides the path for one launch — absolute, or relative to the
main repo root. It exists for trying something out; the default is the convention, and a
repo that moves its memory permanently should say so in its `CLAUDE.md`.

### Absent is a supported state

A repo with no `docs/agents/project-memory.md` launches **exactly** as it did before this
existed: no heading, no placeholder, no mention of memory anywhere in the prompt. The
same is true of a file that is empty, whitespace-only, or unreadable. The launcher logs
one line saying which it found and carries on; nothing fails, and nothing is created for
you. Most repos will never have one, and that is fine.

## What goes in it

Short and factual. **It is paid for on every single launch**, so every line has to earn
its tokens against everything else competing for that context. A page is generous; the
launchers warn above 8 KiB (`MEMORY_WARN_BYTES`) and never truncate.

Worth keeping:

- **Layout** — where things actually are, when the tree doesn't make it obvious.
- **Conventions** the repo follows but never states.
- **Hard-won facts** — a command that only works a certain way, a dependency that behaves
  unexpectedly, a file that looks authoritative and isn't.
- **Traps** that have already cost someone an hour.

Not worth keeping:

- Anything `CLAUDE.md`, `CONTEXT.md` or the ADRs already say. Memory is for what isn't
  written down yet; duplicating those costs tokens twice and drifts out of sync.
- What a particular ticket did. Git history holds that, and far better.
- Anything true only of one branch, or that the code itself states plainly.
- Aspirations, style opinions and "we should probably…". Facts only.

Headings are free-form. `Layout` / `Conventions` / `Hard-won facts` is what tends to
appear, and this repo's own `docs/agents/project-memory.md` is the worked example — copy
its shape rather than inventing one.

## How injection works

Both launchers (`skills/small-ticket/scripts/launch.sh` and
`skills/ticket/scripts/launch.sh`) do the same thing, right before rendering the prompt:
resolve the file against the main repo root, and — if it has any content — wrap it in a
`## Project memory` heading with a short preamble and substitute it for the
`{{PROJECT_MEMORY}}` placeholder in the template. Absent or blank substitutes nothing,
and takes the placeholder's own blank line with it.

| Skill | Template | Reaches it via |
|---|---|---|
| `/small-ticket` | `skills/small-ticket/templates/agent-prompt.md` | its own `launch.sh` |
| `/ticket` | `skills/ticket/templates/ticket-agent-prompt.md` | its own `launch.sh` |
| `/implement-tickets` | the same as `/ticket` | it reuses `/ticket`'s `launch.sh` |

`/implement-tickets` gets injection for free, because it ships no launcher of its own.

The preamble tells the agent three things the memory file itself shouldn't have to
repeat: that it is starting knowledge rather than orders, that the code in front of it
wins wherever the two disagree, and that it must not edit the file.

**Memory is read once per launch, not once per round.** `/implement-tickets` runs a
digest at the top of every coordination round, and memory is emphatically not part of it
— that digest is six fields per ticket and must stay cheap enough to run every round.
Memory is prose, it is read once, by the launcher, at the moment a worktree is created.

### In `/small-ticket`, the orchestrator has to pass it on

`/small-ticket` briefs an orchestrator that delegates the actual work to the
`ticket-implementer`, `ticket-reviewer` and `ticket-tester` subagents. Those subagents get
a fresh context and **never see the launcher's prompt** — injection reaches the
orchestrator and stops there. So the orchestrator's template tells it, at the Phase 2
hand-off, to pass on whatever in the memory bears on the files the implementer is about to
touch. Review and testing aren't given it: they read the diff and run the checks, and
neither was worth the tokens. If that turns out wrong, Phase 3 and 4 of
`skills/small-ticket/templates/agent-prompt.md` are where it would change.

## How capture works

Every agent in the workflow — the one the launcher starts, and each `ticket-*` subagent it
delegates to — is asked to close its report with a **`## Remember`** section:
durable, non-obvious facts about the repo, one line each, phrased as facts about the repo
rather than as a story about the session. `Nothing durable this ticket.` is an explicitly
blessed answer — a padded list is worse than an empty one, because a human has to read it.

The agent **reports; it never writes**. It is told not to touch the memory file — and
because the file is tracked, its worktree does hold a copy, so the real gate isn't the
instruction: the launcher reads the **main checkout's** copy and never the worktree's.
An agent that edited its own copy anyway would change nothing for anyone else; that edit
is simply an ordinary line in the diff you were going to review. What the repo remembers
is the developer's call, not the agent's, and it takes a merge to become so.

### Folding a lesson back in

When you read a ticket's report and a `## Remember` bullet is worth keeping:

1. Judge it. Most bullets aren't worth keeping — the agent has seen one ticket, and
   "this surprised me" is not the same as "this is true of the repo". Keep what you'd
   want to tell the next person on their first day.
2. Edit `docs/agents/project-memory.md` — either in the main checkout as an ordinary
   change, or in that ticket's worktree so it rides along in the diff you are already
   reviewing. The second is usually less work and keeps the lesson beside the change that
   taught it. Create the file if it doesn't exist yet; nothing creates it for you.
3. Rewrite the bullet in the file's voice. An agent's phrasing is aimed at you, once;
   the file is aimed at every future launch. Shorter, flatter, no narrative.
4. Prune while you're there. This is the only moment anyone looks at the file with fresh
   eyes: delete what has gone stale, and merge what is now said twice. The file is only
   valuable while it stays short.
5. Commit and merge it. The next launch off that base branch is briefed with it.

If you'd rather the ticket's own agent make the edit, ask it to — the edit then lands in
that ticket's diff and you review it like any other change. What it must not do is decide
on its own.

## Adding memory to a repo that has none

Write `docs/agents/project-memory.md` (the path above, not the repo root) with three
bullets you are sure of, and commit it to the base branch. Injection needs nothing else —
no install step, no config, no per-machine file. The next launch's summary line confirms
it: `PROJECT_MEMORY=docs/agents/project-memory.md (<n> bytes)`, where `none (…)` means the
file isn't where the launcher looked.

## Related

- `docs/agents/domain.md` — `CONTEXT.md` and `docs/adr/`, which an agent reads *during*
  a ticket. Memory is what it's told *before* one, and the two shouldn't repeat each other.
- `docs/agents/models.md` — the other cross-skill knob. Note the deliberate difference:
  models are **per-machine** config installed next to the skills, while memory is
  **per-repo** content that lives in the repo and travels with it.
