# 0001 — Do not adopt herdr-projects; steal its ideas instead

- **Status:** Accepted
- **Date:** 2026-09-24
- **Deciders:** Daniel Ulisses
- **Subject:** [`eliasstravik/herdr-projects`](https://github.com/eliasstravik/herdr-projects) v0.2.11 (MIT), evaluated against `/ticket`, `/small-ticket` and `/implement-tickets`

## Context

herdr-projects is a Herdr plugin that runs a larger piece of work across parallel
agents: you talk to one persistent **coordinator** agent, it starts a **thread**
per task (each in its own git worktree and branch), every thread is briefed with
the project's goal, standing instructions and accumulated memory, and Herdr's
sidebar groups threads by what needs your attention.

That is recognisably the same shape as our three skills, which raised a fair
question: are we rebuilding something that already exists and is better?

### What we already have

| | Our skills | herdr-projects |
|---|---|---|
| Front door | `/ticket` grills the idea to exhaustion before any code | Coordinator: *"Propose nothing until asked"* |
| Decomposition | Tracer-bullet tickets with **blocked-by** edges | Flat `TASKS.md`, one line per task |
| Scheduling | Frontier computed from the DAG; only unblocked work launches | All threads are parallel, capped by a count |
| Worktrees | Omarchy `ga` injected into a shell, then poll for 90s | `herdr worktree create`, synchronous |
| Memory | None — every ticket rediscovers the codebase | Per-project memory injected into every brief |
| Commit boundary | Agents **never** commit; work is handed back unstaged | Threads commit and open PRs |
| Attention UI | None — you check tabs yourself | Sidebar states, tab bar, popup, notifications |
| Cleanup | Manual `gd` | Auto-resolve, sweep, branch removal on merge |

### How this was evaluated

By reading the source, **not** by running it. The plugin requires Herdr 0.9.1+
and this machine runs 0.8.2, so nothing could be installed. Every claim below is
traceable to a file in the repository at v0.2.11; none is an observation of the
plugin actually running. That limitation is the main reason this decision favours
the reversible option.

## Decision

**Do not adopt herdr-projects.** Keep our own skills, and re-implement the
specific capabilities worth having, lightly, in our own code.

## The paths, and what each earns and misses

### Path A — Adopt wholesale (plugin's coordinator owns the work)

*Earns:* everything in the right-hand column above, for free and maintained by
someone else — memory, attention UI, PR follow-up, cleanup.

*Misses:* **the dependency graph, and the grilling.** Two blockers, both structural:

1. **Two coordinators, one board.** The plugin ships a persistent coordinator
   that owns `TASKS.md`, runs `hp context` every turn, and is the only thing
   permitted to start threads. `/implement-tickets` is *also* a resident
   coordinator that owns the board, verifies merges and launches waves. Both
   believing they own the board means double launches and contradictory state.
   Only one can be resident, and neither can be demoted without losing most of
   its value: the plugin's coordinator without thread-starting is just a chat
   window, and ours without the board is just a launcher.
2. **No dependency concept anywhere in the plugin.** Confirmed by search:
   `TASKS.md` is a flat list of `- [ ] <title> (<owner>)` lines, and threads are
   an unordered parallel set. There is no blocked-by, no ordering, no frontier.
   Our entire `/implement-tickets` premise — launch only what is unblocked,
   recompute on each verified merge — has no counterpart and nowhere to live.

Also missed: the grilling phase. The plugin's coordinator is explicitly tuned for
delegation throughput, not interrogation, so `/ticket` phase 1 would have to sit
in front of it anyway.

*Verdict:* rejected. The two things we would give up are the two things our
skills are actually *for*.

### Path B — Wrap (our skills call `hp thread start` as a launcher)

*Earns:* worktree mechanics, memory injection into briefs, PR follow-up, and the
cleanup machinery, while our layer keeps the DAG and the grilling.

*Misses:* the coordinator UX — the sidebar attention states, the popup, the
`hp context` digest — because we would never open the plugin's coordinator. That
is a large share of what makes the plugin attractive, discarded.

*Costs:* `hp thread start --agent-arg` accepts **model flags only** and hard-refuses
everything else (`src/cli.rs`, `src/settings.rs:51`) — deliberately, so a coordinator
can never widen an agent's powers. Our per-launch `--disallowedTools` git guardrail
and `--permission-mode` would have to move into `thread_agent_args` in
`~/.config/herdr-projects/config.toml`, keyed by absolute project path, hand-edited
by the user, **per project**. We would trade a precise per-launch guardrail for a
coarse global one plus a manual setup step per repo.

*Verdict:* rejected. Paying the plugin's whole operational surface to use it as a
worktree creator, when `herdr worktree create` is one call away.

### Path C — Fork

*Earns:* everything in Path A, plus the dependency graph we would add ourselves.

*Misses:* nothing functionally — this is the only path that gets the full feature
set *and* the DAG.

*Costs:* **17,031 lines of Rust**, on a pre-1.0 project (v0.2.x) that shipped
**12 releases in roughly two days**, with no `CONTRIBUTING.md` and zero open
issues to read as a collaboration signal. Maintaining a divergent fork against
that release cadence is a standing commitment, to keep a feature the maintainer
may well add. Contributing the DAG upstream instead is cheap to attempt but
cannot be planned around.

*Verdict:* rejected on cost. Worth revisiting only if the project stabilises and
the DAG gap persists.

### Path D — Coexist (our skills for tickets, the plugin for big efforts)

*Earns:* the plugin where it shines, with nothing to integrate.

*Misses:* memory where it actually pays. Our work is feature-shaped tickets
against **long-running repos**, so project knowledge saves rediscovery on the
*ordinary* path, not the exceptional one. Reserving the plugin for rare large
efforts puts its best feature exactly where it is needed least.

*Verdict:* rejected on fit.

### Path E — Cherry-pick (chosen)

*Earns:* the capabilities we ranked as must-have, in code we own, in the language
our skills already speak (bash + skill docs), with no upgrade gate, no per-repo
safety table, no fork to maintain, and no second coordinator.

*Misses:* the Herdr client integration — sidebar attention states, the tab-bar
counter, the popup with number keys. These are Herdr config and client plumbing,
not logic, and re-implementing them is not worth it at our scale. Also missed:
whatever the upstream maintainer builds next, which we would have to notice and
port by hand.

*Costs:* we write and maintain it. Modest — the must-list is small and each item
is local to a launcher or a skill doc.

## What we take, and what we leave

**Take (must):**

1. **`herdr worktree create` in place of the `ga` dance.** The single largest
   robustness win. Verified present on the installed Herdr **0.8.2** with exactly
   the flags the plugin uses (`--cwd --branch --base --path --label`), so this
   needs no upgrade. `--path` lets us keep `../<repo>--<branch>`, so `gd` keeps
   working and branch-naming rules are untouched. Replaces: inject a function
   into an interactive shell, poll the filesystem for up to 90s, `sleep 2` for
   mise trust.
2. **Per-repo project memory injected into every ticket brief.** The capability
   that prompted this evaluation. Long-running repos mean accumulated knowledge
   compounds; today every ticket starts blind.
3. **Context-digest discipline.** The coordinator re-reads board, agent state and
   git reality at the top of every round rather than trusting its own memory.
   `/implement-tickets` already half-does this in its phase 1 reconciliation;
   this makes it the rule.

**Take (nice, not now):**

4. **`## Next` lists** in agent reports — dropped from this board by decision.
5. **PR follow-up** — checks and review comments pushed back into the thread.
   Deferred: it only pays once agents push (see *Commit boundary* below).
6. **Auto-resolve and sweep** — list and remove what a finished ticket left behind.

**Leave:**

7. **Progress self-report hooks and sidebar states.** Herdr client config we would
   be reinventing; the value is a UI we can live without.
8. **The plugin's safety model.** It exists because *its* coordinator assembles
   launch flags. Ours does not — our launcher owns them directly — so the problem
   it solves is one we do not have.

## Consequences

- Our launchers lose their most fragile code and gain a synchronous, checkable
  worktree creation call. No Herdr upgrade required.
- Tickets start with project knowledge instead of rediscovering the codebase.
- We keep the DAG, the grilling, and the single-coordinator model.
- We own the maintenance, and we do not get the attention UI.
- We must re-evaluate if upstream adds dependencies between threads, or if the
  project reaches 1.0 and stabilises.

### Commit boundary: unchanged, for now

Adopting PR flow was considered and **deferred**. It turns out the plugin does not
force it — the `PR:` report line is optional (`skill/THREAD.md:18`, `src/pr.rs:22-29`)
and the PR machinery simply never fires without it — so this is a free-standing
choice rather than a migration tax.

Without the plugin's ticker, PR flow buys little that `git diff` in the worktree
does not already give us, while costing agents `git push` rights and touching four
guardrail sites across three skills. Agents continue to hand work back **unstaged**.

**Revisit trigger:** if PR follow-up (#5) is ever promoted to must-have. That is
when PRs start paying.

## Facts that date this decision

Recorded so a future reader knows what to re-check rather than trusting this:

- herdr-projects **v0.2.11**, published 2026-09-24; 12 releases, all `v0.2.x`;
  391 stars, 16 forks, 0 open issues; MIT; 17,031 lines of Rust.
- Plugin requires Herdr **0.9.1+**. This machine ran **0.8.2** when the decision was made; it has since
  been updated to **0.9.1** (client and server), so the version floor is no longer a constraint.
- `herdr worktree create` **is** present on 0.8.2 with the needed flags.
- Plugin defaults: `thread_agent = "claude"`, `max_parallel_threads = 3`,
  `auto_resolve_days = 7`. Multi-repo per project is supported.
- **The plugin was never run.** Every claim here is read from source at v0.2.11. That was forced at the
  time by the version floor; now that the machine is on 0.9.1 it is a *choice*, not a constraint. The
  decision itself does not turn on it — it rests on the two-coordinator conflict and the missing
  dependency graph, neither of which is version-related — so running the plugin would refine the
  evidence, not reverse the finding.
