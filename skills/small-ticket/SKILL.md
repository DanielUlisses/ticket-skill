---
name: small-ticket
description: Opens an isolated Herdr worktree for one already-defined ticket, plans it in Claude Code, then implements, reviews, and tests it via subagents, leaving everything uncommitted. For a rough idea that still needs sharpening and splitting into tickets, use /ticket instead.
argument-hint: "<task description>"
disable-model-invocation: true
allowed-tools: Bash(~/.claude/skills/small-ticket/scripts/launch.sh *), Bash(herdr *), Bash(git *), Bash(mktemp *), Read, Write, AskUserQuestion
---

# /small-ticket

Ticket received:

<ticket>
$ARGUMENTS
</ticket>

Your job here is only to **set up the environment and hand off the ticket**. Do not plan or implement the task in this session — that's done by the agent you're about to start in the new tab.

Follow the `herdr` skill's rules (check `HERDR_ENV=1`, read IDs from the JSON, don't close anything you didn't create, don't answer blocked dialogs without the user). The authoritative syntax is whatever the installed binary exposes (`herdr worktree`, `herdr pane`, `herdr agent`).

## 1. Validate the input

If the ticket is empty, ask for the task description and stop.

## 2. Derive the names (without asking for confirmation)

- **Tab label**: 2–3 words, lowercase, up to 20 characters, describing the task. E.g.: `retry webhook`, `aks node pool`.
- **Branch**: `<type>-<slug>`, kebab-case, in English, up to 40 characters.
  - `type` ∈ `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`, `ci`.
  - `slug` with 2–4 semantic words. E.g.: `fix-webhook-retry-backoff`, `feat-aks-spot-nodepool`.
  - **No `/` and no `--`**: the launcher puts the branch in the worktree directory name (`../<repo>--<branch>`) and `gd` splits repo/branch at the first `--`.

## 3. Save the ticket to a file

Create a temp file with `mktemp -t ticket.XXXXXX.md` and write the ticket text into it with the Write tool, **exactly** as received (no summarizing or rewriting).

## 4. Choose the model

Ask once, with `AskUserQuestion`: "Which model should implement this ticket?" — options **Opus (default)**, **Sonnet**, **Haiku**, **Other…**, Opus listed first and labelled `(default)`. If the developer picks the default, still pass `opus` explicitly in the next step, so the summary and the rendered prompt agree with what actually launched.

## 5. Run the launcher

```bash
~/.claude/skills/small-ticket/scripts/launch.sh "<label>" "<branch>" "<ticket-file>" "<model>"
```

The script: discovers the main repo root (even if this session is inside a worktree), updates the base branch (`git pull --ff-only origin main`, or the remote's default branch), and only then creates the worktree with a single synchronous `herdr worktree create --cwd <root> --branch <branch> --base <base> --path <root>/../<repo>--<branch> --label <label> --no-focus` — which returns the worktree's own Herdr workspace, tab and root pane, or fails with Herdr's own error — then splits that root pane with Claude Code on the right (`--model <the chosen model> --permission-mode plan`, with `git commit`/`git push` blocked), and sends the rendered prompt from `templates/agent-prompt.md`. The chosen model also drives the `ticket-implementer` subagent (and this pane's plan-mode orchestrator); `ticket-reviewer` and `ticket-tester` follow `TICKET_REVIEW_MODEL` / `TICKET_TEST_MODEL` from `config/models.env` — see `docs/agents/models.md`.

Handle the exit code:

- **0** — all set. Go to step 6.
- **3** — Claude Code in the new tab stopped at a dialog (usually "trust this folder?", since the worktree is a new directory). Tell the user to open the tab, answer the dialog, and let you know. Once they confirm, run the `launch.sh prompt ...` command the script printed.
- **1, on a pull failure or a root not on the base branch** — the script stops before creating the worktree. Explain the error to the user and stop. Do not checkout, stash, reset, or merge in the root on your own.
- **Other** — read the error. A failed worktree creation reports Herdr's own message (`ERROR: herdr worktree create failed: ...`), so read that rather than guessing. If it's a Herdr syntax change, check `herdr worktree`, `herdr pane`, and `herdr agent` and do the steps manually (section below). If it's a git problem (branch or directory already exists), pick another branch name and run again. Do not delete existing branches or worktrees.

## 6. Report

Reply in a few lines: tab name, branch, worktree path, agent name, and that the plan will show up for approval in that tab. Don't wait around for the agent to finish.

## Manual fallback (only if the script fails due to a CLI change)

0. In the main repo root, confirm you're on the base branch and run `git pull --ff-only origin <base>`; stop if it fails.
1. `herdr worktree create --cwd <main-repo-root> --branch <branch> --base <base> --path <main-repo-root>/../<repo>--<branch> --label <label> --no-focus`. It returns when the worktree exists — there is nothing to wait for. Read the root pane from `.result.root_pane`, the tab from `.result.tab`, and confirm `.result.worktree.path`. On failure it exits 1 with `{"error":{"message":...}}` on stderr; that message is the real reason.
2. `herdr pane split <root-pane> --direction right --cwd <worktree> --no-focus`; read `.result.pane`.
3. `herdr agent start tk-<branch> --kind claude --pane <new-pane> -- --model <the chosen model> --permission-mode plan --disallowedTools "Bash(git commit:*)" "Bash(git push:*)"`.
4. Render `templates/agent-prompt.md` (substitute `{{TICKET}}`, `{{BRANCH}}`, `{{BASE_BRANCH}}`, `{{BASE_COMMIT}}`, `{{WORKTREE}}`, `{{IMPL_MODEL}}`, `{{REVIEW_MODEL}}`, `{{TEST_MODEL}}`) and send it with `herdr agent prompt tk-<branch> "<prompt>"`.
