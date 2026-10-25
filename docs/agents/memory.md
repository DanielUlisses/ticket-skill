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
<main repo root>/.scratch/project-memory.md
```

One file, per repo, plain Markdown, no schema, read and edited by hand. `.scratch/` is
gitignored, so the file is **never committed**: memory is never written inside tracked
code (ADR `0006-project-memory-in-scratch.md`).

Three things follow from that path:

- **It is read from the *main checkout*, never from the ticket's worktree.** The
  launcher already resolves the main repo root (`git worktree list --porcelain`, first
  entry) to decide where to branch from, and memory is read from the same place. So every
  ticket — including one launched from inside another ticket's worktree — is briefed with
  the same, canonical memory.
- **`/sweep-tickets` cannot take it with it.** That skill removes worktrees and branches
  and never touches the main checkout's `.scratch`, so memory survives every sweep.
- **There is no merge gate.** Being ignored, the file is not reviewed in a diff. The
  developer gate is the approval in `tk.sh retro-apply` (or the hub's memory ticket), and
  then the developer's own edit. The cost: memory is per clone and per box — it does not
  travel with the repo, and two clones of one repo keep separate memories.

`TICKET_MEMORY_FILE` overrides the path for one launch — absolute, or relative to the
main repo root. It exists for trying something out; the default is the convention.

**Transition (one release).** If `.scratch/project-memory.md` is absent and the old
`docs/agents/project-memory.md` exists, the launcher reads the old file and logs one line
saying to move it. It never creates or moves files itself. If the repo's `.gitignore`
doesn't ignore `.scratch/`, the launcher logs a warning that memory there could be
committed, and does nothing else.

### Absent is a supported state

A repo with no `.scratch/project-memory.md` launches **exactly** as it did before this
existed: no heading, no placeholder, no mention of memory anywhere in the prompt. The
same is true of a file that is empty, whitespace-only, or unreadable. The launcher logs
one line saying which it found and carries on; nothing fails, and nothing is created for
you. Most repos will never have one, and that is fine.

## What goes in it

Short and factual. **It is paid for on every single launch**, so every line has to earn
its tokens against everything else competing for that context. A page is generous; the
launcher warns above 8 KiB (`MEMORY_WARN_BYTES`) and never truncate.

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
appear, and copy that shape rather than inventing one.

## How injection works

The launcher reaches this through `lib/ticket-launcher.sh`, which
`skills/ticket/scripts/launch.sh` sources.
Right before rendering the prompt it resolves the file against the main repo root, and —
if it has any content — wraps it in a `## Project memory` heading with a short preamble and
substitutes it for the `{{PROJECT_MEMORY}}` placeholder in the template. Absent or blank
substitutes nothing, and takes the placeholder's own blank line with it.

| Skill | Template | Reaches it via |
|---|---|---|
| `/ticket` | `skills/ticket/templates/ticket-agent-prompt.md` (`ticket-doc-prompt.md` for `--doc`) | its own `launch.sh` |
| `/implement-tickets` (the board session) | the same as `/ticket` | `tk.sh launch` runs `/ticket`'s `launch.sh` |

The template is the only part of this `launch.sh` decides for itself; the
resolution and the wrapping are the shared library's.

`/implement-tickets` gets injection for free, because it ships no launcher of its own.

The preamble tells the agent three things the memory file itself shouldn't have to
repeat: that it is starting knowledge rather than orders, that the code in front of it
wins wherever the two disagree, and that it must not edit the file.

**Memory is read once per launch, not once per round.** The board session runs a
digest at the top of every coordination round, and memory is emphatically not part of it
— that digest is six fields per ticket and must stay cheap enough to run every round.
Memory is prose, it is read once, by the launcher, at the moment a worktree is created.

### The coordinator has to pass it on

