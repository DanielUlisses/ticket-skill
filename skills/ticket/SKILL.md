---
name: ticket
description: Sharpens a rough task into a shared understanding, breaks it into numbered tracer-bullet tickets, then hands the board to a Haiku board session (/implement-tickets) that launches, merges and coordinates them. It never launches tickets itself. For an already-defined ticket, use /small-ticket instead; for tickets already written to the repo's tracker or `.scratch/`, use /implement-tickets.
argument-hint: "[jira-id] <task description>"
disable-model-invocation: true
allowed-tools: Bash(git *), Bash(gh *), Bash(mktemp *), Read, Write, Skill, Agent, AskUserQuestion
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
- Give each ticket its **blocked-by** edges: the other tickets that must land first. No blockers means it's on the **frontier** — startable immediately.
- Give each ticket its **seams under test**: the public boundaries its tests observe behaviour at (`mattpocock-skills:tdd` carries the vocabulary). Each ticket's coordinator runs unattended and writes no test at a seam nobody confirmed, so they get confirmed here, while the developer is present.
- Give each ticket a **suggested effort**: how hard the coordinator's model should think on it, one of `low`, `medium`, `high`, `xhigh`, `max`, with one clause saying why. A ticket that is one mechanical edit against a file whose shape is already known does not need `high`; a ticket still uncertain in its shape at launch time is exactly where the extra thinking pays. `medium` is the default and needs no defending. You **suggest** — the board session's launch question offers it pre-selected and the developer decides, the same asymmetry project memory has.
- Give each ticket a **suggested model** for its implementer — `opus` or `sonnet` — with one clause saying why. **Opus** where the ticket still holds design judgement: a new abstraction, a cross-cutting change, a subtle bug, a seam nobody has tested before. **Sonnet** where the ticket is well specified and follows a pattern the repo already has: another endpoint like the five beside it, a migration batch in a wide refactor, wiring a settled interface through. Model and effort are two knobs — `sonnet` at `high` and `opus` at `low` are both sensible answers. `opus` is the default and needs no defending; `haiku` is not an implementer here, it is what the helpers run on. A ticket that earns `xhigh` or `max` effort may suggest **`fable`** instead — the model built for the hardest, longest-horizon work — and say why more Opus effort isn't enough.
- Give each ticket a **suggested helpers** line where it would help: what the launched coordinator should fan out to its cheap subagents before and after implementation — the repo questions worth a scout each, the external API worth a researcher, checks worth splitting across testers (`scouts: callers of PaymentService, how retries are done elsewhere · research: Stripe webhook signature, API 2025-09 · tests: split by package`). Leave it out when the ticket is small enough that the coordinator's own judgement covers it.
- Check the project for a test suite first — a configured runner with tests already running under it. Without one, or where the ticket's dependencies are side-effectful enough that a test would only exercise stubs, the seams line reads `None` plus the command that exercises the real thing, which is what the coordinator then runs.
- Number tickets `01`, `02`, … in dependency order (blockers first) — or, appending to an existing Jira board (*Naming the board*, below), from the number after its highest.

Present the breakdown as a numbered list — title, blocked by, seams, what it delivers — and ask the developer whether the granularity feels right, the blocking edges and the seams are correct, and anything should merge or split. Iterate until they approve it.

Once approved, write the tickets to the repo's **ticket home** — the tracker where the repo keeps one, files under `.scratch/` where it doesn't. Either way the home is the durable record, not what a ticket's coordinator reads from — the board session composes each brief at launch. Detect which home you're in before writing anything, and never split one feature across both.

### Detecting the ticket home

The home is **GitHub issues** when both of these hold, and `.scratch/` otherwise:

1. `gh` can see a tracker on this repo:

   ```bash
   gh repo view --json nameWithOwner,hasIssuesEnabled --jq 'select(.hasIssuesEnabled) | .nameWithOwner'
   ```

   Empty output, or a non-zero exit — no GitHub remote, issues disabled, `gh` missing or unauthenticated — settles it: `.scratch/`.

2. The repo actually keeps its issues there. Either it **documents** a tracker (a `docs/agents/issue-tracker.md`, or a line in `CLAUDE.md`/`AGENTS.md` naming one), or the tracker already **holds** at least one issue:

   ```bash
   gh issue list --state all --limit 1 --json number
   ```

Issues being *enabled* is GitHub's default and proves nothing on its own, which is what the second test is for: a repo with an empty tracker and no docs about it gets `.scratch/`, so nobody silently acquires a board they never asked for. Where the repo documents its tracker, that doc's conventions win over the commands below — read it first. Say which home you detected, and on what evidence, before you write.

### The ticket body, either home

