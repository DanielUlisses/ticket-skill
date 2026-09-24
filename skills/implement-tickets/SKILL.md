---
name: implement-tickets
description: Implements tickets that are already written. Reads the board from wherever the repo keeps tickets — GitHub issues where it has a tracker, files under `.scratch` where it doesn't — asks which to start, launches one unattended Herdr coordinator per frontier ticket, then stays on as the ticket coordinator — opening each round by re-reading the board, the live agents and git, verifying each merge against that, marking the ticket resolved in its home, and launching whatever the merge unblocks. For a rough idea that still needs grilling and splitting, use /ticket; for a single ad-hoc ticket, use /small-ticket.
argument-hint: "[tickets directory, or a ticket label / feature slug]"
disable-model-invocation: true
allowed-tools: Bash(~/.claude/skills/ticket/scripts/launch.sh *), Bash(herdr *), Bash(git *), Bash(gh *), Bash(mktemp *), Bash(ls *), Bash(cat *), Bash(find *), Bash(grep *), Bash(awk *), Bash(jq *), Bash(diff *), Bash(mv *), Read, Write, Edit, Glob, Grep, AskUserQuestion, ToolSearch, Monitor
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

Both jobs run off the same **digest** (Phase 1): one cheap re-read of the board, the live agents and git, taken at the top of every round. Nothing in this skill is reported from memory of an earlier round.

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

## Phase 1 — The digest

**This is not a startup step.** It is the top of **every** coordination round: the first one, every round in Phase 4, and the first round after a compaction or a restart. Run it in full each time and report from what it returns, never from what you remember of an earlier round. A long-running session's picture of the board drifts; a re-read doesn't — and a coordinator that re-reads is re-entrant by construction, because the round and the recovery are the same procedure.

Read every ticket in the home. Whichever home it is, each one comes out as the same fields — **number**, **title**, **status** (`open`, `in-progress`, `resolved`), **blockers**, **branch**, **base**, **model**, **account**, and, once it's been launched, its **agent name** — and every phase after this works off those. The last five are absent on a fresh board and present once Phase 3 has recorded run state.

### What a digest is, and what it isn't

Three reads, each a fixed number of calls that doesn't grow with how long the session has been running:

1. **The board and its statuses** — one call, parsed per home (below).
2. **The live agent states** — one call for all of them.
3. **Git's view of what has landed** — one fetch, one ancestry sweep, one merged-PR list.

It **must** cover every ticket on the board, not only the ones that moved last round; a live state for every agent the board records; and a landed-or-not answer for every branch the board records.

It **must not** include:

- **Ticket bodies.** Six fields per ticket, never the prose. A brief is composed for one ticket at the moment it launches (Phase 3), and a body is read back only to tick a checkbox (*Writing back to the board*). Re-reading every body every round is the one thing that would make this too expensive to run every round.
- **Agent scrollback.** No `herdr agent read`, no pane contents, no terminal titles. A lifecycle state is one word; what the agent is saying is the developer's business.
- **Diffs, logs, or worktree listings.** Ancestry answers landed-or-not, and nothing in a round needs to know what changed inside a branch.
- **Anything that writes.** No launches, no status write-backs, no closes, no assignee changes. The digest is read-only; Phases 2–4 are what act on it.
- **Anything that waits.** No `Monitor`, no `herdr agent wait`, no polling. A digest is a snapshot and ends in the turn it started.
- **The repo's project memory.** It's prose, and it's read once per *launch* by the launcher (`docs/agents/memory.md`), not once per round. A digest that carried it would pay for it every round to tell you nothing that changed.
- **Detail on resolved tickets** beyond their status line. Their blockers are satisfied and their worktrees are gone; the status is all the board still needs from them.

### Read 1 — the board and its statuses

One call, and only the six fields. Parse it per home:

#### From a file board

One call for the whole board, and it reads the header lines without pulling in the prose under them:

```bash
grep -rHn -E '^# [0-9]+:|^\*\*(Status|Branch|Base|Model|Effort|Account|Worktree|Agent|Blocked by|Suggested effort):' <path> --include='*.md'
```

