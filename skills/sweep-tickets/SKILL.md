---
name: sweep-tickets
description: Lists what the ticket workflow has left lying around — worktrees whose branch already merged, worktrees with no live agent, local branches merged into the base, Herdr workspaces git no longer knows about, and claude-acc account links whose worktree is gone — and removes the ones the developer confirms, one at a time. Listing changes nothing; removal always asks first and never touches a worktree with uncommitted changes. Run it after a wave of tickets has merged; `/implement-tickets` points here instead of naming `gd` by hand.
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
inherited its account has no link of its own and nothing is said. Where the worktree went
without this skill — the ordinary merge — the link is left with nothing to attach it to,
and `remove --link` is the verb for that one. See `docs/agents/accounts.md`.

When the developer merges the PR and moves on, all five stay. Over a few waves they accumulate: a sidebar full of workspaces for work that landed days ago, and a `git branch` list that no longer means anything. Nothing in the workflow clears them, deliberately — `/implement-tickets` names the cleanup and refuses to act on it, because removing a worktree is not a coordinator's decision. This skill is where that decision gets made, with the developer in the room.

**They don't always stay together.** `gh pr merge --squash --delete-branch` takes the directory, git's worktree registration and the branch, and leaves the Herdr workspace — its tabs, its panes and its idle agent — with nothing on git's side left to find it by. Close that workspace too and the account link is left with nothing on either side to find it by. That is the *ordinary* end of a ticket here, not an edge case, so the inventory is taken from **four** sources: git's worktrees, git's branches, Herdr's own workspace list, and claude-acc's links file.

**Listing is safe and always available. Removal is opt-in per item, and a worktree with uncommitted changes is never removed — not with `--force`, not on the developer's say-so.**

## Phase 1 — Take the inventory

One call, read-only, from wherever this session happens to be standing:

```bash
~/.claude/skills/sweep-tickets/scripts/sweep.sh list | column -t -s$'\t'
```

It resolves the main repo root itself (`git worktree list --porcelain`, first entry), so it gives the same answer from the checkout or from any ticket's worktree. It fetches the base branch and nothing else — never a pull, which would need the root clean and on the base branch, and a listing that breaks on the developer's dirty root isn't one they can run whenever they like. `--no-fetch` skips even that.

The output is a `#` header plus one tab-separated row per item:

```
# root=<path> base=<remote>/<base> gh=<yes|no> herdr=<yes|no> links=<yes|no>
[# source unavailable: Herdr workspaces — <why>. …]
[# source unavailable: claude-acc links — <why>. …]
# kind	branch	path	state	reason	agent	dirty	workspace	board	flags
```

