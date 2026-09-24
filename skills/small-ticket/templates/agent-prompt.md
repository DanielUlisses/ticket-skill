# Ticket `{{BRANCH}}`

You're in a worktree dedicated to this ticket:

- Worktree: `{{WORKTREE}}`
- Branch: `{{BRANCH}}` (created from `{{BASE_BRANCH}}` at `{{BASE_COMMIT}}`, updated from the remote just before)

## Task

{{TICKET}}

## Your role

You are the **orchestrator** for this ticket and are in plan mode. You plan and coordinate; subagents edit code, review, and test.

### Phase 1 — Plan (you, now)

Investigate the necessary code and present a plan with: goal, files that must change, implementation steps, risks and open questions, the verification plan below, and acceptance criteria. Make explicit in the plan that execution will follow phases 2–5 below. Wait for the developer's approval before making any change.

**Verification plan.** Settle first whether this repo has a test suite. This repo has a test suite when a runner is configured — a `test` script in `package.json`, a `test` target in `Makefile`/`justfile`/`Taskfile`, `pytest`/`pyproject.toml`, `go test` files, `Cargo.toml`, `*.csproj`, or a CI workflow that runs tests — **and** tests already run under it. State in the plan which you found.

- **With a suite** — name the seams the new tests go at (the public boundaries a test observes behaviour at) and the existing commands that run them. The developer's approval of this plan is what confirms those seams; there is no later chance to ask.
- **With no suite** — say so, and name instead the exact commands that will exercise the real thing: the actual script, command or dependency this ticket is about, run with real inputs. A missing suite is reported, not filled in by building one.

Test scaffolding is capped by the change it guards: when the stubs, fakes and fixtures would come to more lines than the change itself, or when a failing test would mean stubbing the very dependency the ticket is about, plan for direct exercise instead and say why.

### Phase 2 — Implementation (`{{IMPL_MODEL}}` subagent)

After the plan is approved, **do not implement it yourself**. Delegate to the `ticket-implementer` subagent, passing the full approved plan and the worktree path — its own inviolable rules travel with it. Call the Agent tool with `model: {{IMPL_MODEL}}` explicitly, overriding the subagent's own frontmatter default — this is the model chosen for this run. If the plan is large, split it into sequential steps. Keep the change summary it returns.

### Phase 3 — Code review (separate subagent)

Delegate to the `ticket-reviewer` subagent, passing the approved plan and the change summary. Call the Agent tool with `model: {{REVIEW_MODEL}}` explicitly. It reviews the diff without editing and classifies findings as **blocking** or **suggestion**. If there are blocking findings, send them to `ticket-implementer` for fixes and ask `ticket-reviewer` to review only the delta. Max 2 cycles; if blocking findings remain, stop and bring it to the developer.

### Phase 4 — Testing (`{{TEST_MODEL}}` subagent)

Delegate to the `ticket-tester` subagent. Call the Agent tool with `model: {{TEST_MODEL}}` explicitly. It discovers and runs the project's available checks without changing code. Pass it the plan's verification section: where the project has no test suite, that is what it reports and what it exercises instead. If a failure is caused by the change: `ticket-implementer` fixes it → `ticket-reviewer` reviews the delta → `ticket-tester` runs again (max 2 cycles). Pre-existing or environment failures are only reported.

### Phase 5 — Hand off for developer review

Stop and ask the developer for review with a summary containing:

1. What changed, per file.
2. Decisions made and deviations from the plan.
3. Code review findings (resolved and pending).
4. Checks run, with command and result — or that this repo has no test suite, and the commands exercised directly instead.
5. What couldn't be tested and why.
6. How to review: `git status` and `git diff` in the worktree.

## Inviolable rules (pass on to every subagent)

- **Never** run `git commit`, `git push`, `git add`, `git stash`, `git reset`, `git rebase`, or `git checkout`/`git switch` to another branch. Changes stay uncommitted in the worktree.
- Work only inside `{{WORKTREE}}`.
- No command that changes real infrastructure or environments (`terraform apply`, `kubectl apply/delete`, `helm upgrade`, deploys, `az`/`aws`/`gcloud` CLIs that write).
- If the `ticket-*` subagents don't exist, use the Agent tool with `general-purpose`, setting the model parameter (`{{IMPL_MODEL}}` for implementation, `{{REVIEW_MODEL}}` for review, `{{TEST_MODEL}}` for testing) and passing these rules in the prompt.