- **Number and title** from the `# <NN>: <Title>` heading (fall back to the filename).
- **Status** from a `**Status:**` line. **A missing `Status` line means `open`**; `/ticket` writes files without one, and this skill has to read those unchanged.
- **Branch** from a `**Branch:**` line, if a previous run recorded one.
- **Base** from a `**Base:**` line — the commit the branch was cut from. Read 3's empty-branch guard needs it, so a run state without it degrades that read; see there for the fallback.
- **Agent** from the `**Agent:**` line, the name read 2 matches on.
- **Blocked by** from the `**Blocked by:**` line.
- **Model**, **Effort** and **Account** from the `**Model:**`, `**Effort:**` and `**Account:**` lines, if a previous run recorded them — the session settings that ticket's coordinator is (or was) running on. Absent on a fresh board; present once Phase 3 has launched it at least once, and what Phase 2 pre-selects for a resumed session.
- **Suggested effort** from the `**Suggested effort:**` line `/ticket` wrote into the body. Unlike the three above, it is the ticket author's recommendation rather than a record of a run, and it is what Phase 2 pre-selects on a board nothing has launched yet. Tickets written before that line existed carry none.

#### From a GitHub board

One call reads the whole board, dependencies included — drop `--label` on an unlabelled board:

```bash
gh issue list --label "ticket:<slug>" --state all --limit 200 \
  --json number,title,state,assignees,labels,blockedBy,comments
```

No `body`. The digest doesn't carry ticket prose (*What a digest is, and what it isn't*) — Phase 3 reads the one body it's about to launch. The exception is a board whose issues carry **no** native dependencies at all: there the edges live only in the body, so add `body` to the call and keep nothing from it but the `**Blocked by:**` line. The first digest settles which case the board is.

Of `comments`, keep only the newest run-state block per ticket and drop the rest unread; a discussion thread is not state.

- **Number and title** from the issue title's `<NN>: <Title>`. The ticket number is the `NN` prefix, **not** the issue number; keep both, because `NN` orders the board and the issue number is what you act on. On an unlabelled board, an issue whose title carries no `<NN>:` prefix isn't a ticket — skip it.
- **Status**: a **closed** issue is `resolved`. An open one is `in-progress` if it's **assigned** or carries a **run-state comment** from a previous wave (see *Writing back to the board*), and `open` otherwise. Both signals are in the call above — that's why it asks for `assignees` and `comments`. An assignee alone means in-progress even with no run-state comment: `docs/agents/issue-tracker.md` treats assignment as the claim, so somebody is on it whether or not this skill launched them.
- **Blocked by** from `blockedBy.nodes` — GitHub's native issue dependencies, which is where `/ticket` phase 2 puts the edges. A node that's still `OPEN` is a live blocker; a `CLOSED` one is satisfied:

  ```bash
  --jq '[.[] | {number, open_blockers: [.blockedBy.nodes[] | select(.state == "OPEN") | .number]}]'
  ```

  This is the same gate `docs/agents/issue-tracker.md` names as `issue_dependencies_summary.blocked_by`, reached through the CLI instead of the REST API: that field counts **open** blockers only, so a `select(.state == "OPEN")` count over `blockedBy.nodes` equals it, and `nodes | length` equals its `total_blocked_by`. Use the CLI form — `issueDependenciesSummary` is not a `gh --json` field, and `gh api` per issue would be one call per ticket instead of one for the board.

  Where an issue carries **no** dependencies at all, fall back to the `**Blocked by:**` line in its body — a board written before dependencies were available, or one whose repo refused the endpoint, has its edges only there.
- **Branch**, **Base**, **Model**, **Account** and the **agent name** from the newest run-state comment — the same lines a file board keeps in the file, so both homes feed reads 2 and 3 identically. A run state with no `**Base:**` degrades read 3's guard; see there.

#### Blockers are free text either way

The `**Blocked by:**` line is free text — `01, 02`, `#12, #13`, `None (can start immediately)`, `Ticket 02 (schema)`. Parse it leniently: case-insensitive `none` (or empty) means no blockers. Otherwise, a digit-run written as `#<n>` is an **issue** number — resolve it straight against the board — and a bare digit-run is a ticket `NN`, resolved through the `NN` you parsed from each heading or title. Ignore a reference that matches nothing on the board, and say which one you dropped; a typo'd blocker shouldn't silently become "unblocked".