- **kind** — `worktree` (a checkout on disk), `branch` (a local branch with no worktree of its own), `workspace` (a Herdr workspace git has lost track of), or `link` (a `claude-acc` account link whose ticket worktree is gone). `links=no` in the header means claude-acc isn't installed or has no links file — nothing to reconcile, which is absence rather than a source that couldn't be read. A links file that is *there* and won't read is the other thing, and gets a `# source unavailable: claude-acc links —` line of its own: relay it, the same as Herdr's.
- **state** and **reason** — for the first two kinds, whether the branch's work is in the base, and on what evidence: `merged`/`pr#13`, `merged`/`ancestor:origin/main`, `merged`/`patch-id`, `empty`/`no-commits`, `unmerged`/`no-merged-pr`, `unknown`/`no-gh`. A `workspace` row has no branch to classify and answers a different question — `gone`/`checkout-missing (<label>)` when the checkout it was cut for is no longer on disk, `unregistered`/`no-git-worktree (<label>)` when the directory is there but git claims no worktree for it. The label in brackets is the one in the Herdr sidebar, which is how the developer recognises it. A `link` row uses the same two words for the directory its entry points at, and names the account in brackets: `gone`/`checkout-missing (account=pythian)` is the leaked one; `unregistered`/`directory-present (account=…)` is held back, because a directory still on disk can be `cd`'d into and is claude-acc's own to unlink.
- **agent** — `<name>:<status>` for a live agent in that worktree's workspace, `none` when Herdr was asked and had nobody, `unknown` when Herdr couldn't be reached at all. Don't read `unknown` as `none`; the header's `herdr=no` says which it is.
  **A live agent is not a reason to keep a worktree.** The ordinary state of a ticket whose PR has merged is an agent still sitting in its pane at `idle` or `done`, having finished its implement-and-review pass hours ago — that *is* what finished looks like. Only `working` and `blocked` (and Herdr's own `unknown`, which it says "does not prove completion") mean removing the pane would interrupt something, and only those hold an item back.
- **dirty** — count of `git status --porcelain` lines, `-` when the directory is gone, or `?` when the directory is there but git can't read it as a worktree. Only `0` and `-` are removable; `?` means there is no telling what is in it.
- **board** — `<NN>:<status>:<landed>` from `/implement-tickets`' digest, where one is on disk (Phase 3 below).
- **flags** — the summary: `orphan`, `orphan-workspace`, `orphan-link`, `merged-branch`, `never-started`, `no-agent`, `agent-idle`, `agent-busy`, `agent-unknown`, `dirty`, `dirty-unknown`, `prunable`, `covered-by-workspace`, `workspace-unknown`, `self`, `board-disagrees`, and either `removable` or `keep`. `removable` is computed from exactly the conditions `remove` enforces, so the list never offers an item the script will then refuse.

The header's `gh=` and `herdr=` matter for what you can claim. With `gh=no` a squash merge of several commits is undetectable, and the script says `unknown`/`no-gh` rather than `unmerged` — report that as "can't tell", never as "not merged".

**With `herdr=no`, a whole source is missing and the script says so** on a `# source unavailable:` line before the header. Relay that line. An empty listing under it is not "nothing left behind" — it is "nothing left behind *that git knows about*", and the script's own closing line says exactly that. Reporting it as a clean sweep is the bug this third source was added to fix.

### The third source: Herdr workspaces git can't see

Both of the git-keyed sources are blind to the commonest leftover there is. A workspace whose checkout has been deleted and whose registration has been pruned appears in neither `git worktree list --porcelain` nor `for-each-ref refs/heads/` — there is no row to flag, so the sweep used to report nothing at all while three tabs, three panes and an idle agent sat in the sidebar.

`herdr workspace list` is keyed on Herdr's own state instead, and it keeps the `checkout_path` and `repo_root` a workspace was created with **even after the checkout is gone**. That is what makes the orphan findable.

**That list is machine-wide.** Most of the workspaces on it belong to other projects, and offering one of those is the one thing this source must never do, so a workspace counts as this repo's only when Herdr's recorded `repo_root` *is* this repo's root, or — where Herdr recorded no repo — when its checkout path is this repo's root or matches the launcher's `<parent>/<repo>--<branch>` convention. "Somewhere under the repo's parent" is deliberately not enough: every sibling repo lives under that parent too. `remove --workspace` re-asks the same question and refuses anything that fails it.

A workspace whose checkout git *does* still claim isn't in this group — it already has a `worktree` row, and `remove --workspace` sends you back to `remove --worktree` so the worktree and the branch go with it.

### The fourth source: account links with nothing left to attach them to

A ticket launched with `--account` has a line in `~/.claude-switch/links`. The ordinary merge takes the directory, the registration and the branch; closing the workspace takes the last thing Herdr could find it by. The line stays, and by then **no tool can reach it**: `claude-acc unlink` takes no path argument (`claude-acc unlink <path>` is `error: unexpected argument`) and unlinks the directory it is standing in, which no longer exists. Links never expire, so that is one permanent line per `--account` ticket unless something reconciles it.

So the links file is read as a source in its own right — the only one that needs neither git nor Herdr to answer, which is exactly the state it reports on. **It is the developer's own file**, so a row is emitted only for a path under the launcher's `<parent>/<repo>--<branch>` convention: a hand-written entry like `/home/daniel/repos/pythian=pythian`, another project's worktree and the main checkout itself are never listed, never offered and never written away. Entries a git worktree still claims aren't leftovers at all and get no row; one a Herdr workspace still holds gets a row flagged `covered-by-workspace` and held at `keep`, because closing that workspace releases the link at the one moment claude-acc itself can still be asked to.

### Why `merged` isn't just ancestry

Ancestry alone gives a **false negative every time** on GitHub's default. A squash merge collapses the branch into one new commit with a new sha, and a rebase merge rewrites them all; either way `git merge-base --is-ancestor` and `git branch --merged` find nothing. Every PR in this repo is squash-merged, so a sweep that trusted ancestry would report a fully-merged board as entirely unmerged. Three legs run instead, first answer wins: ancestry (against the remote base, then the local one, since an unpushed merge is visible only locally), then the merged PR for that branch (`gh pr list --head <branch>`, scoped per branch — a board-wide `--state merged --limit <n>` silently loses anything that merged beyond the newest `<n>`), then patch ids (`git cherry`, which catches a rebase merge with no network at all).

### Why `empty` is its own state, not `merged`

A branch the launcher cut minutes ago sits exactly at the base and has no commits, so **ancestry calls it merged** — and a sweep acting on that would delete a ticket that is still being worked on. The script reads the branch's reflog for the commit it was created at, and counts the commits made since. Zero commits *and* a tip already in the base is `empty`: nothing was ever written here, so there is nothing to have merged and nothing to lose. That's the same trap `/implement-tickets`' digest guards with the `**Base:**` sha from run state; the sweep has no run state to read, and the reflog is the same fact recorded by git itself.

An `empty` worktree is still worth reporting — it's a launch that never got anywhere — but say *why* it's removable ("never started, nothing committed"), never "merged".

## Phase 2 — Report the five groups

Turn the rows into the five groups the developer actually thinks in, in this order, and say plainly when a group is empty:

1. **Orphan worktrees** — `orphan` flag: the branch has landed, so the whole workspace is finished. Give the branch, the evidence (`pr#13`), the workspace id, and whether an agent is still sitting in it.
2. **Worktrees with no live agent** — `no-agent`: the session died or the pane was closed. This overlaps group 1 and that's fine; say which rows are in both. An **unmerged** worktree with no agent is the interesting one — work in progress that nobody is driving, and the one row in this group that isn't routine cleanup.
3. **Merged branches** — `merged-branch`: a local branch with no worktree left, from a `gd` or a hand-removed checkout.
4. **Orphaned workspaces** — `orphan-workspace`: a Herdr workspace whose git worktree is gone, left by a normal `gh pr merge --delete-branch`. Give the workspace id, its sidebar label and the path it was cut for; the tabs, panes and agent are still open in the sidebar even though nothing on git's side remains. Say which of `gone` (the checkout is no longer on disk — the ordinary case) and `unregistered` (the directory is still there, git just doesn't claim it) it is: an `unregistered` row is usually held back by `dirty-unknown`, and where it isn't, closing the workspace leaves the directory behind — the script says so when it does.