Since ADR 0002, `/ticket` briefs a coordinator that delegates the
actual work to the `ticket-*` subagents. Those subagents get
a fresh context and **never see the launcher's prompt** — injection reaches the
coordinator and stops there. So the coordinator's template tells it, at the Phase 2
hand-off, to pass on whatever in the memory bears on the files the implementer is about to
touch. Review and testing aren't given it: they read the diff and run the checks, and
neither was worth the tokens; nor are the Haiku scouts, researchers and criteria checkers,
which answer one narrow question each. If that turns out wrong, the verify phases of
`skills/ticket/templates/ticket-agent-prompt.md` and `ticket-doc-prompt.md`
are where it would change.

The scouts, researchers and criteria checkers don't close with `## Remember` — their whole
report is a fact list for the coordinator, which is free to carry a durable one forward.

## How capture works

Every agent in the workflow — the one the launcher starts, and each `ticket-*` subagent it
delegates to — is asked to close its report with a **`## Remember`** section:
durable, non-obvious facts about the repo, one line each, phrased as facts about the repo
rather than as a story about the session. `Nothing durable this ticket.` is an explicitly
blessed answer — a padded list is worse than an empty one, because a human has to read it.

The agent **reports; it never writes**. It is told not to touch the memory file; the file
lives in the main checkout's `.scratch`, which a worktree does not have, and the launcher
reads only that copy. What the repo remembers is the developer's call, not the agent's:
the approval in `tk.sh retro-apply`, then the developer's own edit.

### Folding a lesson back in

When you read a ticket's report and a `## Remember` bullet is worth keeping:

1. Judge it. Most bullets aren't worth keeping — the agent has seen one ticket, and
   "this surprised me" is not the same as "this is true of the repo". Keep what you'd
   want to tell the next person on their first day.
2. Edit `.scratch/project-memory.md` in the main checkout. It is ignored, so there is
   nothing to commit and a ticket's worktree is the wrong place for it. Create the file
   if it doesn't exist yet; nothing creates it for you.
3. Rewrite the bullet in the file's voice. An agent's phrasing is aimed at you, once;
   the file is aimed at every future launch. Shorter, flatter, no narrative.
4. Prune while you're there. This is the only moment anyone looks at the file with fresh
   eyes: delete what has gone stale, and merge what is now said twice. The file is only
   valuable while it stays short.

The next launch is briefed with it. What no agent may do is decide on its own.

## Retro results

Approved lessons from past retros live in `.scratch/<board>/retro-results.md`, written by
`tk.sh retro-apply` from the developer's marks, not by this file's curator (the flow:
`docs/agents/retro.md`). They reach a ticket by **pointer**, never by copy:
at launch `resolve_retro_results` (`lib/ticket-launcher.sh`) globs
`<main checkout>/.scratch/*/retro-results.md` — the main checkout, as for project memory,
since a worktree has no `.scratch/` — and the `{{RETRO_RESULTS}}` placeholder (beside
`{{PROJECT_MEMORY}}` in both templates, `/ticket`'s code and doc briefs) becomes a
`## Retro results` block with one absolute-path line per file, telling the agent to read it
if it exists, follow approved items that bear on its work, and never edit it. The `/ticket`
coordinator passes the relevant items on to the implementer; the `/ticket` planner reads the
files before grilling. No file found: the placeholder and its blank line vanish, the prompt is
unchanged, and one log line says so. The launch summary reports `RETRO_RESULTS=<n> file(s)` or
`none (...)`.

## Adding memory to a repo that has none

Write `.scratch/project-memory.md` (in the main checkout) with three bullets you are
sure of. Injection needs nothing else — no install step, no config. The next launch's
summary line confirms it: `PROJECT_MEMORY=.scratch/project-memory.md (<n> bytes)`, where
`none (…)` means the file isn't where the launcher looked.

## Related

- `docs/agents/domain.md` — `CONTEXT.md` and `docs/adr/`, which an agent reads *during*
  a ticket. Memory is what it's told *before* one, and the two shouldn't repeat each other.
- `docs/agents/models.md` — the other cross-skill knob. Note the deliberate difference:
  models are **per-machine** config installed next to the skills, while memory is
  **per-repo** content that lives in the repo and travels with it.