### Read 2 — the live agent states

One call for the whole session, not one `herdr agent get` per ticket:

```bash
herdr agent list | jq -r '.result.agents[] | select(.name) | "\(.name)\t\(.agent_status // "unknown")\t\(.tab_id // "-")"'
```

The fallbacks are deliberate: as everywhere else in these skills, the installed binary is the authoritative syntax, not this file (`skills/small-ticket/SKILL.md`). If the shape has moved, read `herdr agent list` raw and take the same three values by hand rather than reporting every agent as missing.

`name` is the agent the launcher created (`tk-<branch>`), so it joins straight onto the `**Agent:**` line in run state. `agent_status` is one of `idle`, `working`, `blocked`, `done`, `unknown` — the meaning of each is in Phase 4, which is the phase that acts on it.

An agent the board records but the list doesn't return is **gone** — its session died or its pane was closed. That absence is the signal, not an error.

### Read 3 — what git says has landed

Against the **main repo root** resolved in Phase 0, and read-only. The digest **fetches; it never pulls**: a pull needs the root clean and on the base branch, and a read that breaks on the developer's dirty working tree isn't a read you can run every round.

Fetch once, then ask three things **per in-progress branch**. Substitute the values in literally — write out the branch and the sha rather than looping or assigning, because each Bash call is a fresh shell and a variable set in one doesn't survive into the next:

```bash
git -C <root> fetch <remote> <base> --quiet

# 1. has this branch any commits of its own? 0 -> nothing to land; stop here for it
git -C <root> rev-list --count <the ticket's Base sha>..<branch>

# 2. only when that count is non-zero — exit 0 from either one means landed
git -C <root> merge-base --is-ancestor <branch> <remote>/<base>
git -C <root> merge-base --is-ancestor <branch> <base>

# 3. and, because a squash merge leaves no ancestry to find
gh pr list --head <branch> --state merged --json number,mergedAt,mergeCommit
```

Only **in-progress** branches are swept: that's a wave, usually a handful, not the whole board — a resolved ticket's branch is often deleted and its answer is already recorded. Keep step 3 scoped to `--head <branch>`: a board-wide `gh pr list --state merged --limit <n>` looks cheaper but silently loses any branch that merged beyond the newest `<n>` PRs.

**The empty-branch guard is not optional.** The launcher creates the branch *at* the base, and the agent it launches can't commit, so a freshly launched branch still has the base as its tip — and `merge-base --is-ancestor` answers `ancestor` for it, every time. Without step 1 the digest reads a ticket that hasn't started as one that has landed, and Phase 4 closes it. The `**Base:**` sha in run state is what tells the two apart. Where a run state predates that line, use `git merge-base <branch> <remote>/<base>` as the sha and lean on step 3, which has no such failure mode. If step 1 errors rather than printing a number — a deleted branch, a `**Base:**` that no longer resolves — that's **unknown**, not zero and not landed: say which branch and leave the ticket where it is.

Step 2 tests both bases, because a merge the developer hasn't pushed is visible only against the local one.

**And ancestry alone is never proof.** A squash or rebase merge rewrites the commits and leaves nothing for `merge-base` (or `git branch --merged`) to find. That's GitHub's default, and it's what this repo itself uses — every branch that has landed here answers `no-ancestor`. So steps 2 and 3 both run every round, and a branch has landed if **either** says so.

### The digest line, and what changed since last round

Fold the three reads into **one line per ticket**, ordered by `NN`, fields in this fixed order, `-` where there's nothing:

```
<NN> <status> <#issue|file> <branch> <agent-state> <landed> <open-blockers>
```

Every field is one whitespace-free token, so a line stays comparable: `<status>` is the bare `open`/`in-progress`/`resolved`, never the resolved line's prose; `<open-blockers>` is comma-separated. A **resolved** ticket collapses to `<NN> resolved <#issue|file> - - - -` — the digest keeps no detail on resolved tickets (*What a digest is, and what it isn't*), and a line that dropped its branch and agent doesn't churn again when the worktree is cleaned up.

