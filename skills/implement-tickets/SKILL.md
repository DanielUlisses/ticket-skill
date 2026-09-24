---
name: implement-tickets
description: Implements tickets that are already written. Reads a directory of ticket files (default `.scratch`), asks which to start, launches one unattended Herdr coordinator per frontier ticket, then stays on as the ticket coordinator — verifying each merge the developer reports, marking that ticket resolved in its file, and launching whatever the merge unblocks. For a rough idea that still needs grilling and splitting, use /ticket; for a single ad-hoc ticket, use /small-ticket.
argument-hint: "[path to the tickets directory]"
disable-model-invocation: true
allowed-tools: Bash(~/.claude/skills/ticket/scripts/launch.sh *), Bash(herdr *), Bash(git *), Bash(gh *), Bash(mktemp *), Bash(ls *), Bash(cat *), Bash(find *), Bash(grep *), Bash(awk *), Read, Write, Edit, Glob, Grep, AskUserQuestion, ToolSearch, Monitor
---

# /implement-tickets

Tickets path received (may be empty):

<path>
$ARGUMENTS
</path>

The tickets already exist. Skip grilling and breakdown entirely — `/ticket` phases 1–3 already happened, or the developer wrote the files by hand. You start at implementation, and then **you stay**: this session is the **ticket coordinator** for the whole run, not just a launcher.

Two jobs, in order:

1. **Launch** an unattended Herdr coordinator per frontier ticket, exactly as `/ticket` phase 4 does.
2. **Coordinate**: when the developer tells you a ticket has merged, verify it against the base branch, mark it resolved in its file, and launch whatever that unblocks — until the board is done or the developer stops you.

## Phase 0 — Find the tickets

Resolve the **main repo root** first (this session may be inside a worktree):

```bash
git worktree list --porcelain | awk 'NR==1 && /^worktree /{ sub(/^worktree /, ""); print }'
```

Then resolve the path:

- **Argument given** — use it, relative to the main repo root unless it's absolute.
- **Empty** — default to `<root>/.scratch`.

Now find the ticket files under it (`*.md`, recursively). `/ticket` writes them as `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, so a bare `.scratch` is two levels above the tickets and may hold **several feature directories**. If the path resolves to more than one feature directory, list them and ask the developer which one (AskUserQuestion). If it resolves to no `.md` files at all, say so with the path you looked in and stop — don't invent tickets.

Also check whether the tickets are ignored by git (`git check-ignore <path>`; exit 1 means **not ignored**). If they aren't ignored, mention once that marking tickets resolved will dirty the repo root, and that `.scratch/` in `.gitignore` avoids it. Don't edit `.gitignore` yourself.

## Phase 1 — Read the board

Read every ticket file. For each, extract:

- **Number and title** from the `# <NN>: <Title>` heading (fall back to the filename).
- **Status** from a `**Status:**` line — one of `open`, `in-progress`, `resolved`. **A missing `Status` line means `open`**; `/ticket` writes files without one, and this skill has to read those unchanged.
- **Branch** from a `**Branch:**` line, if a previous run recorded one.
- **Blocked by** from the `**Blocked by:**` line. This is free text — `01, 02`, `None (can start immediately)`, `Ticket 02 (schema)`. Parse it leniently: case-insensitive `none` (or empty) means no blockers; otherwise take every digit-run on that line as a ticket number.
- **Model** from a `**Model:**` line, if a previous run recorded one — that's what that ticket's coordinator is (or was) running on. Absent on a fresh board; present once Phase 3 has launched it at least once.

Then reconcile each ticket against reality, because a previous coordinator session may have died mid-run (see *Re-entrancy* below):

- `in-progress` with a branch that's already merged → it's really **resolved**; write that back now.
- `in-progress` with no live Herdr agent and an unmerged branch → the work exists but nobody is driving it; flag it to the developer.

Print the board as a table — number, title, status, blockers, branch — followed by the parsed dependency graph (`03 ← 01, 02`) and ask the developer to confirm the graph reads right before anything launches. A silently mis-parsed `Blocked by:` line launches work against code that doesn't exist yet; this one cheap question turns that into a visible error.

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

It discovers the repo root, fast-forwards the base branch, creates the tab, runs `ga <branch>`, splits the pane, starts Claude Code unattended (no plan mode, `git add`/`commit`/`push`/`stash`/`reset`/`rebase`/`checkout`/`switch` blocked at the tool level) and sends `ticket/templates/ticket-agent-prompt.md`. The launched agent implements and reviews, then **stops with everything unstaged** — the developer reviews, commits, and merges. That boundary doesn't move; you are not here to commit for them.

Exit codes, exactly as `/ticket` handles them: **0** → next ticket; **3** → tell the developer to answer the trust dialog in that tab, then run the printed `launch.sh prompt …` command once they confirm; **other** → read the error, don't delete branches or worktrees, try the next ticket. Launch one ticket at a time and keep each summary block.

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
