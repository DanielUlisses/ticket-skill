# Agent accounts

Which Claude subscription a ticket bills to. Configured per launch, not per repo —
unlike the models in [`models.md`](models.md), which are one setting for the machine.

Rate limits meter **per account**, in rolling 5h/7d windows, and two accounts' windows
are independent. Running three tickets on one account exhausts it three times as fast;
running them on three accounts doesn't. That is the whole point of this knob.

## The default is inheritance, and it writes nothing

With no account named, a launch writes **no link at all**. The worktree resolves whatever
[`claude-acc`](https://github.com/rcosteira79/claude-switch) already resolves for the
directory above it — the mapping the developer manages by hand in `~/.claude-switch/links`
— exactly as every launch did before this existed.

So the interesting change on the default path isn't behaviour, it's visibility. Every
ticket this repo launched up to now ran on `pythian`, because `~/repos/daniel=pythian`
and worktrees land under it, and **nothing in the launcher's output said so**. Now the
summary's `ACCOUNT=` line says it, and the launcher proves it rather than assuming it.

## Overriding it

```bash
launch.sh --account <name> "<label>" "<branch>" "<ticket-file>" [model]
```

`<name>` is an account as `claude-acc list` prints it, or `default` for the standard
`~/.claude`. An exported `TICKET_ACCOUNT` does the same for a whole session and the flag
beats it — the same order, and the same reason, as the model knob: the skills'
`allowed-tools` entries are prefix patterns like
`Bash(~/.claude/skills/ticket/scripts/launch.sh *)`, which a `TICKET_ACCOUNT=x ~/.claude/…`
prefix would no longer match. Both launchers take it, and `/implement-tickets` gets it
free, since it runs `/ticket`'s launcher.

The name is checked **before** the worktree is created. A typo costs nothing; it would
otherwise cost a worktree, a workspace and a branch to sweep. After the link is written the
launcher checks the answer against the question — that the worktree really does resolve to
the account that was asked for — because everything downstream, the post-start verification
included, is derived from that one resolution and would agree with itself even if the link
had landed somewhere else.

### An account is a whole config root

`CLAUDE_CONFIG_DIR` points at a full Claude config directory, and Claude Code reads **that**
root's `skills/` and `agents/`, not `~/.claude`'s. So a ticket launched on an account this
repo was never installed into starts an agent with no `ticket-implementer`,
`ticket-reviewer` or `ticket-tester` — and `/small-ticket`'s orchestrator delegates to all
three. `install.sh` takes the root as its argument precisely for this:

```bash
./install.sh ~/.claude ~/.claude-switch/accounts/<name>
```

The launcher warns rather than refuses when the root looks uninstalled, and names that
command. A `/ticket` run does its work in one session and needs none of the subagents, so
refusing would block a launch that would have been fine.

## Why a directory link, and why the agent gets a fresh tab

`claude-acc` selects an account by exporting **`CLAUDE_CONFIG_DIR`**, a native Claude Code
variable pointing at a whole per-account config directory. The scope is **per process**:
nothing mutates a shared credential store, so two tickets on two accounts run side by side
without racing. It picks *which* account from the directory the shell stands in.

`~/.bashrc` runs `eval "$(claude-acc init bash)"`, which resolves the account on shell
startup and re-resolves it from a `PROMPT_COMMAND` hook — but **only when `$PWD` changes**.
Two consequences, and they are the whole design:

- A pre-set `CLAUDE_CONFIG_DIR` is overwritten at startup, so `herdr tab create --env`
  can't inject the account. (`herdr worktree create` has no `--env` at all.)
- A pane resolves its account **once** and then keeps it. The worktree's root pane starts
  with the worktree, which is *before* there is a directory to link — so on the override
  path that pane carries the inherited account for as long as it lives.

Hence the one structural difference between the two paths:

| | inherited (default) | overridden (`--account`) |
|---|---|---|
| link written | none | `<worktree>=<account>`, under `flock` |
| the `agent` tab | the worktree's own tab, renamed | a fresh tab, created **after** the link |
| the worktree's original tab | *is* the agent tab | closed once `review` has taken the reviewr pane out of it |
| tabs | `agent` `review` `shell` | `agent` `review` `shell` |

The original tab is closed rather than kept as a spare shell: its shell resolved the
inherited account, and leaving a wrong-account shell lying about in the ticket's own
workspace is the invisibility this feature exists to end. It is closed **only** when it
holds nothing but the pane Herdr created with it — a reviewr pane that turned up after the
wait gave up is worth more than a tidy tab bar — and the launcher says so when it declines.

> **Not** `rcosteira79/herdr-account-switch`. It is the only account-switching Herdr plugin
> and it does the opposite of what this needs: it rewrites the machine-wide credential
> store, so every pane bills to one account and a switch drags already-running agents onto
> the new one. It would actively corrupt per-ticket isolation.

## Verification is not optional

The dangerous failure is not a crash, it's silence: the hook doesn't fire, the agent starts
on the inherited account, and nothing says so. So after `herdr agent start` the launcher
reads **the agent process's own environment** (`/proc/<pid>/environ`) and compares it to
what `claude-acc activate` resolves for the worktree.

It reads the process, not `claude-acc status`, deliberately: `status` would only re-answer
the question from the links file, and the failure being guarded against is the pane never
*applying* that answer. Only the started process can say what it got.

- **Mismatch** → `die`, before the prompt is sent. The wrong account pays for a startup and
  not for a ticket, and the workspace is left for `/sweep-tickets`.
- **Can't read it at all** → it depends on which path, and deliberately. An overriding
  launch asked for a specific account, so an unconfirmed answer is exactly the silence this
  guards against: it dies. An inheriting launch asked for nothing and wrote nothing — it is
  the launch this repo has always done — so it prints `ACCOUNT=… UNVERIFIED (<why>)` loudly
  and carries on.

The check runs on the exit-3 path too. An agent stopped at the folder-trust dialog is a
started process with an environment to read, and the account it will run under once the
dialog is answered is already decided.

## Concurrency: the links file is one small file

`claude-acc link` and `unlink` are read-modify-write on `~/.claude-switch/links`, so every
write here goes through `flock` on `~/.claude-switch/links.lock` — a lock file of its own,
never `links` itself, because claude-acc may replace that file by rename and a lock on the
replaced inode would guard nothing.

This is not theoretical, and what's at risk is not just a ticket's own entry. Twelve
concurrent unserialised links were measured here: **two survived**, and the developer's own
top-level entries — the ones every worktree inherits from — were among the ten that didn't.
So a **launch** that can't take the lock doesn't happen. Losing one ticket beats losing the
machine's account layout.

The wait is bounded (`TICKET_ACCOUNT_LOCK_WAIT`, 10s) rather than indefinite — an unbounded
`flock` on a stale holder would hang the launch forever, which is not "refusing", it's
hanging.

**`/sweep-tickets` does the opposite**, and on purpose: a removal that reaches the link has
already passed all four of its guards, so aborting there would leave the developer worse off
than a stale line in `links` does. It warns, names the hand fix, and removes the worktree.

Default launches write nothing, so none of this touches them.

## Teardown

Link entries never expire on their own: worktrees get removed, their links don't, and
`links` would grow a line per ticket forever.

`/sweep-tickets`' `remove --worktree` drops the worktree's own entry, and the placement is
load-bearing in both directions:

- **After all four guards**, because a worktree the sweep refuses is one the developer still
  has — a `SKIPPED` item keeps its account.
- **Before the removal**, because `claude-acc unlink` unlinks the directory it is *standing
  in*, and there is nothing to stand in once the worktree is gone.

Only an entry for exactly that path is removed. A ticket that never overrode its account has
none, and the inherited link above it is the developer's — `claude-acc unlink` refuses an
inherited entry on its own, and the sweep asks the same question before calling it. Where the
directory is already gone (the `prunable` case) the single `<path>=<account>` line is dropped
in place instead, under the same lock, with every other line copied through untouched.

`remove --workspace` — the sweep's third kind, a Herdr workspace whose git worktree has
already been removed — releases the link the same way and at the same point. Its checkout
path is gone by definition, so that is exactly the drop-the-line-in-place case, and it is the
one route by which a link left behind by an ordinary `gh pr merge --delete-branch` can still
be reached: `claude-acc unlink` takes no path argument and cannot `cd` into a directory that
no longer exists. It reaches only the links whose workspace is still open, though. Links whose
workspace has *also* gone are not enumerated from anywhere yet.

## Provider switching is out of scope

`herdr agent start --kind` accepts 24 kinds, and Codex uses the same
env-var-points-at-a-config-dir pattern (`CODEX_HOME`), so the *account* half of this
generalises cleanly. The *permissions* half does not: Codex has no equivalent of
`--disallowedTools`, only coarse sandbox modes, and this repo's git guardrails are enforced
entirely through per-tool denies. That is a per-provider guardrail strategy, not a
flag-translation table, and needs its own decision.
