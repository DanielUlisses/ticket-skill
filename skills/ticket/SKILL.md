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
- Give each ticket a **suggested effort**: how hard the coordinator's model should think on it, one of `low`, `medium`, `high`, `xhigh`, `max`, with one clause saying why. A ticket that is one mechanical edit against a file whose shape is already known does not need `high`; a ticket still uncertain in its shape at launch time is exactly where the extra thinking pays. `medium` is the default and needs no defending. You **suggest** — Phase 3's launch question offers it pre-selected and the developer decides, the same asymmetry project memory has.
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

**Suggested effort:** <low|medium|high|xhigh|max> — <one clause: why this ticket needs that much thinking, or that little>

- [ ] <Acceptance criterion>
- [ ] <Acceptance criterion>
```

The two homes differ in only two places: the GitHub home carries the heading as the issue **title** rather than as a `# ` line, and writes `**Blocked by:**` as issue references (`#12, #13`) where the file home writes ticket numbers (`01, 02`).

`**Suggested effort:**` is written the same way in **both** homes — a body line like the two above it, in the file under `.scratch/` and in the issue body alike. It is what Phase 3's launch question pre-selects, and what `/implement-tickets` reads back off a board later; a ticket written before this line existed simply carries none, and the launcher's own `medium` stands.

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

#### First, make sure `.scratch/` is ignored

Only on this path — a repo with a tracker creates no `.scratch/`, so none of this runs there. Before writing the first ticket, check at the project root, with a **trailing slash**:

```bash
git -C <root> check-ignore .scratch/
```

Exit 0 means ignored: say nothing further and write the tickets. Exit 1 means not ignored. Any other exit (128 — not a repo, bad root) is an error rather than an answer: report it and edit nothing.

The trailing slash is what makes that answer right *before* the directory exists. The conventional entry is `.scratch/`, a directory-only pattern, and git won't match it against a `.scratch` that isn't on disk yet — so the bare path reports a repo that already ignores the board as one that doesn't, and the developer gets asked to add an entry that's already there. (`/implement-tickets` Phase 0 checks the bare path and is right to: by the time it reads a board, the directory exists.)

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

Write one file per ticket to `.scratch/<feature-slug>/issues/<NN>-<slug>.md` at the project root — find it with `git worktree list --porcelain` if you're not sure you're there already — with the heading in place and `**Blocked by:**` holding ticket numbers.

## Phase 3 — Pick tickets to implement

