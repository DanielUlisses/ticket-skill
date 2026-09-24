---
name: sweep-tickets
description: Lists what the ticket workflow has left lying around — worktrees whose branch already merged, worktrees with no live agent, local branches merged into the base — and removes the ones the developer confirms, one at a time. Listing changes nothing; removal always asks first and never touches a worktree with uncommitted changes. Run it after a wave of tickets has merged; `/implement-tickets` points here instead of naming `gd` by hand.
argument-hint: "[no argument — sweeps the repo you're in]"
disable-model-invocation: true
allowed-tools: Bash(~/.claude/skills/sweep-tickets/scripts/sweep.sh *), Bash(git *), Bash(herdr *), Bash(column *), AskUserQuestion
---

# /sweep-tickets

Every ticket `/ticket` or `/implement-tickets` launches leaves **five** things behind, not one:

a Herdr **workspace**, its three **tabs** (`agent`, `review`, `shell`), their **panes**, a git **worktree**, and a **branch**.

A ticket launched on a named account (`--account`) leaves a **sixth**: a `claude-acc`
directory link. `remove --worktree` takes it with the worktree, and says `REMOVED account
link for <path>` when it does — link entries never expire on their own, so a sweep that
left them would grow `~/.claude-switch/links` a line per ticket forever. A ticket that
inherited its account has no link of its own and nothing is said. See
`docs/agents/accounts.md`.

When the developer merges the PR and moves on, all five stay. Over a few waves they accumulate: a sidebar full of workspaces for work that landed days ago, and a `git branch` list that no longer means anything. Nothing in the workflow clears them, deliberately — `/implement-tickets` names the cleanup and refuses to act on it, because removing a worktree is not a coordinator's decision. This skill is where that decision gets made, with the developer in the room.

**Listing is safe and always available. Removal is opt-in per item, and a worktree with uncommitted changes is never removed — not with `--force`, not on the developer's say-so.**

## Phase 1 — Take the inventory

One call, read-only, from wherever this session happens to be standing:

```bash
~/.claude/skills/sweep-tickets/scripts/sweep.sh list | column -t -s$'\t'
```

It resolves the main repo root itself (`git worktree list --porcelain`, first entry), so it gives the same answer from the checkout or from any ticket's worktree. It fetches the base branch and nothing else — never a pull, which would need the root clean and on the base branch, and a listing that breaks on the developer's dirty root isn't one they can run whenever they like. `--no-fetch` skips even that.

The output is a `#` header plus one tab-separated row per item:

```
# root=<path> base=<remote>/<base> gh=<yes|no> herdr=<yes|no>
# kind	branch	path	state	reason	agent	dirty	workspace	board	flags
```

