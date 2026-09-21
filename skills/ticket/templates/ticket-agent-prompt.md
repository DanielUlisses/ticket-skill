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

## Phase 2 — Review

Call the Skill tool with `mattpocock-skills:code-review`. Use that namespaced name: Claude Code also ships a built-in `code-review`, which hunts correctness bugs in a diff rather than checking it against standards and spec, and the overrides below only make sense for mattpocock's. Apply three overrides for this mid-flow diff:

- Fixed point: `{{BASE_COMMIT}}`. Nothing has been committed since, so the usual `git diff {{BASE_COMMIT}}...HEAD` is empty — use `git diff {{BASE_COMMIT}}` (working tree against base) instead.
- Spec: the ticket above. No tracker is configured here, so treat it as the spec source directly and skip any prompt to run `/setup-matt-pocock-skills`.
- Standards: whatever this repo documents (`CODING_STANDARDS.md`, `CONTRIBUTING.md`, …), plus the skill's built-in smell baseline.

## Phase 3 — Hand back for review

Stop. Report: files changed (one line each), the Phase 2 findings, and how to look at it (`git status` / `git diff` in `{{WORKTREE}}`). Everything stays unstaged — the developer reviews, commits, and pushes it themselves.

## Inviolable rules

Never `git add`, `git commit`, `git push`, `git stash`, `git reset`, `git rebase`, or switch branches — these are also blocked at the tool level, but don't route around them. Work only inside `{{WORKTREE}}`. No command that changes real infrastructure or environments (`terraform apply`, `kubectl apply`/`delete`, `helm upgrade`, deploys, or a write-capable `az`/`aws`/`gcloud` call).