Write the whole set to a file at a path you can **derive rather than remember** — `/tmp/implement-tickets-digest-<board-slug>.txt`, where the slug is `<owner>-<repo>` (plus the label, where the board has one) for a GitHub board, or the board path with `/` replaced by `-` for a file board. A remembered `mktemp` path is recalled state, and recalled state is the thing this phase exists to stop trusting; a derived one is still there after a compaction. Write both files with the `Write` tool, then:

```bash
diff /tmp/implement-tickets-digest-<slug>.txt /tmp/implement-tickets-digest-<slug>.new.txt
mv /tmp/implement-tickets-digest-<slug>.new.txt /tmp/implement-tickets-digest-<slug>.txt
```

`diff` exits 1 whenever the files differ. On this path that's the ordinary case — a round where something moved — not a failed command.

**That diff is the round's report.** A ticket whose line is unchanged hasn't moved, so it isn't mentioned again — not its agent state, not its blockers, not "still waiting on review". Say nothing rather than repeat; the developer reads a short round as "nothing moved", and a repeated one as noise to skim past.

Everything you say about a status, an agent or a merge comes from **this** round's lines. If the digest doesn't say it, don't say it. Where the digest contradicts what you said last round, the digest wins: restate it and move on, without narrating the drift.

**The first digest of a session reports the whole board**, diff or no diff — a fresh start owes the developer the full picture, and so does a session that died mid-run and came back. From round two on, the diff is the report. A derived path means a restarted session finds the previous round's file and picks the diff back up immediately; a missing file just means everything reads as new, which is the same answer.

### Reconcile

The digest itself writes nothing (*What a digest is, and what it isn't*). Reconciling is the first thing done **with** a digest, once all three reads are in — and it's a write, into the home.

The three reads disagree with each other whenever a previous coordinator session died mid-run (see *Re-entrancy*). The reads are the evidence; the home is the record:

- `in-progress`, and read 3 says the branch **landed** → it's really **resolved**; write that back now (Phase 4's step 1).
- `in-progress`, read 2 has **no live agent**, and the branch hasn't landed → the work exists but nobody is driving it; flag it to the developer.
- `in-progress`, read 2 says **blocked** → the agent is sitting at a dialog; name the tab and leave it to the developer.

This isn't startup-only repair. It's what the digest does every round, which is what makes a round and a recovery one procedure instead of two.

### Confirm the graph — first digest only

On the **first** digest of a session, print the board as a table — number, title, status, blockers, branch, and the issue number too on a GitHub board — followed by the parsed dependency graph (`03 ← 01, 02`), and ask the developer to confirm the graph reads right before anything launches. A silently mis-parsed blocker launches work against code that doesn't exist yet; this one cheap question turns that into a visible error.

Later rounds neither re-ask nor reprint the table: the parse hasn't changed, and the diff already says what has. Re-ask only when a digest shows the edges themselves changed.

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

Compute the **frontier** from the digest you just took: tickets that are `open` and whose every blocker is already `resolved`. A blocker that's merely `in-progress` does **not** unblock — this run waits for real merges, so there's no reason to build against unmerged code.