5. **Orphaned account links** — `orphan-link`: a `claude-acc` link whose ticket worktree is gone, left by a normal merge. Give the path and the account it names. This is the leftover nothing else can see, and the one that can't be cleaned up by hand except in a text editor — say that plainly, because it's why the item is worth a minute. A row flagged `covered-by-workspace` belongs to group 4's item instead: name it there, as what closing that workspace will also take, and don't offer it separately. A row flagged `workspace-unknown` is still on offer but Herdr couldn't be asked whether a workspace holds it — say so when you offer it; dropping the entry takes nothing else with it either way.

Groups 1–3 are removed with `--worktree` or `--branch`; groups 4 and 5 have a **different verb** each, and Phase 4 says which.

Then the rows that are **not** on offer, with the reason, because a sweep that silently omits them reads as "nothing else is there":

- `dirty` — uncommitted changes, so never removable.
- `dirty-unknown` — an `unregistered` workspace's directory is still on disk and git can't read it; there is no telling what's in it, so it's the developer's to look at by hand.
- `agent-busy` — the agent is mid-turn (`working`) or sitting at a dialog (`blocked`); removing the workspace would interrupt it. An `agent-idle` row is **not** held back — see above.
- `self` — the worktree this session is standing in, and the workspace it is standing in.
- `unmerged` / `unknown` — the work isn't provably in the base.
- a `link` row at `unregistered` — its directory is still on disk, so `claude-acc` can reach its own entry; the answer there is `cd <path> && claude-acc unlink`, not this skill.

