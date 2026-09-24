---
name: ticket
description: Sharpens a rough task into a shared understanding, breaks it into numbered tracer-bullet tickets, then launches an unattended Herdr coordinator per chosen ticket to implement and review it, leaving everything uncommitted. For an already-defined ticket, use /small-ticket instead; for tickets already written to disk, use /implement-tickets.
argument-hint: "<task description>"
disable-model-invocation: true
allowed-tools: Bash(~/.claude/skills/ticket/scripts/launch.sh *), Bash(herdr *), Bash(git *), Bash(mktemp *), Read, Write, Skill, Agent, AskUserQuestion
---

# /ticket

Task received:

<task>
$ARGUMENTS
</task>

This command runs two very different modes in sequence. Phases 1–3 are an interview: you sharpen and break down the task with the developer, right here, in this session. Phase 4 is a hand-off: for each ticket they choose, you start a Herdr coordinator that implements and reviews it, unattended, in its own worktree — mirroring `small-ticket`'s environment setup, but without a plan-mode gate, since by then the plan is already agreed.

If the task is empty, ask for a description and stop.

## Phase 1 — Grill the idea

Call the Skill tool with `mattpocock-skills:grilling`, using the task above as the plan under interview, and follow its process as loaded. Stop only once the frontier is empty **and** the developer has confirmed you've reached a shared understanding — don't move to Phase 2 before that confirmation. A shared understanding, not a hunch, is what Phase 2 slices up.

## Phase 2 — Break into tickets

Break the settled plan into **tracer-bullet tickets**. (This mirrors mattpocock's `to-tickets`, inlined here rather than invoked — it ships `disable-model-invocation: true`, so nothing in this session can call it directly.)

- Each ticket is a vertical slice through every layer it touches (schema, API, UI, tests) — demoable or verifiable on its own, sized to fit a single fresh context window.
- **Wide refactor exception**: one mechanical change with a codebase-wide blast radius (rename a column, retype a shared symbol) doesn't fit a vertical slice. Sequence it instead as expand (add the new form beside the old) → migrate in blast-radius-sized batches, each its own ticket, CI green batch to batch → contract (delete the old form once nothing calls it).
- Give each ticket its **blocked-by** edges: the other tickets that must land first. No blockers means it's on the **frontier** — startable immediately.
- Number tickets `01`, `02`, … in dependency order (blockers first).

Present the breakdown as a numbered list — title, blocked by, what it delivers — and ask the developer whether the granularity feels right, the blocking edges are correct, and anything should merge or split. Iterate until they approve it.

Once approved, write one file per ticket to `.scratch/<feature-slug>/issues/<NN>-<slug>.md` at the project root (find it with `git worktree list --porcelain` if you're not sure you're there already) — this is the durable record, not what the coordinator reads from (see Phase 4):

```
# <NN>: <Title>

**What to build:** <end-to-end behaviour, from the user's perspective>

**Blocked by:** <ticket numbers/titles, or "None (can start immediately)">

- [ ] <Acceptance criterion>
- [ ] <Acceptance criterion>
```

## Phase 3 — Pick tickets to implement

Ask the developer which to implement now: **all**, **none**, or **specific numbers** (AskUserQuestion, or plainly if the options don't fit). If the answer is none, stop here — the tickets are saved, and `/implement-tickets` picks them up later without re-running phases 1–3.

Check every selected ticket's blocked-by edges against the rest of the *selection*: a ticket blocked by one that's neither landed nor also launching right now would build against code that doesn't exist yet. Hold those back and note which unmet blocker gates each one. Launch only the frontier of the selection.

Once the selection is settled, ask once for the whole wave, with `AskUserQuestion`: "Which model should implement these tickets?" — options **Opus (default)**, **Sonnet**, **Haiku**, **Other…**, Opus listed first and labelled `(default)`. Every ticket launched in Phase 4 uses this answer; if the developer picks the default, still pass `opus` explicitly, so the summary agrees with what actually launched. Since this coordinator implements *and* reviews in one unattended session (see Phase 4), the chosen model governs both — there is no separate review model here the way `/small-ticket` has one.

## Phase 4 — Launch one coordinator per launched ticket

Follow `herdr` skill's rules (check `HERDR_ENV=1`, read IDs from the JSON, don't close anything you didn't create, don't answer blocked dialogs without the developer).

For each ticket to launch, derive names the same way `small-ticket` does:

- **Tab label**: 2–3 words, lowercase, up to 20 characters.
- **Branch**: `<type>-<NN>-<slug>`, kebab-case, up to 40 characters, no `/` or `--` (`type` ∈ `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`, `ci`).

Save that ticket's full file body to a temp file (`mktemp -t ticket.XXXXXX.md`) and run:

```bash
~/.claude/skills/ticket/scripts/launch.sh "<label>" "<branch>" "<ticket-file>" "<model>"
```

The script reuses `small-ticket`'s tab/worktree/pane mechanics (discover the repo root, fast-forward the base branch, create the tab, run `ga <branch>`, split the pane), then starts Claude Code unattended — no plan mode, since the plan is already agreed, and no one there to click a permission prompt mid-run — with `git add`, `commit`, `push`, `stash`, `reset`, `rebase`, `checkout`, and `switch` all blocked, and sends `templates/ticket-agent-prompt.md`. That prompt is what actually tells the coordinator how to implement (mattpocock's `implement` process inlined, since that skill is `disable-model-invocation` and can't be called) and how to review (`mattpocock-skills:code-review`), both restricted to leave everything unstaged; see that file for the exact rules passed to it.

Handle the exit code exactly as `small-ticket` does: **0** → move to the next ticket; **3** → tell the developer to answer the trust dialog in that tab, then run the printed `launch.sh prompt …` command once they confirm; **other** → read the error, don't delete branches or worktrees, and try the next ticket. Launch tickets one at a time, keeping each script's summary block.

## Phase 5 — Report

List, per launched ticket: tab, branch, worktree, agent. List held-back tickets with their unmet blockers, and unselected tickets, so the developer can run `/implement-tickets <tickets-dir>` once blockers land — that skill starts at this phase and stays resident to mark tickets resolved and launch what each merge unblocks. Don't wait for any coordinator to finish.