Ask the developer which to start (AskUserQuestion, or plainly if the options don't fit): **all of the frontier**, **specific numbers**, or **none**. If they pick numbers that aren't on the frontier, hold those back and name the unmet blocker for each. If none, stop — nothing was changed.

### The session's launch settings

Only if something will be launched — a round that starts nothing asks nothing, and neither does a session that never reaches a wave.

Three things govern every ticket a session launches: the **account** it bills to, the **model** that implements it, and the **effort** — how hard that model thinks — it runs at. They are settled **once**, at the first wave of the session, and every later wave reuses the answer without re-asking — as does anything `/ticket` or `/small-ticket` launches later in the same session.

**Already settled** — this session answered, for an earlier wave or because the developer named them up front: don't ask again. State which account, model and effort are in force when you launch and move on.

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

The `ACCOUNT=` name is the one a **new worktree** would inherit. That is not the same question as which account *this* session is running under, and the difference is the entire reason this is asked: a session in a worktree that overrode its own account would otherwise offer that account as the default and launch the whole wave somewhere else. Quote what the command printed.

`EFFORT=` is the level an unnamed launch would run at, and its source is named the same way `MODEL=`'s is. On a machine whose `ticket-models.env` predates this knob it reads `(from the launcher's built-in fallback — nothing set it in <path>)`, which is `medium` and is correct: `install.sh` never overwrites a hand-held destination copy, so that file keeps saying nothing about effort until the developer deletes it. `EFFORTS=` is the list of levels to offer, printed by the launcher so no skill has to keep its own copy of it.

**A resumed board answers part of it for you.** Where an `in-progress` ticket carries a `**Model:**`, `**Effort:**` or `**Account:**` line (Phase 1 parsed all three), that is what this board is *already* running on — say so and pre-select it over the launcher's default, so a resumed session stays with its wave instead of silently drifting onto another model or another subscription. Where in-progress tickets disagree (one wave on Sonnet, another on Opus), list what each is running on and pre-select the most recently launched. Whatever the board says nothing about still comes from `defaults`.

**The tickets suggest the effort, where the board has recorded none.** Each ticket `/ticket` wrote carries a `**Suggested effort:**` line. Pre-select, in this order: the effort in-progress tickets are already running on, else the level the *wave's* tickets suggest, else `EFFORT=`. Where the wave's suggestions disagree, name the spread and pre-select the highest of them — the ticket that asked for more thinking is the one that loses by getting less, and a single ticket can still be launched at its own level as a per-ticket override.

On a **file board** the digest already carries the line. On a **GitHub board** it lives in the issue body, which the digest deliberately leaves out — so read it for the wave alone, with the same `gh issue view <n> --json body --jq .body` Phase 3 makes, keeping nothing from the body but that one line. The digest's no-prose rule is about the board, not about the handful of tickets already chosen to launch.

Then ask with **one** `AskUserQuestion` call, one question per setting:

| Setting | Question | Options, in order | How it reaches the launcher |
|---|---|---|---|
| Account | "Which Claude account should this session's tickets run on?" | the pre-selected name first — the board's, else the `ACCOUNT=` one labelled `(default — inherited)` — then the rest of `ACCOUNTS=` | `--account <name>` — and the inherited default passes **no flag at all**, since inheriting is what writes no link |
| Model | "Which model should implement this session's tickets?" | the pre-selected value first — the board's, else the `MODEL=` one labelled `(default)` — then the other two of Opus / Sonnet / Haiku, then **Other…** — the launcher takes any model id, a pinned one included | the positional `[model]`, always explicitly, even when it is the default, so the summary and the recorded run state agree with what launched |
| Effort | "How hard should the model think on this session's tickets?" | the pre-selected level first — the board's, else the wave's suggestion labelled `(suggested by the tickets)`, else the `EFFORT=` one labelled `(default)` — then the rest of `EFFORTS=` | `--effort <level>`, always explicitly, even when it is the default, so the summary and the recorded run state agree with what launched |

One call with one question per setting, not one question then another: a further setting is another row here, another field you carry, and another line in the run state Phase 3 records — not another round of questions.

**Then hold them.** Every launch in this session passes all three, records all three in the ticket's run state, and names all three in the round's report. Two overrides exist and they are different things:

- **For one ticket** — the developer names an account, a model or an effort for a single launch. It goes to that launch alone, is recorded on that ticket, and leaves the session's settings standing for the rest of the wave.
- **For the session** — the developer asks to change the setting itself. Replace it, say so, and use the new value for every launch after it. Tickets already running keep what they launched on; the run state is what each is on, not what the session now says.

Neither is a reason to re-ask on the next wave; re-ask only when the developer asks you to. See `docs/agents/session-settings.md`.

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

Now — and only now — read the **body** of each ticket in the wave, the prose the digest deliberately leaves out. On a GitHub board that's `gh issue view <n> --json body --jq .body` for the one ticket you're about to launch.

Compose the **brief**: the ticket as the coordinator will receive it — the body with `# <NN>: <Title>` put back on top and a `**Tracker:** <owner>/<repo>#<issue> — report against it, don't close it` line under it, so the launcher and the agent prompt never know which home it came from. Keep **brief** and **issue body** apart: the brief is composed fresh for each launch and is never written back, and the issue body is what actually lives on the tracker. Editing the issue with a brief would duplicate the title as an H1 and plant a `**Tracker:**` self-reference that was never there.

