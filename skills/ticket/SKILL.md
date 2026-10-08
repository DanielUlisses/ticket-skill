---
name: ticket
description: Sharpens a rough task into a shared understanding, breaks it into numbered tracer-bullet tickets, then hands the board to a Haiku board session (/implement-tickets) that launches, merges and coordinates them. It never launches tickets itself. For an already-defined ticket, use /small-ticket instead; for tickets already written to `.scratch/`, use /implement-tickets.
argument-hint: "[jira-id] <task description>"
disable-model-invocation: true
allowed-tools: Bash(git *), Bash(ls *), Read, Write, Skill, Agent, AskUserQuestion
---

# /ticket

Task received:

<task>
$ARGUMENTS
</task>

This command is the **planning session**: Phases 1–2 are an interview — you sharpen and break down the task with the developer, right here — and Phase 3 hands the written board to a separate, cheap board session that launches and coordinates the tickets. Nothing is launched from here.

### A Jira id as the first word

Before anything else, look at the task's **first word**. It is a Jira id when it matches `^[A-Za-z][A-Za-z0-9]+-[0-9]+$` — `ITM-9909`, `itm-9909`, `PROJ2-14`. When it does:

- **Normalize** it to lowercase (`ITM-9909` → `itm-9909`); that lowercase form is the only one written anywhere below.
- **Strip** it from the task text. What remains is the task Phase 1 interviews — the id names where the tickets go, not what they are about.
- **Say so** in one line before the interview starts: "Jira id `itm-9909` — the board is `itm-9909` and every ticket's parent."

The id then does two things in Phase 2, and nothing else: it is the **board's name** (in place of the feature slug) and every ticket's **parent** (a `**Parent:**` line in its body). Branch names, the coordinator's brief and `/small-ticket` are untouched, and nothing calls Jira — the id is a name, not a link.

Only the first word counts. A key-shaped token anywhere later in the text is just text, and a first word that doesn't match the pattern means there is no id: the feature slug names the board and no ticket carries a parent, exactly as before this existed. See `docs/agents/jira-parent.md`.

If the task is empty — including a task that was only an id — ask for a description and stop.

## Phase 1 — Grill the idea

Call the Skill tool with `mattpocock-skills:grilling`, using the task above as the plan under interview, and follow its process as loaded. Stop only once the frontier is empty **and** the developer has confirmed you've reached a shared understanding — don't move to Phase 2 before that confirmation. A shared understanding, not a hunch, is what Phase 2 slices up.

## Phase 2 — Break into tickets

