---
name: implement-tickets
description: Implements tickets that are already written. Reads the board from wherever the repo keeps tickets — GitHub issues where it has a tracker, files under `.scratch` where it doesn't — asks which to start, launches one unattended Herdr coordinator per frontier ticket, then stays on as the ticket coordinator — verifying each merge the developer reports, marking that ticket resolved in its home, and launching whatever the merge unblocks. For a rough idea that still needs grilling and splitting, use /ticket; for a single ad-hoc ticket, use /small-ticket.
argument-hint: "[tickets directory, or a ticket label / feature slug]"
disable-model-invocation: true
allowed-tools: Bash(~/.claude/skills/ticket/scripts/launch.sh *), Bash(herdr *), Bash(git *), Bash(gh *), Bash(mktemp *), Bash(ls *), Bash(cat *), Bash(find *), Bash(grep *), Bash(awk *), Read, Write, Edit, Glob, Grep, AskUserQuestion, ToolSearch, Monitor
---

# /implement-tickets

Board received — a tickets directory, a ticket label, or a feature slug (may be empty):

<board>
$ARGUMENTS
</board>

The tickets already exist. Skip grilling and breakdown entirely — `/ticket` phases 1–3 already happened, or the developer wrote the files by hand. You start at implementation, and then **you stay**: this session is the **ticket coordinator** for the whole run, not just a launcher.

Two jobs, in order:

1. **Launch** an unattended Herdr coordinator per frontier ticket, exactly as `/ticket` phase 4 does.
2. **Coordinate**: when the developer tells you a ticket has merged, verify it against the base branch, mark it resolved in its home, and launch whatever that unblocks — until the board is done or the developer stops you.

## Phase 0 — Find the board

Tickets live in the repo's **ticket home**: GitHub issues where the repo keeps a tracker, files under `.scratch/` where it doesn't. `/ticket` phase 2 chose that home when it wrote them; this phase finds it again. Everything after this phase works off tickets, not files — the home only decides how you read and write them.

Resolve the **main repo root** first (this session may be inside a worktree):

```bash
git worktree list --porcelain | awk 'NR==1 && /^worktree /{ sub(/^worktree /, ""); print }'
```

Then read the argument:

- **A path** — it contains a `/`, ends in `.md`, or names an existing directory. A **file board** there, relative to the main repo root unless it's absolute.
- **A label or feature slug** — `ticket:<slug>`, or a bare `<slug>` that matches one of the tracker's `ticket:*` labels. A **GitHub board** scoped to that label.
- **Empty** — detect the home, the same two tests `/ticket` phase 2 uses. A **GitHub board** when both hold, a **file board** at `<root>/.scratch` otherwise:

  ```bash
  gh repo view --json nameWithOwner,hasIssuesEnabled --jq 'select(.hasIssuesEnabled) | .nameWithOwner'   # 1. a tracker exists
  gh issue list --state all --limit 1 --json number                                                      # 2. ...and it holds issues
  ```

  Empty output or a non-zero exit from the first — no GitHub remote, issues disabled, `gh` missing or unauthenticated — settles it as a file board. A repo that **documents** a tracker (`docs/agents/issue-tracker.md`, or a line in `CLAUDE.md`/`AGENTS.md` naming one) satisfies the second test even with an empty tracker, and its conventions win over the commands here.

Say which home you resolved and on what evidence, before reading anything.

### A GitHub board

Scope the board to a label, where the tickets carry one:

```bash
gh label list --search "ticket:" --json name --jq '.[].name'
```

- **One `ticket:*` label** — that's the board.
- **Several** — list them with their open counts and ask the developer which (AskUserQuestion); this is the same question a multi-feature `.scratch` asks.
- **None** — the board is the tracker's own tickets: every issue whose title starts with `<NN>:`. Say that's what you're treating as the board before reading it, since it's the whole tracker rather than one feature.

### A file board