And if the header said `herdr=no`, say that group 4 could not be looked at **at all** — not that it was empty.

### When the board disagrees

A `board-disagrees` flag means `/implement-tickets`' digest and this sweep answered "is it finished?" differently — the board still calls ticket 07 `in-progress` while `gh` says PR #13 merged it, or the board recorded it landed while no leg here can find it.

**Surface it before offering anything.** It usually means a coordinator session died between the merge and the write-back, so the board is stale and the ticket needs marking resolved; occasionally it means the sweep is looking at the wrong base. Either way it's the developer's call, and it's worth more than the cleanup: a stale board launches the wrong wave next round. Say which the disagreement is, and don't resolve it by deleting the evidence.

The digest is read from `/tmp/implement-tickets-digest-*<repo>*.txt`, the derived path that skill writes every round, narrowed to this repo and excluding the `.new.txt` it writes and renames mid-round. No file, no cross-check, no flag — the `board` column just reads `-`, which is not evidence of anything.

**The cross-check has a blind spot, and it's the tickets most likely to have leftovers.** A digest line for a `resolved` ticket collapses to `<NN> resolved <#issue|file> - - - -` — it drops the branch deliberately, so the line stops churning once the worktree is cleaned up. With no branch there is nothing to join on, so a resolved ticket never reaches the `board` column at all. What the cross-check does catch is the live disagreement: a ticket the board still calls `in-progress` whose branch this sweep can prove merged. Don't report a `-` in that column as "the board agrees".

## Phase 3 — Ask, per item

Put the removable items to the developer with `AskUserQuestion` (multi-select), one option per item, each labelled with the branch and its evidence — or, for an `orphan-workspace` row, with the workspace id and its sidebar label, and for an `orphan-link` row with the path and the account it names, which is what each has instead of a branch. **An `orphan-link` item is a write into `~/.claude-switch/links`, so it is asked about like everything else and never folded into another item's answer.** **Never offer "remove all".** The ticket this skill was built from is explicit about it, and so is the script: `remove` takes exactly one item per call and there is no blanket verb to reach for.

Ask separately about the branch when a worktree's branch is worth keeping — `--keep-branch` removes the workspace and the checkout and leaves the branch where it is. Default to removing both; a merged branch is the thing that clutters `git branch`.

If the developer picks nothing, stop and say nothing was changed.

## Phase 4 — Remove what was confirmed

One call per confirmed item, in the order the developer chose them:

```bash
~/.claude/skills/sweep-tickets/scripts/sweep.sh remove --worktree <path> [--keep-branch]
~/.claude/skills/sweep-tickets/scripts/sweep.sh remove --branch <name>
~/.claude/skills/sweep-tickets/scripts/sweep.sh remove --workspace <id>
~/.claude/skills/sweep-tickets/scripts/sweep.sh remove --link <path>
```

For a worktree with an open Herdr workspace that is one `herdr worktree remove --workspace <id>`, which takes the workspace, its tabs, its panes, the git worktree and the directory together. It does **not** take the branch — verified, not assumed — so the script deletes that separately, with `git branch -d`, falling back to `-D` only when `-d` refuses *and* a leg proved the branch merged. A squash-merged branch whose remote was deleted on merge fails `-d` forever; that's the ordinary case here, not an alarm.

Where no Herdr workspace is open it falls back to `git worktree remove`, and where the directory is already gone it clears that one administrative entry with `git worktree remove --force` — not `git worktree prune`, which is repo-wide and would take every other broken entry along with the one item the developer confirmed.

### An orphaned workspace takes a different verb

`herdr worktree remove --workspace <id>` is the **wrong call** for an `orphan-workspace` row, and not by a little: it asks git for the repo's worktrees first, and once the checkout is gone `herdr worktree list` doesn't list that workspace at all. The working call is

