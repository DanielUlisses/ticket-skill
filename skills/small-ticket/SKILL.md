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

The script: discovers the main repo root (even if this session is inside a worktree), updates the base branch (`git pull --ff-only origin main`, or the remote's default branch), and only then creates the worktree with a single synchronous `herdr worktree create --cwd <root> --branch <branch> --base <base> --path <root>/../<repo>--<branch> --label <label> --no-focus` — which returns the worktree's own Herdr workspace, tab and root pane, or fails with Herdr's own error — then lays that workspace out as three tabs, `agent` | `review` | `shell` (see below), starts Claude Code on the root pane in the `agent` tab (`--model <the chosen model> --permission-mode plan`, with `git commit`/`git push` blocked), and sends the rendered prompt from `templates/agent-prompt.md`. If the repo keeps a `docs/agents/project-memory.md` in its **main checkout**, the script folds it into that prompt as a `## Project memory` section, so the ticket starts knowing the repo; a repo without one launches exactly as before, and the summary's `PROJECT_MEMORY=` line says which happened — see `docs/agents/memory.md`. The chosen model also drives the `ticket-implementer` subagent (and this pane's plan-mode orchestrator); `ticket-reviewer` and `ticket-tester` follow `TICKET_REVIEW_MODEL` / `TICKET_TEST_MODEL` from `config/models.env` — see `docs/agents/models.md`.

Handle the exit code:

- **0** — all set. Go to step 6.
- **3** — Claude Code in the new tab stopped at a dialog (usually "trust this folder?", since the worktree is a new directory). Tell the user to open the tab, answer the dialog, and let you know. Once they confirm, run the `launch.sh prompt ...` command the script printed.
- **1, on a pull failure or a root not on the base branch** — the script stops before creating the worktree. Explain the error to the user and stop. Do not checkout, stash, reset, or merge in the root on your own.
- **Other** — read the error. Every Herdr call reports Herdr's own message (`ERROR: herdr worktree create failed: ...`, `ERROR: herdr tab create (shell) failed: ...`), so read that rather than guessing. If it's a Herdr syntax change, check `herdr worktree`, `herdr tab`, `herdr pane`, and `herdr agent` and do the steps manually (section below). If it's a git problem (branch or directory already exists), pick another branch name and run again. Do not delete existing branches or worktrees.

## 6. Report

Reply in a few lines: workspace name, branch, worktree path, agent name, and that the plan will show up for approval in the workspace's `agent` tab. Don't wait around for the agent to finish.

## Manual fallback (only if the script fails due to a CLI change)

0. In the main repo root, confirm you're on the base branch and run `git pull --ff-only origin <base>`; stop if it fails.
1. `herdr worktree create --cwd <main-repo-root> --branch <branch> --base <base> --path <main-repo-root>/../<repo>--<branch> --label <label> --no-focus`. It returns when the worktree exists — there is nothing to wait for. Read the root pane from `.result.root_pane`, the tab from `.result.tab`, and confirm `.result.worktree.path`. On failure it exits 1 with `{"error":{"message":...}}` on stderr; that message is the real reason.
2. Lay the workspace out as three tabs, in this order, so the bar reads `agent` | `review` | `shell`:
   1. `herdr tab rename <tab> agent` — `--label` above named the *workspace*; the tab it came with is labelled by number (`1`). Rename it rather than replace it: that keeps the agent on the root pane, which already has the worktree as its cwd.
   2. `review` — the `persiyanov.reviewr` plugin auto-opens its own pane on Herdr's `worktree.created` event, placed from *its* config file, not from anything you pass (see the note below). Wait a few seconds for it with `herdr pane list --workspace <workspace>` (the reviewr pane is the one whose `herdr pane process-info --pane <pane>` shows `herdr-reviewr` in its foreground processes), then `herdr pane move <that-pane> --new-tab --label review --no-focus` and read `.result.move_result.created_tab`. If no such pane shows up, `herdr tab create --workspace <workspace> --cwd <worktree> --label review --no-focus` instead and say so in the report.
   3. `herdr tab create --workspace <workspace> --cwd <worktree> --label shell --no-focus`; read `.result.tab`.
3. `herdr agent start tk-<branch> --kind claude --pane <root-pane> -- --model <the chosen model> --permission-mode plan --disallowedTools "Bash(git commit:*)" "Bash(git push:*)"`.
4. Render `templates/agent-prompt.md` (substitute `{{TICKET}}`, `{{BRANCH}}`, `{{BASE_BRANCH}}`, `{{BASE_COMMIT}}`, `{{WORKTREE}}`, `{{IMPL_MODEL}}`, `{{REVIEW_MODEL}}`, `{{TEST_MODEL}}`, `{{PROJECT_MEMORY}}`) and send it with `herdr agent prompt tk-<branch> "<prompt>"`. `{{PROJECT_MEMORY}}` is the contents of `<main-repo-root>/docs/agents/project-memory.md` under a `## Project memory` heading, or **nothing at all** — heading included, and the blank line after the placeholder with it — when that file is missing or blank (`docs/agents/memory.md`).

### Why the `review` tab is built by moving a pane

The review pane belongs to the `persiyanov.reviewr` plugin, not to this skill. The plugin opens it itself on `worktree.created` and takes its placement from its own config file (`~/.config/herdr/plugins/config/persiyanov.reviewr/config.toml`, keys `toggle_placement` / `toggle_direction`) — no launcher flag or event payload reaches that choice, and on that event it always attaches to the workspace's *first* pane, so with the defaults (`split`, `right`) it lands as a split on top of the agent. Its placement cannot be directed, but the pane it opens can be moved afterwards, which is what the launcher does. `TICKET_REVIEWR_WAIT` (default 5 seconds) caps the wait; if the pane never appears — plugin absent or disabled, `auto_open = false`, or slower than the wait — the launcher opens `review` as a plain shell tab, reports `REVIEW=empty shell ...` in its summary, and leaves the plugin alone. Running `herdr-reviewr` in that tab fills it in by hand.

One consequence is worth knowing, because the launcher can't prevent it: a reviewr pane that arrives *after* the wait still attaches to the workspace's first pane, so the `agent` tab ends up split beside an empty `review` tab. The summary's `REVIEW=empty shell ...` line is the tell. Close the stray pane (`herdr pane close <pane>`) and run `herdr-reviewr` in the `review` tab, or raise `TICKET_REVIEWR_WAIT` on a machine where the plugin is consistently slow.