Find the ticket files under the path (`*.md`, recursively). `/ticket` writes them as `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, so a bare `.scratch` is two levels above the tickets and may hold **several feature directories**. If the path resolves to more than one feature directory, list them and ask the developer which one (AskUserQuestion).

Also check whether the tickets are ignored by git (`git check-ignore <path>`; exit 1 means **not ignored**). If they aren't ignored, mention once that marking tickets resolved will dirty the repo root, and that `.scratch/` in `.gitignore` avoids it. Don't edit `.gitignore` yourself. A GitHub board has no equivalent concern — nothing in the working tree changes.

Either way, if the home resolves to no tickets at all — no issues on the label, no `.md` files under the path — say so with exactly where you looked, and stop. Don't invent tickets, and don't fall back to the other home: an empty board is a wrong argument or a wrong home, and the developer settles which.

## Phase 1 — Read the board

Read every ticket in the home. Whichever home it is, each one comes out as the same six things — **number**, **title**, **status** (`open`, `in-progress`, `resolved`), **blockers**, **branch**, **model** — and every phase after this works off those.

### From a file board

- **Number and title** from the `# <NN>: <Title>` heading (fall back to the filename).
- **Status** from a `**Status:**` line. **A missing `Status` line means `open`**; `/ticket` writes files without one, and this skill has to read those unchanged.
- **Branch** from a `**Branch:**` line, if a previous run recorded one.
- **Blocked by** from the `**Blocked by:**` line.
- **Model** from a `**Model:**` line, if a previous run recorded one — that's what that ticket's coordinator is (or was) running on. Absent on a fresh board; present once Phase 3 has launched it at least once.

### From a GitHub board

One call reads the whole board, dependencies included — drop `--label` on an unlabelled board:

```bash
gh issue list --label "ticket:<slug>" --state all --limit 200 \
  --json number,title,body,state,assignees,labels,blockedBy,comments
```

- **Number and title** from the issue title's `<NN>: <Title>`. The ticket number is the `NN` prefix, **not** the issue number; keep both, because `NN` orders the board and the issue number is what you act on. On an unlabelled board, an issue whose title carries no `<NN>:` prefix isn't a ticket — skip it.
- **Status**: a **closed** issue is `resolved`. An open one is `in-progress` if it's **assigned** or carries a **run-state comment** from a previous wave (see *Writing back to the board*), and `open` otherwise. Both signals are in the call above — that's why it asks for `assignees` and `comments`. An assignee alone means in-progress even with no run-state comment: `docs/agents/issue-tracker.md` treats assignment as the claim, so somebody is on it whether or not this skill launched them.
- **Blocked by** from `blockedBy.nodes` — GitHub's native issue dependencies, which is where `/ticket` phase 2 puts the edges. A node that's still `OPEN` is a live blocker; a `CLOSED` one is satisfied:

  ```bash
  --jq '[.[] | {number, open_blockers: [.blockedBy.nodes[] | select(.state == "OPEN") | .number]}]'
  ```

  This is the same gate `docs/agents/issue-tracker.md` names as `issue_dependencies_summary.blocked_by`, reached through the CLI instead of the REST API: that field counts **open** blockers only, so a `select(.state == "OPEN")` count over `blockedBy.nodes` equals it, and `nodes | length` equals its `total_blocked_by`. Use the CLI form — `issueDependenciesSummary` is not a `gh --json` field, and `gh api` per issue would be one call per ticket instead of one for the board.

  Where an issue carries **no** dependencies at all, fall back to the `**Blocked by:**` line in its body — a board written before dependencies were available, or one whose repo refused the endpoint, has its edges only there.
- **Branch** and **Model** from the run-state comment.
- **Brief** — the ticket as the coordinator will receive it: the **issue body** with `# <NN>: <Title>` put back on top and a `**Tracker:** <owner>/<repo>#<issue> — report against it, don't close it` line under it. That's what Phase 3 writes to its temp file, so the launcher and the agent prompt never know which home it came from.

  Keep **brief** and **issue body** apart from here on: the brief is composed fresh for each launch and is never written back, and the issue body is what actually lives on the tracker. Editing the issue with a brief would duplicate the title as an H1 and plant a `**Tracker:**` self-reference that was never there.

### Blockers are free text either way

The `**Blocked by:**` line is free text — `01, 02`, `#12, #13`, `None (can start immediately)`, `Ticket 02 (schema)`. Parse it leniently: case-insensitive `none` (or empty) means no blockers. Otherwise, a digit-run written as `#<n>` is an **issue** number — resolve it straight against the board — and a bare digit-run is a ticket `NN`, resolved through the `NN` you parsed from each heading or title. Ignore a reference that matches nothing on the board, and say which one you dropped; a typo'd blocker shouldn't silently become "unblocked".

### Reconcile, then confirm

Reconcile each ticket against reality, because a previous coordinator session may have died mid-run (see *Re-entrancy* below):

- `in-progress` with a branch that's already merged → it's really **resolved**; write that back now.
- `in-progress` with no live Herdr agent and an unmerged branch → the work exists but nobody is driving it; flag it to the developer.