```
# <NN>: <Title>

**What to build:** <end-to-end behaviour, from the user's perspective>

**Parent:** <jira-id — this line only when the task opened with one>

**Blocked by:** <blockers, or "None (can start immediately)">

**Seams under test:** <the public boundaries this ticket's tests go at, or "None — no test suite here; verify by running <the real command>">

**Suggested model:** <opus|sonnet|fable> — <one clause: why this ticket needs that model>

**Suggested effort:** <low|medium|high|xhigh|max> — <one clause: why this ticket needs that much thinking, or that little>

**Suggested helpers:** <what to fan out to scouts, researchers and testers — this line only when it helps>

- [ ] <Acceptance criterion>
- [ ] <Acceptance criterion>
```

The two homes differ in only two places: the GitHub home carries the heading as the issue **title** rather than as a `# ` line, and writes `**Blocked by:**` as issue references (`#12, #13`) where the file home writes ticket numbers (`01, 02`).

`**Parent:**` is written only when the task opened with a Jira id, and then identically in **both** homes: the lowercase id, on every ticket of the run, just above `**Blocked by:**`. Without an id the line is left out entirely — not written empty, not written as `None`.

`**Suggested model:**`, `**Suggested effort:**` and `**Suggested helpers:**` are written the same way in **both** homes — body lines like the two above them, in the file under `.scratch/` and in the issue body alike. The first two are what the board session's launch question pre-selects; the third reaches the coordinator inside the ticket body it is sent. A ticket written before these lines existed simply carries none, and the launcher's own defaults stand.

### Naming the board

The board's name is the **Jira id** when the task opened with one, and a **feature slug** — a short kebab-case name for the settled plan — otherwise. It is `<board>` below, in the label and in the folder alike.

A fresh feature slug names a fresh board, numbered from `01`, exactly as before. A Jira id may not: a second `/ticket` run on the same id lands on the board the first one wrote, and **appends** to it rather than starting over — that is the point of naming the board after the parent. Each home below says how to tell and where numbering resumes; those checks run **only with a Jira id**. Run them **before you present the breakdown**, not when you come to write it — so with an id, detect the home (below) first, then check it for the board. When it is an existing board, announce it before writing anything, naming the numbers you're about to add — "appending 04–05 to the existing itm-9909 board" — and present the Phase 2 breakdown numbered that way from the start, so the developer approves the numbers that will actually be written. New tickets may name existing ones as blockers, by the same number (file home) or issue reference (GitHub home) those already carry.

### Writing to a GitHub tracker

Create the issues **in ticket-number order** — blockers first, which is the order they're already numbered in — so every ticket's blockers have issue numbers by the time you write its body.

- **Title**: `<NN>: <Title>`. The `NN:` prefix is what carries ticket order onto a tracker that numbers issues its own way; `/implement-tickets` reads the board back through it.
- **Label**: `ticket:<board>`, the tracker's equivalent of the feature directory, and how `/implement-tickets` finds this board again. With a Jira id, first check whether it already exists, and if it does, read the numbers its issues already hold — open and closed both, since a closed `03` still owns `03`:

  ```bash
  gh label list --search "ticket:<board>" --limit 1000 --json name --jq '.[].name' | grep -qx "ticket:<board>" \
    && gh issue list --label "ticket:<board>" --state all --limit 1000 --json number,title \
         --jq '.[] | select(.title | test("^[0-9]+:")) | "\(.title | capture("^(?<nn>[0-9]+):").nn) #\(.number)"' \
    | sort -n
  ```

  An existing label is an existing board: numbering continues from the highest `NN:` it prints — the last line (`03` → the first new ticket is `04`), and the `#number` beside each is what a new ticket's `**Blocked by:**` names when it depends on one. No label — or no Jira id — means a fresh board, numbered from `01` — create it once up front, since `--label` fails on a label that doesn't exist:

  ```bash
  gh label create "ticket:<board>" --description "Tickets for <board>" 2>/dev/null || true
  ```

- **Body**: the ticket body above, minus the heading. Write it to a file — `--body-file` where `docs/agents/issue-tracker.md` writes `--body "..."` with a heredoc, since a ticket body is multi-line Markdown and a file avoids quoting it twice — and keep the issue number `gh` prints back — the dependency edges below need it, and so does the next ticket's `**Blocked by:**` line:

  ```bash
  url=$(gh issue create --title "<NN>: <Title>" --label "ticket:<board>" --body-file <body-file>)
  number=${url##*/}
  ```

  Nothing in the stored body names the issue itself: the number doesn't exist until the issue does. The coordinator learns it at launch instead: the board session's `tk.sh launch` puts a `**Tracker:** <owner>/<repo>#<number> — report against it, don't close it` line at the top of the brief it composes, so an unattended agent knows what it's reporting against without being able to resolve its own ticket.

Then add each blocked-by edge as a **native issue dependency** — the canonical, UI-visible form, per `docs/agents/issue-tracker.md`. The endpoint wants the blocker's numeric **database id**, not its `#number`:

```bash
blocker_id=$(gh api repos/<owner>/<repo>/issues/<blocker-number> --jq .id)
gh api --method POST repos/<owner>/<repo>/issues/<child-number>/dependencies/blocked_by -F issue_id="$blocker_id"
```

If that endpoint refuses (not available on the repo), say so once and leave it: the `**Blocked by:** #12, #13` line in the body is the documented fallback, and `/implement-tickets` reads blockers from it when an issue carries no dependencies.

### Writing to `.scratch/`

#### First, make sure `.scratch/` is ignored

Only on this path — a repo with a tracker creates no `.scratch/`, so none of this runs there. Before writing the first ticket, check at the project root, with a **trailing slash**:

```bash
git -C <root> check-ignore .scratch/
```

Exit 0 means ignored: say nothing further and write the tickets. Exit 1 means not ignored. Any other exit (128 — not a repo, bad root) is an error rather than an answer: report it and edit nothing.

The trailing slash is what makes that answer right *before* the directory exists. The conventional entry is `.scratch/`, a directory-only pattern, and git won't match it against a `.scratch` that isn't on disk yet — so the bare path reports a repo that already ignores the board as one that doesn't, and the developer gets asked to add an entry that's already there. (The board session reads a board that already exists, so a bare path is right there.)

Not ignored means every `git status` in the root shows `?? .scratch/` from here on, and any `git add -A` sweeps the board into a commit. The board lives in the root checkout alone — each ticket's worktree branches off the base before the board is there, so it never travels — which makes the branch the root is on, normally the **default branch**, the one the entry belongs on. Name it rather than assuming:

```bash
git -C <root> symbolic-ref --quiet --short refs/remotes/<remote>/HEAD   # strip the leading `<remote>/`
git -C <root> branch --show-current
```

Resolve it the way `resolve_base_branch` does, so the branch you name is the one the launchers will pull: `TICKET_BASE_BRANCH` where it's set, else that remote's `HEAD` (`TICKET_REMOTE`, default `origin`), else whichever of `main`/`master` exists locally.

- **The root is on the default branch** — tell the developer `.scratch/` isn't ignored, that you'd add it to `.gitignore` on `<default-branch>`, and that this is a tracked change they'll be committing. Ask (`AskUserQuestion`), and edit only on a yes: `Read` the `.gitignore` and `Write` it back with `.scratch/` appended as its own line, preserving everything already there, or `Write` just that line where there's no file yet. Never edit it silently.
- **The root is on another branch** — say which branch it's on and which is the default, and that the entry belongs on the default one. Don't edit this branch's `.gitignore` and don't switch branches: the entry would land where the board won't. Leave it with the developer.
- **Declined, or left with the developer** — write the tickets anyway. An un-ignored board is a noisy root, not a broken one.

#### Then write the tickets

Write one file per ticket to `.scratch/<board>/issues/<NN>-<slug>.md` at the project root — find it with `git worktree list --porcelain` if you're not sure you're there already — with the heading in place and `**Blocked by:**` holding ticket numbers.

With a Jira id, check for that folder first. If `.scratch/<board>/issues/` already holds tickets, it is an existing board: numbering continues from the highest `NN` among its file names, and a new ticket blocked by an existing one names it by that number:

```bash
ls <root>/.scratch/<board>/issues/ 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)-.*\.md$/\1/p' | sort -n | tail -1
```

Empty output — or no Jira id, which skips the check — means a fresh board, numbered from `01`. Never rewrite or renumber a file that is already there — appending adds files, nothing else.

## Phase 3 — Hand the board off

This session's job ends with the tickets. It runs on the model a grilling needs and carries the whole interview in its context; running the board — launching waves, merging on the developer's word, relaying messages, launching what each merge unblocks — is bookkeeping, and it belongs to a session of its own on the cheap model `config/models.env` names for it (`TICKET_BOARD_MODEL`, Haiku). **Never launch tickets from this session.** Nothing is lost by leaving: the board session rebuilds its whole picture from the board, the live agents and git, never from this conversation.

Print, with the board's name — the Jira id, the `ticket:<board>` label's slug, or the `.scratch/<board>` path (the main checkout's, since the board session may start elsewhere):

```
Board <board> is ready: <NN> tickets, frontier <the tickets with no blockers>.
In a new Herdr tab at <root>:

  ~/.claude/skills/implement-tickets/scripts/board.sh <board>

It asks which tickets to start and how to run them, then stays on to merge on your word,
relay messages to ticket agents, and launch what each merge unblocks. Come back to a planning
session — `/ticket <jira-id> …` appends to this board — when the plan itself needs to change.
```

Then stop. See `docs/adr/0003-planner-and-board-sessions.md` and `docs/adr/0004-haiku-board-session.md`.