Ask the developer which to implement now: **all**, **none**, or **specific numbers** (AskUserQuestion, or plainly if the options don't fit). If the answer is none, stop here — the tickets are saved, and `/implement-tickets` picks them up later without re-running phases 1–3.

Check every selected ticket's blocked-by edges against the rest of the *selection*: a ticket blocked by one that's neither landed nor also launching right now would build against code that doesn't exist yet. Hold those back and note which unmet blocker gates each one. Launch only the frontier of the selection.

Once the selection is settled, settle the session's launch settings below — unless this session already has, in which case they hold and nothing is asked.

### The session's launch settings

Three things govern every ticket a session launches: the **account** it bills to, the **model** that implements it, and the **effort** — how hard that model thinks — it runs at. They are settled **once**, at the first launch of the session, and every later launch reuses the answer — this skill's whole wave, and anything `/small-ticket` or `/implement-tickets` launches later in the same session. A session that launches nothing asks nothing, so this comes after the selection above, never on load.

**Already settled** — this session answered, in an earlier wave or because the developer named them up front: don't ask again. State which account, model and effort are in force when you launch and move on.

**Not settled yet** — read the defaults before you state them, rather than assuming them:

```bash
~/.claude/skills/ticket/scripts/launch.sh defaults
```

It changes nothing and prints one line per setting, plus the options for the account and for the effort:

```
MODEL=opus (from /home/you/.claude/skills/ticket-models.env)
EFFORT=medium (from /home/you/.claude/skills/ticket-models.env)
EFFORTS=low medium high xhigh max
ACCOUNT=default (inherited by a new worktree in /home/you/repos — config root ~/.claude)
ACCOUNTS=default work
```

The `ACCOUNT=` name is the one a **new worktree** would inherit. That is not the same question as which account *this* session is running under, and the difference is the entire reason this is asked: a session in a worktree that overrode its own account would otherwise offer that account as the default and launch every ticket somewhere else. Quote what the command printed.

`EFFORT=` is the level an unnamed launch would run at, and its source is named the same way `MODEL=`'s is. On a machine whose `ticket-models.env` predates this knob it reads `(from the launcher's built-in fallback — nothing set it in <path>)`, which is `medium` and is correct: `install.sh` never overwrites a hand-held destination copy, so that file keeps saying nothing about effort until the developer deletes it. `EFFORTS=` is the list of levels to offer, printed by the launcher so no skill has to keep its own copy of it.

**The tickets suggest the effort.** Every ticket Phase 2 wrote carries a `**Suggested effort:**` line — read the *selection's* and pre-select it over the launcher's `EFFORT=` default. Where the selected tickets disagree, name the spread and pre-select the highest of them: the ticket that asked for more thinking is the one that loses by getting less, and a single ticket can still be launched at its own level as a per-ticket override. Where none of them carries the line — a board written before this existed — `EFFORT=` stands.

Then ask with **one** `AskUserQuestion` call, one question per setting:

| Setting | Question | Options, in order | How it reaches the launcher |
|---|---|---|---|
| Account | "Which Claude account should this session's tickets run on?" | the `ACCOUNT=` name first, labelled `(default — inherited)`, then the rest of `ACCOUNTS=` | `--account <name>` — and the inherited default passes **no flag at all**, since inheriting is what writes no link |
| Model | "Which model should implement this session's tickets?" | the `MODEL=` value first, labelled `(default)`, then the other two of Opus / Sonnet / Haiku, then **Other…** — the launcher takes any model id, a pinned one included | the positional `[model]`, always explicitly, even when it is the default, so the summary agrees with what launched |
| Effort | "How hard should the model think on this session's tickets?" | the suggested level first, labelled `(suggested by the tickets)` — or the `EFFORT=` value labelled `(default)` where none of them suggests one — then the rest of `EFFORTS=` | `--effort <level>`, always explicitly, even when it is the default, so the summary agrees with what launched |

One call with one question per setting, not one question then another: a further setting is another row here and another field you carry, not another round of questions.

**Then hold them.** Every launch in this session passes all three and names all three in its report. Two overrides exist and they are different things:

- **For one ticket** — the developer names an account, a model or an effort for a single launch. It goes to that launch alone; the session's settings are untouched and the next ticket uses them again.
- **For the session** — the developer asks to change the setting itself. Replace it, say so, and use the new value for every launch after it.

Neither is a reason to re-ask on the next ticket; re-ask only when the developer asks you to. See `docs/agents/session-settings.md`.

Since this coordinator implements *and* reviews in one unattended session (see Phase 4), the chosen model **and the chosen effort** govern both — there is no separate review model here the way `/small-ticket` has one, and no separate review effort anywhere. Trading effort down for a cheaper run buys a shallower review with it.

## Phase 4 — Launch one coordinator per launched ticket

Follow `herdr` skill's rules (check `HERDR_ENV=1`, read IDs from the JSON, don't close anything you didn't create, don't answer blocked dialogs without the developer).

For each ticket to launch, derive names the same way `small-ticket` does:

- **Tab label**: 2–3 words, lowercase, up to 20 characters.
- **Branch**: `<type>-<NN>-<slug>`, kebab-case, up to 40 characters, no `/` or `--` (`type` ∈ `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`, `ci`).

Save that ticket's full file body to a temp file (`mktemp -t ticket.XXXXXX.md`) and run:

```bash
~/.claude/skills/ticket/scripts/launch.sh [--account <name>] --effort "<level>" "<label>" "<branch>" "<ticket-file>" "<model>"
```

All three values come from the session's launch settings above: `--account <name>` unless the
session inherits, in which case the flag is left off entirely and the ticket resolves the
developer's own directory link, exactly as every ticket did before this knob existed;
`--effort <level>` always, since unlike the account there is no "inherit" for it and an
explicit flag is what makes the launch and its summary agree. A level the launcher doesn't
know stops it before anything is created — Claude Code itself would only warn and run at its
own default, so a typo would otherwise look like it worked. A per-ticket override the
developer named for *this* ticket replaces one value here and leaves the session's settings
alone. An unknown account name stops the script before anything is
created, and `claude-acc list` is the answer to show them. See `docs/agents/accounts.md` and
`docs/agents/session-settings.md`.

The script runs the same shared launcher `small-ticket` does — one `lib/ticket-launcher.sh`, installed as `~/.claude/skills/ticket-launcher.sh`, with only the template, the permission mode and the blocked tools differing (discover the repo root, fast-forward the base branch, then one synchronous `herdr worktree create --cwd <root> --branch <branch> --base <base> --path <root>/../<repo>--<branch> --label <label>` that returns the worktree's own workspace, tab and root pane — or fails with Herdr's own error — then lay that workspace out as three tabs, `agent` | `review` | `shell`; `small-ticket`'s **Manual fallback** section has the call sequence and the note on why `review` is built by moving the reviewr plugin's pane), then starts Claude Code unattended on the root pane in the `agent` tab — no plan mode, since the plan is already agreed, and no one there to click a permission prompt mid-run — with `git add`, `commit`, `push`, `stash`, `reset`, `rebase`, `checkout`, and `switch` all blocked, and sends `templates/ticket-agent-prompt.md` — with the repo's `docs/agents/project-memory.md` folded in as a `## Project memory` section where the main checkout keeps one, and nothing at all where it doesn't (`docs/agents/memory.md`; the script's `PROJECT_MEMORY=` summary line says which). That prompt is what actually tells the coordinator how to implement (mattpocock's `implement` process inlined, since that skill is `disable-model-invocation` and can't be called) and how to review (`mattpocock-skills:code-review`), both restricted to leave everything unstaged; see that file for the exact rules passed to it.