Print the board as a table — number, title, status, blockers, branch, and the issue number too on a GitHub board — followed by the parsed dependency graph (`03 ← 01, 02`) and ask the developer to confirm the graph reads right before anything launches. A silently mis-parsed blocker launches work against code that doesn't exist yet; this one cheap question turns that into a visible error.

### Writing back to the board

Later phases say to write things "into the ticket file" — run state after a launch (Phase 3), the resolved status and ticked criteria after a verified merge (Phase 4). Read those as **into the home**, and do the equivalent there:

| | File board | GitHub board |
|---|---|---|
| Record run state | write the block into the file, under the heading | post it as a comment (`gh issue comment <n> --body-file …`) and claim the issue: `gh issue edit <n> --add-assignee @me` |
| Update run state | edit the existing block in place | post a fresh comment; the newest run-state comment wins |
| Mark resolved | rewrite the `**Status:**` line | `gh issue close <n> --comment "<the same resolved line>"` — closing *is* the resolved status |
| Tick a criterion | edit the checkbox in the file | rewrite the **issue body** with the box ticked (`gh issue edit <n> --body-file …`) — read it back with `gh issue view <n> --json body`, never reuse a brief |

These use `--body-file` where `docs/agents/issue-tracker.md` writes `--body "..."` with a heredoc. Same thing, deliberately: a run-state block or a ticket body is multi-line Markdown, and a file avoids quoting it twice.

Everything else — verifying the merge, computing the frontier, the launcher and its exit codes — is the same in both homes.

## Phase 2 — Pick what to start

Compute the **frontier**: tickets that are `open` and whose every blocker is already `resolved`. A blocker that's merely `in-progress` does **not** unblock — this run waits for real merges, so there's no reason to build against unmerged code.

Ask the developer which to start (AskUserQuestion, or plainly if the options don't fit): **all of the frontier**, **specific numbers**, or **none**. If they pick numbers that aren't on the frontier, hold those back and name the unmet blocker for each. If none, stop — nothing was changed.

If anything will be launched, also ask once **per session** which model should implement it, with `AskUserQuestion`: "Which model should implement these tickets?" — options **Opus (default)**, **Sonnet**, **Haiku**, **Other…**, Opus listed first and labelled `(default)`. If the board already carries a `**Model:**` line from an `in-progress` ticket (Phase 1 parsed it), say so and offer that model as the pre-selected option instead of Opus, so a resumed session defaults to what's already running rather than silently drifting to a different one; if in-progress tickets disagree (e.g. one wave on Sonnet, another on Opus), list what each is running on and let the developer choose, pre-selecting the most recently launched. If the developer picks the default, still record it explicitly. Keep this answer for the rest of the session: Phase 3 reuses it for every later wave without re-asking, states which model is being used when it launches, and only re-asks if the developer says so.

## Phase 3 — Launch a wave

**Precheck the root before every wave**, not just the first. Between waves the developer has been merging, and `launch.sh` dies with a confusing message if the root isn't where it expects:

```bash
git -C <root> rev-parse --abbrev-ref HEAD   # must be the base branch
git -C <root> status --porcelain            # uncommitted work in the root?
```

If the root is on another branch, mid-merge, or dirty in a way that will block `git pull --ff-only`, tell the developer exactly what to fix and wait. Never checkout, stash, reset, or merge in the root yourself.

For each ticket in the wave, derive names the same way `/ticket` does:

- **Tab label**: 2–3 words, lowercase, up to 20 characters.
- **Branch**: `<type>-<NN>-<slug>`, kebab-case, up to 40 characters, no `/` and no `--` (`type` ∈ `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`, `ci`).

Save the ticket file's full body to a temp file (`mktemp -t ticket.XXXXXX.md`) and run **`/ticket`'s launcher** — this skill deliberately doesn't ship its own, the mechanics and the agent prompt are identical. State which model is being used (the session's answer from Phase 2) before launching:

```bash
~/.claude/skills/ticket/scripts/launch.sh "<label>" "<branch>" "<ticket-file>" "<model>"
```

It discovers the repo root, fast-forwards the base branch, creates the worktree with one synchronous `herdr worktree create` (still at `../<repo>--<branch>`, so `gd` keeps working), splits the root pane it returns, starts Claude Code unattended (no plan mode, `git add`/`commit`/`push`/`stash`/`reset`/`rebase`/`checkout`/`switch` blocked at the tool level) and sends `ticket/templates/ticket-agent-prompt.md`. The launched agent implements and reviews, then **stops with everything unstaged** — the developer reviews, commits, and merges. That boundary doesn't move; you are not here to commit for them.

