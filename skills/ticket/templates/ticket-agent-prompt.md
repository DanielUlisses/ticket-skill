# Ticket `{{BRANCH}}`

You're in a worktree dedicated to this ticket:

- Worktree: `{{WORKTREE}}`
- Branch: `{{BRANCH}}` (created from `{{BASE_BRANCH}}` at `{{BASE_COMMIT}}`, updated from the remote just before)

The plan behind this ticket was already settled with the developer before this session started. You are not here to re-open it, interview anyone, or propose a different approach — turn it into working code, reviewed, left unstaged.

## Ticket

{{TICKET}}

## Phase 1 — Implement

Run `/implement` against the ticket above: it drives TDD at the agreed seams, typechecks and runs single test files as it goes, and runs the full suite once at the end. Follow that process, but stop before its last two steps — do not run its internal review and do not commit; Phase 2 below reviews this in a clean context, and nothing gets committed here regardless.

If `/implement` doesn't trigger as a command in this context, run the same process by hand instead: drive `/tdd` at the seams, typecheck and run single test files repeatedly, run the full suite once, then stop.

## Phase 2 — Review

Run `/code-review`, with three overrides for this mid-flow diff:

- Fixed point: `{{BASE_COMMIT}}`. Nothing has been committed since, so the usual `git diff {{BASE_COMMIT}}...HEAD` is empty — use `git diff {{BASE_COMMIT}}` (working tree against base) instead.
- Spec: the ticket above. No tracker is configured here, so treat it as the spec source directly and skip any prompt to run `/setup-matt-pocock-skills`.
- Standards: whatever this repo documents (`CODING_STANDARDS.md`, `CONTRIBUTING.md`, …), plus the skill's built-in smell baseline.

## Phase 3 — Hand back for review

Stop. Report: files changed (one line each), the Phase 2 findings, and how to look at it (`git status` / `git diff` in `{{WORKTREE}}`). Everything stays unstaged — the developer reviews, commits, and pushes it themselves.

## Inviolable rules

Never `git add`, `git commit`, `git push`, `git stash`, `git reset`, `git rebase`, or switch branches — these are also blocked at the tool level, but don't route around them. Work only inside `{{WORKTREE}}`. No command that changes real infrastructure or environments (`terraform apply`, `kubectl apply`/`delete`, `helm upgrade`, deploys, or a write-capable `az`/`aws`/`gcloud` call).
