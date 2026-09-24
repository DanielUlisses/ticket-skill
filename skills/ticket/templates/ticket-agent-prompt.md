# Ticket `{{BRANCH}}`

You're in a worktree dedicated to this ticket:

- Worktree: `{{WORKTREE}}`
- Branch: `{{BRANCH}}` (created from `{{BASE_BRANCH}}` at `{{BASE_COMMIT}}`, updated from the remote just before)

The plan behind this ticket was already settled with the developer before this session started. You are not here to re-open it, interview anyone, or propose a different approach — turn it into working code, reviewed, left unstaged.

## Ticket

{{TICKET}}

## Phase 1 — Implement

Implement the ticket above with mattpocock's `implement` process, **inlined here in full**. That skill ships `disable-model-invocation: true`, so nothing in this session can invoke it — don't go looking for `/implement`, and don't report it as unavailable. The whole of it is:

- Drive TDD at pre-agreed seams. Call the Skill tool with `mattpocock-skills:tdd` — that one *is* model-invocable — and follow its process as loaded.
- Typecheck regularly, and run single test files regularly, as you go.
- Run the full test suite once, at the end.

Its last two steps do not apply here: don't run its review (Phase 2 does that below, with a fixed point it doesn't know about) and don't commit (nothing is committed in this worktree, ever).

All three bullets assume a test suite. Start by settling whether this repo has one — the sections below say which of them then apply.

### Whether this repo has a test suite

This repo has a test suite when a runner is configured — a `test` script in `package.json`, a `test` target in `Makefile`/`justfile`/`Taskfile`, `pytest`/`pyproject.toml`, `go test` files, `Cargo.toml`, `*.csproj`, or a CI workflow that runs tests — **and** tests already run under it. Check before you change anything, and report either answer in Phase 3.

**With a suite** — all three bullets apply as written: call `mattpocock-skills:tdd`, red before green at the ticket's seams, single test files as you go, the full suite once at the end.

**With no suite** — the repo decides, not the process. Leave `mattpocock-skills:tdd` uncalled: its seam gate and its red-before-green both assume the suite this repo doesn't have. Verify by **direct exercise** instead — run the real script, command or dependency the ticket is about, with real inputs, inside this worktree and within the inviolable rules below — and keep the middle bullet as whatever checks this repo does have (a linter, a build, `bash -n`). In Phase 3, report the exact commands you ran and what they printed. The full-suite step is skipped for the same reason, and Phase 3 says so: a missing suite is a result to report, not a gap to fill by assembling one.

### Where the seams are

This section applies with a suite. The `tdd` skill asks you to confirm the seams with the user before writing a test; that confirmation already happened. The seams are the ones the ticket names under **Seams under test**, settled with the developer when the ticket was written — treat that line as the confirmation and test there. `None` on that line is the developer's answer, not a gap to fill: verify by direct exercise instead. When a named seam turns out to be the wrong boundary, use the nearest boundary that observes the same real behaviour, and say in Phase 3 what you moved and why.

### Scaffolding is capped by the change it guards

Stubs, fakes, harnesses and fixtures that would come to more lines than the change they guard are the signal to verify by direct exercise instead. So is reaching red by stubbing the very dependency the ticket is about: a test against your own stub confirms the stub. Exercise the real dependency, and say in Phase 3 that you did and why.

## Phase 2 — Review

Call the Skill tool with `mattpocock-skills:code-review`. Use that namespaced name: Claude Code also ships a built-in `code-review`, which hunts correctness bugs in a diff rather than checking it against standards and spec, and the overrides below only make sense for mattpocock's. Apply three overrides for this mid-flow diff:

- Fixed point: `{{BASE_COMMIT}}`. Nothing has been committed since, so the usual `git diff {{BASE_COMMIT}}...HEAD` is empty — use `git diff {{BASE_COMMIT}}` (working tree against base) instead.
- Spec: the ticket above. No tracker is configured here, so treat it as the spec source directly and skip any prompt to run `/setup-matt-pocock-skills`.
- Standards: whatever this repo documents (`CODING_STANDARDS.md`, `CONTRIBUTING.md`, …), plus the skill's built-in smell baseline.

## Phase 3 — Hand back for review

Stop. Report: files changed (one line each), how you verified it (the suite you ran, or that this repo has none and the exact commands you exercised instead), the Phase 2 findings, and how to look at it (`git status` / `git diff` in `{{WORKTREE}}`). Everything stays unstaged — the developer reviews, commits, and pushes it themselves.

## Inviolable rules

Never `git add`, `git commit`, `git push`, `git stash`, `git reset`, `git rebase`, or switch branches — these are also blocked at the tool level, but don't route around them. Work only inside `{{WORKTREE}}`. No command that changes real infrastructure or environments (`terraform apply`, `kubectl apply`/`delete`, `helm upgrade`, deploys, or a write-capable `az`/`aws`/`gcloud` call).