```
herdr workspace close <id>
```

**positional** — the `--workspace` flag form prints a usage error — and the script makes it for you behind `remove --workspace <id>`. It takes the workspace, its tabs and its panes, which is all that is left; there is no worktree to remove and no branch to delete, so it says so rather than claiming either. A `claude-acc` link for the vanished path goes with it, the same as on the worktree path.

That call **cannot** reach another project's workspace: the script re-checks that the id belongs to this repo before it fires, and refuses a workspace whose checkout git still claims, pointing at `remove --worktree` instead. Never reach for `herdr workspace close` by hand to get around a refusal.

### An orphaned link is the one write into the developer's own file

`remove --link <path>` drops a single `<path>=<account>` line from `~/.claude-switch/links`, under the same `flock` every other write to that file takes, copying every other line through byte for byte. It is the only removal here that edits a file claude-acc owns rather than calling claude-acc, and it does so only because the tool cannot reach the entry any more.

It takes **no `--force`** — passing one is an error, not an override — and it refuses, with the better answer named, when: the path isn't under this repo's worktree convention (the guard that keeps hand-written entries safe), a git worktree still claims it (`remove --worktree` instead), a Herdr workspace still holds it (`remove --workspace` instead), or the directory is still on disk (`cd <path> && claude-acc unlink` instead). Relay the refusal; never work around one by editing the file yourself.

It prints `REMOVED account link for <path>` and nothing else goes with it — no directory, no workspace, no branch. Say exactly that when reporting it.

**Read the exit code and relay it verbatim. Never re-run a call with `--force` to get past one:**

| | |
|---|---|
| `0` | removed; the script printed exactly what went |
| `2` | **skipped — uncommitted changes**, or a workspace whose directory is still on disk and unreadable by git. Report the file list it printed and move to the next item. `--force` does not override this one, by design. |
| `3` | skipped — the agent in that workspace is mid-turn or at a dialog. Name the agent and its status; let it finish, or the developer says explicitly to take the pane with it. An idle or finished agent never lands here. |
| `4` | skipped — the branch isn't provably merged. Say which state and reason, and leave it. `remove --workspace` never returns this: a workspace has no branch of its own. |
| `1` | an error. Read it, don't retry. |

`remove --link` uses only `0` and `1`: a link entry has no working tree to be dirty, no pane to interrupt and no branch to classify, so every refusal of it arrives as `1` with the reason on stderr.

`--force` exists for exit 3 and 4 and reaches neither guard on its own authority — pass it only after the developer has said so about that specific item, and say in the report that you did.

## Phase 5 — Report

Per item: removed (with what went — workspace, tabs, worktree, branch) or skipped (with the reason from its exit code). Then re-run `sweep.sh list --no-fetch` once and report what's still there, so the developer sees the result rather than a claim about it. Anything left carrying `board-disagrees` gets named again — that one outlives the cleanup.

## What this skill does not do

- **It doesn't touch the ticket home.** A closed issue stays closed, an open one stays open. Marking a ticket resolved is `/implement-tickets` Phase 4's job, off a verified merge; this skill only reads the digest that skill leaves behind. Where the two disagree, say so (Phase 2) and let the developer decide — don't write to the tracker to make the disagreement go away.
- **It doesn't merge, push, or commit anything.** The commit boundary is unchanged: agents hand work back unstaged, the developer merges.
- **It doesn't remove the main checkout or the worktree it's running in.** Both are refused by the script before any guard runs, and so is the Herdr workspace this session is sitting in — by id as well as by path, since an orphan row is emitted precisely when git has lost track of a checkout.
- **It never touches the developer's own account links.** `~/.claude-switch/links` is hand-managed and holds the entries every worktree here inherits from. Only a line whose path matches this repo's `<parent>/<repo>--<branch>` convention is ever listed or removed, and only when nothing else still holds it.
- **It never touches another project's workspace.** `herdr workspace list` covers the whole machine; this skill only ever offers, and the script only ever closes, a workspace this repo can be proved to own.