Exit codes, exactly as `/ticket` handles them: **0** → next ticket; **3** → tell the developer to answer the trust dialog in that tab, then run the printed `launch.sh prompt …` command once they confirm; **other** → read the error (a failed creation carries Herdr's own message, not a timeout), don't delete branches or worktrees, try the next ticket. Launch one ticket at a time and keep each summary block.

Immediately after a successful launch, **write the run state into the ticket file** — this is the coordinator's only durable memory:

```
**Status:** in-progress
**Branch:** <branch>
**Model:** <model>
**Worktree:** <worktree path>
**Agent:** <herdr agent name>  **Tab:** <tab id>
```

Put these lines right under the `# <NN>: <Title>` heading, above `**What to build:**`. Update an existing block rather than appending a second one.

## Phase 4 — Coordinate (attended: the developer reports merges)

Coordination is **attended**: the developer tells you when they've merged something, and that message is what starts a round. Don't poll on a timer and don't try to wait out a merge inside one turn — a merge is a human action that lands hours later. List the wave (tab, branch, worktree, agent), say plainly that you're waiting to be told about merges, and end the turn.

Each round — triggered by the developer, or by anything else worth a check — do the following for every `in-progress` ticket.

**Has the agent finished?** `herdr agent get <agent>` — `idle`/`done` means the implement-and-review pass is over and the worktree is waiting for human review; `blocked` means it's sitting at a dialog. Report either once (don't re-report the same state every round), and never answer a blocked dialog yourself. `Monitor` (load it with `ToolSearch`, `select:Monitor`) is fine for a **short in-turn wait** on an agent about to go idle; foreground `sleep` is blocked. Never use it to wait on a merge.

**Verify the merge — don't take it on trust.** The developer saying "01 is merged" starts the check; it doesn't replace it. Pull the base branch up to date first, then test ancestry:

```bash
git -C <root> pull --ff-only <remote> <base>     # root on the base branch and clean; otherwise:
git -C <root> fetch <remote> <base>              # ...and verify against <remote>/<base> instead
git -C <root> merge-base --is-ancestor <branch> <base>
```

If the root isn't on the base branch or the pull won't fast-forward, say so and fetch instead — never checkout, stash, reset, or merge in the root to make the pull work.

If ancestry says no, check for a **squash or rebase merge**, which rewrites the commits and so leaves no ancestry for `merge-base` (or `git branch --merged`) to find — this is GitHub's default, so a negative ancestry check is never proof on its own:

```bash
gh pr list --head <branch> --state merged --json number,mergedAt,mergeCommit
```

If both come back negative, tell the developer the merge isn't visible from the root yet — unpushed, or pushed to a different base — and ask rather than guessing. Only if `gh` is unavailable *and* ancestry can't see it (a local merge on a branch you can't reach) do you record it on their word alone, and say that's what you did.

**On a verified merge**, in this order:

1. Edit the ticket file: `**Status:** resolved — merged into <base> as <short sha> on <YYYY-MM-DD>`, keep the `**Branch:**` and `**Model:**` lines — the latter is the historical record of what implemented it — drop the `**Agent:**`/`**Tab:**` line, and tick the acceptance-criteria checkboxes only if the developer confirms they're met — don't tick them on your own authority.
2. Recompute the frontier over the whole board. Every ticket whose last open blocker just closed is now startable.
3. If anything became startable, tell the developer what unblocked and run **Phase 3** again for it (precheck the root first — they've just been merging). Ask before launching if the wave is more than a couple of tickets or they asked to be consulted; otherwise launch it and report.
4. Mention, don't do, the cleanup: the worktree at `<worktree>` and branch `<branch>` are now finished, and `gd <repo>--<branch>` removes them. Removing a worktree isn't yours to decide.

End every round with what moved: merges verified and recorded, tickets launched, agents now waiting on review, what's still blocked by what — and the one thing you're waiting on next. When every selected ticket is `resolved` and nothing is left on the frontier, say the board is done.

## Re-entrancy

The ticket files are the state store, not this conversation. If this session is compacted, killed, or the developer closes the tab, re-running `/implement-tickets <same path>` rebuilds the whole picture from the files plus git — Phase 1's reconciliation is exactly that recovery path. So: **write status back to the files as things happen**, not in a batch at the end. A coordinator that only remembers the run in context is a coordinator that loses it.