Break the settled plan into **tracer-bullet tickets**. (This mirrors mattpocock's `to-tickets`, inlined here rather than invoked — it ships `disable-model-invocation: true`, so nothing in this session can call it directly.)

- Each ticket is a vertical slice through every layer it touches (schema, API, UI, tests) — demoable or verifiable on its own, sized to fit a single fresh context window.
- **Wide refactor exception**: one mechanical change with a codebase-wide blast radius (rename a column, retype a shared symbol) doesn't fit a vertical slice. Sequence it instead as expand (add the new form beside the old) → migrate in blast-radius-sized batches, each its own ticket, CI green batch to batch → contract (delete the old form once nothing calls it).
- Give each ticket its **repo**: the repository whose code it changes — this one unless the plan says otherwise. A ticket's worktree, branch and PR are made in the repo its board is in, so a ticket that changes another repo **must be written to that repo's board**, never this one (a ticket launched here for code that lives elsewhere does its work outside its own branch, and its PR can never be seen to land). One ticket changes one repo: a slice that needs both is split into one ticket per repo, the second blocked by the first. Where the plan touches another repo, ask the developer for its local checkout (`AskUserQuestion`, offering sibling directories of this root that are git repos) and confirm it with `git -C <path> rev-parse --show-toplevel`.
- Give each ticket its **blocked-by** edges: the other tickets that must land first. No blockers means it's on the **frontier** — startable immediately.
- Give each ticket its **seams under test**: the public boundaries its tests observe behaviour at (`mattpocock-skills:tdd` carries the vocabulary). Each ticket's coordinator runs unattended and writes no test at a seam nobody confirmed, so they get confirmed here, while the developer is present.
- Give each ticket a **suggested effort**: how hard the coordinator's model should think on it, one of `low`, `medium`, `high`, `xhigh`, `max`, with one clause saying why. A ticket that is one mechanical edit against a file whose shape is already known does not need `high`; a ticket still uncertain in its shape at launch time is exactly where the extra thinking pays. `medium` is the default and needs no defending. You **suggest** — the board session's launch question offers it pre-selected and the developer decides, the same asymmetry project memory has.
- Give each ticket a **suggested model** for its implementer — `opus` or `sonnet` — with one clause saying why. **Opus** where the ticket still holds design judgement: a new abstraction, a cross-cutting change, a subtle bug, a seam nobody has tested before. **Sonnet** where the ticket is well specified and follows a pattern the repo already has: another endpoint like the five beside it, a migration batch in a wide refactor, wiring a settled interface through. Model and effort are two knobs — `sonnet` at `high` and `opus` at `low` are both sensible answers. `opus` is the default and needs no defending; `haiku` is not an implementer here, it is what the helpers run on. A ticket that earns `xhigh` or `max` effort may suggest **`fable`** instead — the model built for the hardest, longest-horizon work — and say why more Opus effort isn't enough.
- Give each ticket a **suggested helpers** line where it would help: what the launched coordinator should fan out to its cheap subagents before and after implementation — the repo questions worth a scout each, the external API worth a researcher, checks worth splitting across testers (`scouts: callers of PaymentService, how retries are done elsewhere · research: Stripe webhook signature, API 2025-09 · tests: split by package`). Leave it out when the ticket is small enough that the coordinator's own judgement covers it.
- Check the project for a test suite first — a configured runner with tests already running under it. Without one, or where the ticket's dependencies are side-effectful enough that a test would only exercise stubs, the seams line reads `None` plus the command that exercises the real thing, which is what the coordinator then runs. Infrastructure that only runs live (Terraform, Terragrunt, Helm) is `None` too — `None — offline checks only (terragrunt hclfmt, validate); verified by the developer's plan` — never a command that touches a real environment. A `None` there also raises that ticket's review to `TICKET_REVIEW_EFFORT_UNTESTED` (`high`), and the reviewer returns the plan it expects.
- Number tickets `01`, `02`, … in dependency order (blockers first) — or, appending to an existing Jira board (*Naming the board*, below), from the number after its highest.

Present the breakdown as a numbered list — title, repo (when the plan spans more than one), blocked by, seams, what it delivers — and ask the developer whether the granularity feels right, the blocking edges and the seams are correct, and anything should merge or split. Iterate until they approve it.

Once approved, write the tickets as files under `.scratch/<board>/issues/` at the project root (*Writing to `.scratch/`*, below). That folder is the board: the durable record the board session reads, and what it composes each ticket's brief from at launch. Boards live nowhere else — not on a GitHub tracker, even where the repo has one (ADR 0005).

### The ticket body

```
# <NN>: <Title>

**What to build:** <end-to-end behaviour, from the user's perspective>

**Parent:** <jira-id — this line only when the task opened with one>

**Repo:** <the repo root's directory name> — <its absolute path>

**Blocked by:** <blockers, or "None (can start immediately)">

**Seams under test:** <the public boundaries this ticket's tests go at, or "None — no test suite here; verify by running <the real command>">

**Suggested model:** <opus|sonnet|fable> — <one clause: why this ticket needs that model>

**Suggested effort:** <low|medium|high|xhigh|max> — <one clause: why this ticket needs that much thinking, or that little>

**Suggested helpers:** <what to fan out to scouts, researchers and testers — this line only when it helps>

- [ ] <Acceptance criterion>
- [ ] <Acceptance criterion>
```

`**Blocked by:**` names ticket numbers (`01, 02`). A blocker on another repo's board is `<repo>:<NN>` (`api:02`), with `<repo>` that repo's directory name — the board looks it up on that repo's board of the same name and holds the ticket until it is resolved there.

`**Repo:**` is written on every ticket: the directory name of the root of the repo the ticket changes, then its absolute path. The board refuses to launch, or open a PR for, a ticket whose repo isn't its own, so a ticket written to the wrong board is caught at launch rather than after its merge.

`**Parent:**` is written only when the task opened with a Jira id: the lowercase id, on every ticket of the run, just above `**Blocked by:**`. Without an id the line is left out entirely — not written empty, not written as `None`.

`**Suggested model:**`, `**Suggested effort:**` and `**Suggested helpers:**` are body lines like the two above them. The first two are what the board session's launch question pre-selects; the third reaches the coordinator inside the ticket body it is sent. A ticket written before these lines existed simply carries none, and the launcher's own defaults stand.

### Naming the board

The board's name is the **Jira id** when the task opened with one, and a **feature slug** — a short kebab-case name for the settled plan — otherwise. It is `<board>` below — the folder `.scratch/<board>/`.

A fresh feature slug names a fresh board, numbered from `01`, exactly as before. A Jira id may not: a second `/ticket` run on the same id lands on the board the first one wrote, and **appends** to it rather than starting over — that is the point of naming the board after the parent. *Then write the tickets*, below, says how to tell and where numbering resumes; that check runs **only with a Jira id**. Run it **before you present the breakdown**, not when you come to write it. When it is an existing board, announce it before writing anything, naming the numbers you're about to add — "appending 04–05 to the existing itm-9909 board" — and present the Phase 2 breakdown numbered that way from the start, so the developer approves the numbers that will actually be written. New tickets may name existing ones as blockers, by the number those already carry.

### Writing to `.scratch/`

#### First, make sure `.scratch/` is ignored

Before writing the first ticket, check at the project root, with a **trailing slash**:

```bash
git -C <root> check-ignore .scratch/
```

Exit 0 means ignored: say nothing further and write the tickets. Exit 1 means not ignored. Any other exit (128 — not a repo, bad root) is an error rather than an answer: report it and edit nothing.

The trailing slash is what makes that answer right *before* the directory exists. The conventional entry is `.scratch/`, a directory-only pattern, and git won't match it against a `.scratch` that isn't on disk yet — so the bare path reports a repo that already ignores the board as one that doesn't, and the developer gets asked to add an entry that's already there. (The board session reads a board that already exists, so a bare path is right there.)

Not ignored means every `git status` in the root shows `?? .scratch/` from here on, and any `git add -A` sweeps the board into a commit. The board lives in the root checkout alone — each ticket's worktree branches off the base before the board is there, so it never travels — which makes the branch the root is on, normally the **default branch**, the one the entry belongs on. Name it rather than assuming:

```bash
git -C <root> symbolic-ref --quiet --short refs/remotes/<remote>/HEAD   # strip the leading `<remote>/`; fails with no remote
git -C <root> branch --show-current
```

Resolve it the way `resolve_base_branch` does, so the branch you name is the one the launchers branch from: `TICKET_BASE_BRANCH` where it's set, else that remote's `HEAD` (`TICKET_REMOTE`, default `origin`), else whichever of `main`/`master` exists locally.

- **The root is on the default branch** — tell the developer `.scratch/` isn't ignored, that you'd add it to `.gitignore` on `<default-branch>`, and that this is a tracked change they'll be committing. Ask (`AskUserQuestion`), and edit only on a yes: `Read` the `.gitignore` and `Write` it back with `.scratch/` appended as its own line, preserving everything already there, or `Write` just that line where there's no file yet. Never edit it silently.
- **The root is on another branch** — say which branch it's on and which is the default, and that the entry belongs on the default one. Don't edit this branch's `.gitignore` and don't switch branches: the entry would land where the board won't. Leave it with the developer.
- **Declined, or left with the developer** — write the tickets anyway. An un-ignored board is a noisy root, not a broken one.

#### Then write the tickets

Write one file per ticket to `.scratch/<board>/issues/<NN>-<slug>.md` at the root **of the ticket's repo** — this project's root for its own tickets (find it with `git worktree list --porcelain` if you're not sure you're there already), the other repo's root for each of its tickets — with the heading in place and `**Blocked by:**` holding ticket numbers.

**A plan spanning repos** gets one board per repo, all under the same board name, numbered as one sequence — `01`–`03` in `api`, `04`–`05` in `web` — so a number names one ticket wherever it is written, and a cross-repo blocker reads `api:02`. Run the `.gitignore` check above in each repo before writing there. In each of those boards, also write `.scratch/<board>/repos`: one line per repo of the plan, `<name> <absolute path>`, which is how each board finds the others' tickets. With a Jira id, the existing-board check below runs in every repo of the plan, and numbering continues from the highest number across all of them.

With a Jira id, check for that folder first. If `.scratch/<board>/issues/` already holds tickets, it is an existing board: numbering continues from the highest `NN` among its file names, and a new ticket blocked by an existing one names it by that number:

```bash
ls <root>/.scratch/<board>/issues/ 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)-.*\.md$/\1/p' | sort -n | tail -1
```

Empty output — or no Jira id, which skips the check — means a fresh board, numbered from `01`. Never rewrite or renumber a file that is already there — appending adds files, nothing else.

## Phase 3 — Hand the board off

This session's job ends with the tickets. It runs on the model a grilling needs and carries the whole interview in its context; running the board — launching waves, merging on the developer's word, relaying messages, launching what each merge unblocks — is bookkeeping, and it belongs to a session of its own on the cheap model `config/models.env` names for it (`TICKET_BOARD_MODEL`, Haiku). **Never launch tickets from this session.** Nothing is lost by leaving: the board session rebuilds its whole picture from the board, the live agents and git, never from this conversation.

Print, with the board's name — the Jira id or the feature slug, i.e. the folder under `.scratch/` — and, for a plan spanning repos, one such block per repo, each with its own root, frontier and command (each repo runs its own board session; a cross-repo blocker clears when the other board resolves it):

```
Board <board> is ready: <NN> tickets, frontier <the tickets with no blockers>.
In a new Herdr tab at <root>:

  ~/.claude/skills/implement-tickets/scripts/board.sh <board>

It asks which tickets to start and how to run them, then stays on to merge on your word,
relay messages to ticket agents, and launch what each merge unblocks. Come back to a planning
session — `/ticket <jira-id> …` appends to this board — when the plan itself needs to change.
```

Then stop. See `docs/adr/0003-planner-and-board-sessions.md` and `docs/adr/0004-haiku-board-session.md`.