- **kind** — `worktree` (a checkout on disk) or `branch` (a local branch with no worktree of its own).
- **state** and **reason** — whether the branch's work is in the base, and on what evidence. `merged`/`pr#13`, `merged`/`ancestor:origin/main`, `merged`/`patch-id`, `empty`/`no-commits`, `unmerged`/`no-merged-pr`, `unknown`/`no-gh`.
- **agent** — `<name>:<status>` for a live agent in that worktree's workspace, `none` when Herdr was asked and had nobody, `unknown` when Herdr couldn't be reached at all. Don't read `unknown` as `none`; the header's `herdr=no` says which it is.
  **A live agent is not a reason to keep a worktree.** The ordinary state of a ticket whose PR has merged is an agent still sitting in its pane at `idle` or `done`, having finished its implement-and-review pass hours ago — that *is* what finished looks like. Only `working` and `blocked` (and Herdr's own `unknown`, which it says "does not prove completion") mean removing the pane would interrupt something, and only those hold an item back.
- **dirty** — count of `git status --porcelain` lines, or `-` when the directory is gone.
- **board** — `<NN>:<status>:<landed>` from `/implement-tickets`' digest, where one is on disk (Phase 3 below).
- **flags** — the summary: `orphan`, `merged-branch`, `never-started`, `no-agent`, `agent-idle`, `agent-busy`, `agent-unknown`, `dirty`, `prunable`, `self`, `board-disagrees`, and either `removable` or `keep`. `removable` is computed from exactly the conditions `remove` enforces, so the list never offers an item the script will then refuse.

The header's `gh=` and `herdr=` matter for what you can claim. With `gh=no` a squash merge of several commits is undetectable, and the script says `unknown`/`no-gh` rather than `unmerged` — report that as "can't tell", never as "not merged".

### Why `merged` isn't just ancestry

Ancestry alone gives a **false negative every time** on GitHub's default. A squash merge collapses the branch into one new commit with a new sha, and a rebase merge rewrites them all; either way `git merge-base --is-ancestor` and `git branch --merged` find nothing. Every PR in this repo is squash-merged, so a sweep that trusted ancestry would report a fully-merged board as entirely unmerged. Three legs run instead, first answer wins: ancestry (against the remote base, then the local one, since an unpushed merge is visible only locally), then the merged PR for that branch (`gh pr list --head <branch>`, scoped per branch — a board-wide `--state merged --limit <n>` silently loses anything that merged beyond the newest `<n>`), then patch ids (`git cherry`, which catches a rebase merge with no network at all).

### Why `empty` is its own state, not `merged`

A branch the launcher cut minutes ago sits exactly at the base and has no commits, so **ancestry calls it merged** — and a sweep acting on that would delete a ticket that is still being worked on. The script reads the branch's reflog for the commit it was created at, and counts the commits made since. Zero commits *and* a tip already in the base is `empty`: nothing was ever written here, so there is nothing to have merged and nothing to lose. That's the same trap `/implement-tickets`' digest guards with the `**Base:**` sha from run state; the sweep has no run state to read, and the reflog is the same fact recorded by git itself.

An `empty` worktree is still worth reporting — it's a launch that never got anywhere — but say *why* it's removable ("never started, nothing committed"), never "merged".

## Phase 2 — Report the three groups

Turn the rows into the three groups the developer actually thinks in, in this order, and say plainly when a group is empty:

1. **Orphan worktrees** — `orphan` flag: the branch has landed, so the whole workspace is finished. Give the branch, the evidence (`pr#13`), the workspace id, and whether an agent is still sitting in it.
2. **Worktrees with no live agent** — `no-agent`: the session died or the pane was closed. This overlaps group 1 and that's fine; say which rows are in both. An **unmerged** worktree with no agent is the interesting one — work in progress that nobody is driving, and the one row in this group that isn't routine cleanup.
3. **Merged branches** — `merged-branch`: a local branch with no worktree left, from a `gd` or a hand-removed checkout.

Then the rows that are **not** on offer, with the reason, because a sweep that silently omits them reads as "nothing else is there":

- `dirty` — uncommitted changes, so never removable.
- `agent-busy` — the agent is mid-turn (`working`) or sitting at a dialog (`blocked`); removing the workspace would interrupt it. An `agent-idle` row is **not** held back — see above.
- `self` — the worktree this session is standing in.
- `unmerged` / `unknown` — the work isn't provably in the base.

### When the board disagrees

A `board-disagrees` flag means `/implement-tickets`' digest and this sweep answered "is it finished?" differently — the board still calls ticket 07 `in-progress` while `gh` says PR #13 merged it, or the board recorded it landed while no leg here can find it.

**Surface it before offering anything.** It usually means a coordinator session died between the merge and the write-back, so the board is stale and the ticket needs marking resolved; occasionally it means the sweep is looking at the wrong base. Either way it's the developer's call, and it's worth more than the cleanup: a stale board launches the wrong wave next round. Say which the disagreement is, and don't resolve it by deleting the evidence.

The digest is read from `/tmp/implement-tickets-digest-*<repo>*.txt`, the derived path that skill writes every round, narrowed to this repo and excluding the `.new.txt` it writes and renames mid-round. No file, no cross-check, no flag — the `board` column just reads `-`, which is not evidence of anything.

**The cross-check has a blind spot, and it's the tickets most likely to have leftovers.** A digest line for a `resolved` ticket collapses to `<NN> resolved <#issue|file> - - - -` — it drops the branch deliberately, so the line stops churning once the worktree is cleaned up. With no branch there is nothing to join on, so a resolved ticket never reaches the `board` column at all. What the cross-check does catch is the live disagreement: a ticket the board still calls `in-progress` whose branch this sweep can prove merged. Don't report a `-` in that column as "the board agrees".

## Phase 3 — Ask, per item

Put the removable items to the developer with `AskUserQuestion` (multi-select), one option per item, each labelled with the branch and its evidence. **Never offer "remove all".** The ticket this skill was built from is explicit about it, and so is the script: `remove` takes exactly one item per call and there is no blanket verb to reach for.

Ask separately about the branch when a worktree's branch is worth keeping — `--keep-branch` removes the workspace and the checkout and leaves the branch where it is. Default to removing both; a merged branch is the thing that clutters `git branch`.

If the developer picks nothing, stop and say nothing was changed.

## Phase 4 — Remove what was confirmed

One call per confirmed item, in the order the developer chose them:

```bash
~/.claude/skills/sweep-tickets/scripts/sweep.sh remove --worktree <path> [--keep-branch]
~/.claude/skills/sweep-tickets/scripts/sweep.sh remove --branch <name>
```

For a worktree with an open Herdr workspace that is one `herdr worktree remove --workspace <id>`, which takes the workspace, its tabs, its panes, the git worktree and the directory together. It does **not** take the branch — verified, not assumed — so the script deletes that separately, with `git branch -d`, falling back to `-D` only when `-d` refuses *and* a leg proved the branch merged. A squash-merged branch whose remote was deleted on merge fails `-d` forever; that's the ordinary case here, not an alarm.

Where no Herdr workspace is open it falls back to `git worktree remove`, and where the directory is already gone it clears that one administrative entry with `git worktree remove --force` — not `git worktree prune`, which is repo-wide and would take every other broken entry along with the one item the developer confirmed.

**Read the exit code and relay it verbatim. Never re-run a call with `--force` to get past one:**

| | |
|---|---|
| `0` | removed; the script printed exactly what went |
| `2` | **skipped — uncommitted changes.** Report the file list it printed and move to the next item. `--force` does not override this one, by design. |
| `3` | skipped — the agent in that workspace is mid-turn or at a dialog. Name the agent and its status; let it finish, or the developer says explicitly to take the pane with it. An idle or finished agent never lands here. |
| `4` | skipped — the branch isn't provably merged. Say which state and reason, and leave it. |
| `1` | an error. Read it, don't retry. |

`--force` exists for exit 3 and 4 and reaches neither guard on its own authority — pass it only after the developer has said so about that specific item, and say in the report that you did.

## Phase 5 — Report

Per item: removed (with what went — workspace, tabs, worktree, branch) or skipped (with the reason from its exit code). Then re-run `sweep.sh list --no-fetch` once and report what's still there, so the developer sees the result rather than a claim about it. Anything left carrying `board-disagrees` gets named again — that one outlives the cleanup.

## What this skill does not do

- **It doesn't touch the ticket home.** A closed issue stays closed, an open one stays open. Marking a ticket resolved is `/implement-tickets` Phase 4's job, off a verified merge; this skill only reads the digest that skill leaves behind. Where the two disagree, say so (Phase 2) and let the developer decide — don't write to the tracker to make the disagreement go away.
- **It doesn't merge, push, or commit anything.** The commit boundary is unchanged: agents hand work back unstaged, the developer merges.
- **It doesn't remove the main checkout or the worktree it's running in.** Both are refused by the script before any guard runs.
