---
name: ticket
description: Sharpens a rough task into a shared understanding, breaks it into numbered tracer-bullet tickets, then launches an unattended Herdr coordinator per chosen ticket to implement and review it, leaving everything uncommitted. For an already-defined ticket, use /small-ticket instead; for tickets already written to the repo's tracker or `.scratch/`, use /implement-tickets.
argument-hint: "<task description>"
disable-model-invocation: true
allowed-tools: Bash(~/.claude/skills/ticket/scripts/launch.sh *), Bash(herdr *), Bash(git *), Bash(gh *), Bash(mktemp *), Read, Write, Skill, Agent, AskUserQuestion
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
- Give each ticket its **seams under test**: the public boundaries its tests observe behaviour at (`mattpocock-skills:tdd` carries the vocabulary). Phase 4's coordinator runs unattended and writes no test at a seam nobody confirmed, so they get confirmed here, while the developer is present.
- Check the project for a test suite first — a configured runner with tests already running under it. Without one, or where the ticket's dependencies are side-effectful enough that a test would only exercise stubs, the seams line reads `None` plus the command that exercises the real thing, which is what the coordinator then runs.
- Number tickets `01`, `02`, … in dependency order (blockers first).

Present the breakdown as a numbered list — title, blocked by, seams, what it delivers — and ask the developer whether the granularity feels right, the blocking edges and the seams are correct, and anything should merge or split. Iterate until they approve it.

Once approved, write the tickets to the repo's **ticket home** — the tracker where the repo keeps one, files under `.scratch/` where it doesn't. Either way the home is the durable record, not what the coordinator reads from (see Phase 4). Detect which home you're in before writing anything, and never split one feature across both.

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

**Blocked by:** <blockers, or "None (can start immediately)">

**Seams under test:** <the public boundaries this ticket's tests go at, or "None — no test suite here; verify by running <the real command>">

- [ ] <Acceptance criterion>
- [ ] <Acceptance criterion>
```

The two homes differ in only two places: the GitHub home carries the heading as the issue **title** rather than as a `# ` line, and writes `**Blocked by:**` as issue references (`#12, #13`) where the file home writes ticket numbers (`01, 02`).

### Writing to a GitHub tracker

Create the issues **in ticket-number order** — blockers first, which is the order they're already numbered in — so every ticket's blockers have issue numbers by the time you write its body.

- **Title**: `<NN>: <Title>`. The `NN:` prefix is what carries ticket order onto a tracker that numbers issues its own way; `/implement-tickets` reads the board back through it.
- **Label**: `ticket:<feature-slug>`, the tracker's equivalent of the feature directory, and how `/implement-tickets` finds this board again. Create it once up front — `--label` fails on a label that doesn't exist:

  ```bash
  gh label create "ticket:<feature-slug>" --description "Tickets for <feature>" 2>/dev/null || true
  ```

- **Body**: the ticket body above, minus the heading. Write it to a file — `--body-file` where `docs/agents/issue-tracker.md` writes `--body "..."` with a heredoc, since a ticket body is multi-line Markdown and a file avoids quoting it twice — and keep the issue number `gh` prints back — the dependency edges below need it, and so does the next ticket's `**Blocked by:**` line:

  ```bash
  url=$(gh issue create --title "<NN>: <Title>" --label "ticket:<feature-slug>" --body-file <body-file>)
  number=${url##*/}
  ```

  Nothing in the stored body names the issue itself: the number doesn't exist until the issue does. The coordinator learns it in Phase 4 instead, which puts a `**Tracker:** <owner>/<repo>#<number> — report against it, don't close it` line at the top of the brief it composes, so an unattended agent knows what it's reporting against without being able to resolve its own ticket.

Then add each blocked-by edge as a **native issue dependency** — the canonical, UI-visible form, per `docs/agents/issue-tracker.md`. The endpoint wants the blocker's numeric **database id**, not its `#number`:

```bash
blocker_id=$(gh api repos/<owner>/<repo>/issues/<blocker-number> --jq .id)
gh api --method POST repos/<owner>/<repo>/issues/<child-number>/dependencies/blocked_by -F issue_id="$blocker_id"
```

If that endpoint refuses (not available on the repo), say so once and leave it: the `**Blocked by:** #12, #13` line in the body is the documented fallback, and `/implement-tickets` reads blockers from it when an issue carries no dependencies.

### Writing to `.scratch/`

Write one file per ticket to `.scratch/<feature-slug>/issues/<NN>-<slug>.md` at the project root — find it with `git worktree list --porcelain` if you're not sure you're there already — with the heading in place and `**Blocked by:**` holding ticket numbers.

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

The script reuses `small-ticket`'s worktree/pane mechanics (discover the repo root, fast-forward the base branch, then one synchronous `herdr worktree create --cwd <root> --branch <branch> --base <base> --path <root>/../<repo>--<branch> --label <label>` that returns the worktree's own workspace, tab and root pane — or fails with Herdr's own error — and split that pane), then starts Claude Code unattended — no plan mode, since the plan is already agreed, and no one there to click a permission prompt mid-run — with `git add`, `commit`, `push`, `stash`, `reset`, `rebase`, `checkout`, and `switch` all blocked, and sends `templates/ticket-agent-prompt.md`. That prompt is what actually tells the coordinator how to implement (mattpocock's `implement` process inlined, since that skill is `disable-model-invocation` and can't be called) and how to review (`mattpocock-skills:code-review`), both restricted to leave everything unstaged; see that file for the exact rules passed to it.

Handle the exit code exactly as `small-ticket` does: **0** → move to the next ticket; **3** → tell the developer to answer the trust dialog in that tab, then run the printed `launch.sh prompt …` command once they confirm; **other** → read the error (a failed creation carries Herdr's own message, `ERROR: herdr worktree create failed: ...`), don't delete branches or worktrees, and try the next ticket. Launch tickets one at a time, keeping each script's summary block.

## Phase 5 — Report

List, per launched ticket: tab, branch, worktree, agent. List held-back tickets with their unmet blockers, and unselected tickets, so the developer can run `/implement-tickets <tickets-dir>` once blockers land — that skill starts at this phase and stays resident to mark tickets resolved and launch what each merge unblocks. Don't wait for any coordinator to finish.