Save the brief to a temp file (`mktemp -t ticket.XXXXXX.md`) and run **`/ticket`'s launcher** — this skill deliberately doesn't ship its own, the mechanics and the agent prompt are identical. State which account and model the wave is using (the session's settings from Phase 2) before launching:

```bash
~/.claude/skills/ticket/scripts/launch.sh [--account <name>] --effort "<level>" "<label>" "<branch>" "<ticket-file>" "<model>"
```

All three values come from Phase 2 and cover the whole wave. `--account <name>` is passed only
where the session settled on a named account; where it inherits, the flag is left off
entirely and each ticket resolves the developer's own directory link, as every ticket did
before this knob existed. `--effort <level>` is passed always — there is no "inherit" for it,
and a level the launcher doesn't know stops that ticket before anything is created, since
Claude Code itself would only warn and then run at its own default. A wave is exactly where a
named account pays — rate limits meter per account, so spreading a wave across two
subscriptions doubles the headroom — and a
per-ticket override the developer names for one ticket leaves the wave's setting standing.
Every summary's `ACCOUNT=`, `MODEL=` and `EFFORT=` lines record what each ticket actually ran
on; the account is verified in its pane. See `docs/agents/accounts.md` and `docs/agents/session-settings.md`.

It discovers the repo root, fast-forwards the base branch, creates the worktree with one synchronous `herdr worktree create` (still at `../<repo>--<branch>`, the path convention `/sweep-tickets` reports against), splits the root pane it returns, starts Claude Code unattended (no plan mode, `git add`/`commit`/`push`/`stash`/`reset`/`rebase`/`checkout`/`switch` blocked at the tool level) and sends `ticket/templates/ticket-agent-prompt.md` — folding in the repo's `docs/agents/project-memory.md` where the main checkout keeps one, so every ticket in every wave starts with the same project knowledge (`docs/agents/memory.md`). You do nothing to arrange that: it's the launcher's, and a repo without memory launches unchanged. The launched agent implements and reviews, then **stops with everything unstaged** — the developer reviews, commits, and merges. That boundary doesn't move; you are not here to commit for them.

Exit codes, exactly as `/ticket` handles them: **0** → next ticket; **3** → tell the developer to answer the trust dialog in that tab, then run the printed `launch.sh prompt …` command once they confirm; **other** → read the error (a failed creation carries Herdr's own message, not a timeout), don't delete branches or worktrees, try the next ticket. Launch one ticket at a time and keep each summary block.

Immediately after a successful launch, **write the run state into the ticket file** — this is the coordinator's only durable memory:

```
**Status:** in-progress
**Branch:** <branch>
**Base:** <sha>
**Model:** <model>
**Effort:** <level>
**Account:** <account>
**Worktree:** <worktree path>
**Agent:** <herdr agent name>  **Tab:** <tab id>
```

`Model`, `Effort` and `Account` are what this ticket actually launched on — the launcher's own `MODEL=`, `EFFORT=` and `ACCOUNT=` lines rather than what was asked for; the account one is verified in the pane. `Effort` is a record of the run and is distinct from the body's `**Suggested effort:**`, which is the ticket author's recommendation and never rewritten. A later change to the session's settings doesn't rewrite any of them: they say what this ticket is running on.

`Base` is the commit the branch was cut from — `git -C <worktree> rev-parse HEAD` straight after the launch, before anything is committed on it.

Put these lines right under the `# <NN>: <Title>` heading, above `**What to build:**`. Update an existing block rather than appending a second one.

This block is what the next round's digest joins on: `**Branch:**` is what read 3 sweeps, `**Base:**` is what keeps read 3 from mistaking a branch with no commits for a landed one, and `**Agent:**` is what read 2 matches by name. A launch you don't write back is a launch the next digest can't see — and the next digest is all the coordinator will have.

## Phase 4 — Coordinate (attended: the developer reports merges)

Coordination is **attended**: the developer tells you when they've merged something, and that message is what starts a round. Don't poll on a timer and don't try to wait out a merge inside one turn — a merge is a human action that lands hours later. List the wave (tab, branch, worktree, agent), say plainly that you're waiting to be told about merges, and end the turn.

**Every round opens with the digest.** Run **Phase 1** in full — board, agents, git — before saying anything about the board, and work from its diff. A round is triggered by the developer, or by anything else worth a check; nothing is triggered by memory, and nothing skips the digest because "nothing can have changed since last round".

The digest has already answered the two questions this phase used to ask ticket by ticket:

**An agent that finished** — read 2 says `idle` or `done` — has ended its implement-and-review pass, and its worktree is now waiting on the developer. Tell them it's ready for review, once. `blocked` means it's sitting at a dialog: name the tab so they can answer it, and never answer it yourself. `working` needs nothing said. `Monitor` (load it with `ToolSearch`, `select:Monitor`) is fine for a **short in-turn wait** on an agent about to go idle; foreground `sleep` is blocked. That wait is a deliberate step outside the digest, and never a way to wait on a merge.

**A branch that landed** — read 3, by either leg — is a **verified merge**, and the steps below act on it. The developer saying "01 is merged" is what **starts** a round; it isn't what proves the merge, and it isn't needed for one. A merge read 3 can see is verified whether or not anybody mentioned it.

**When a reported merge isn't in the digest**, both legs came back negative. Say so instead of guessing: the branch is unpushed, or pushed to a different base. Ask. Only if `gh` is unavailable *and* ancestry can't see it (a local merge on a branch you can't reach) do you record it on the developer's word alone, and say that's what you did.

The digest fetches and never pulls, so the root's own `<base>` may lag behind `<remote>/<base>`. Moving it up is `git -C <root> pull --ff-only <remote> <base>` with the root clean and on the base branch — Phase 3's precheck, before a launch, not a step in every round. Never checkout, stash, reset, or merge in the root to make a pull work.

**On a verified merge**, in this order:

1. Edit the ticket file: `**Status:** resolved — merged into <base> as <short sha> on <YYYY-MM-DD>`, keep the `**Branch:**`, `**Base:**`, `**Model:**` and `**Account:**` lines — the last two are the historical record of what implemented it and what paid for it — drop the `**Agent:**`/`**Tab:**` line, and tick the acceptance-criteria checkboxes only if the developer confirms they're met — don't tick them on your own authority.
2. Recompute the frontier over the whole board, from this round's digest lines. Every ticket whose last open blocker just closed is now startable.
3. If anything became startable, tell the developer what unblocked and run **Phase 3** again for it (precheck the root first — they've just been merging). Ask before launching if the wave is more than a couple of tickets or they asked to be consulted; otherwise launch it and report.
4. Mention, don't do, the cleanup: the workspace, tabs, worktree at `<worktree>` and branch `<branch>` are now finished, and `/sweep-tickets` lists them with everything else the board has left behind and removes what the developer confirms. Removing a worktree isn't yours to decide — point at the sweep and leave it there. Don't run it, and don't describe the removal commands by hand: that skill's guards (never a dirty worktree, never a blanket delete) are the reason it exists.

End every round with what moved — which is what the digest diff already narrowed it to: merges verified and recorded, tickets launched, agents that reached review, what's newly blocked or unblocked, and the one thing you're waiting on next. A round where the diff was empty is worth exactly one line saying so. When every selected ticket is `resolved` and nothing is left on the frontier, say the board is done — and say once that `/sweep-tickets` will list and clear the workspaces, worktrees, branches — and, for a wave launched with `--account`, the `claude-acc` links — the run left behind. The links are the one leftover a merge makes unreachable by any other means, so a wave that used `--account` is worth sweeping even when the sidebar already looks empty.

## Re-entrancy

The ticket files are the state store, not this conversation. If this session is compacted, killed, or the developer closes the tab, re-running `/implement-tickets <same path>` rebuilds the whole picture from the files plus the agents plus git — because that's the digest, and the digest is what every round already runs. A restart isn't a recovery mode; it's a round whose previous digest file happens to be missing, so it reports the whole board instead of a diff.

That only holds if the home is current, so: **write status back as things happen**, not in a batch at the end. A run state the digest can't read is a ticket the next round can't see, and a coordinator that only remembers the run in context is a coordinator that loses it.