Handle the exit code exactly as `small-ticket` does: **0** → move to the next ticket; **3** → tell the developer to answer the trust dialog in that tab, then run the printed `launch.sh prompt …` command once they confirm; **other** → read the error (every Herdr call carries Herdr's own message, `ERROR: herdr worktree create failed: ...`, `ERROR: herdr tab create (shell) failed: ...`), don't delete branches or worktrees, and try the next ticket. Launch tickets one at a time, keeping each script's summary block — it names the workspace and all three tabs, its `REVIEW=` line says whether the `review` tab holds the reviewr pane or an empty shell, and its `MODEL=`, `EFFORT=` and `ACCOUNT=` lines name what that ticket actually started on.

## Phase 5 — Report

List, per launched ticket: workspace, branch, worktree, agent, and the account, model and effort it ran on — the launcher's own `ACCOUNT=`, `MODEL=` and `EFFORT=` lines, not what you asked for; the account one in particular is verified in the pane. List held-back tickets with their unmet blockers, and unselected tickets, so the developer can run `/implement-tickets <tickets-dir>` once blockers land — that skill starts at this phase and stays resident to mark tickets resolved and launch what each merge unblocks. Don't wait for any coordinator to finish.

## Manual fallback (only if the script fails due to a CLI change)

Steps 0–2 and 4 are `small-ticket`'s **Manual fallback**, unchanged: update the base branch, `herdr worktree create`, lay the workspace out as the three tabs `agent` | `review` | `shell` (rename the worktree's numeric tab to `agent`; move the reviewr plugin's pane into a `review` tab, or create an empty one; append `shell`), then render and send the prompt. Read that section for the exact calls and for why `review` is built by moving a pane.

Only step 3, starting the agent, differs — `/ticket` runs unattended, so it does **not** use plan mode and blocks eight git verbs rather than two:

```bash
herdr agent start tk-<branch> --kind claude --pane <root-pane> -- \
  --model <the chosen model> --effort <the chosen effort> --permission-mode bypassPermissions \
  --disallowedTools "Bash(git add:*)" "Bash(git commit:*)" "Bash(git push:*)" \
    "Bash(git stash:*)" "Bash(git reset:*)" "Bash(git rebase:*)" \
    "Bash(git checkout:*)" "Bash(git switch:*)"
```

Step 4 sends `templates/ticket-agent-prompt.md`, not `small-ticket`'s `templates/agent-prompt.md`. Its placeholders are the same set, `{{PROJECT_MEMORY}}` included.
