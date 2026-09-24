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

## 4. Settle the session's launch settings

Two things govern every ticket a session launches: the **account** it bills to and the **model** that implements it. They are settled **once**, at the first launch of the session, and every later launch reuses the answer — a second `/small-ticket` here, and anything `/ticket` or `/implement-tickets` launches later in the same session. A session that launches nothing asks nothing, which is why this comes after step 1 has found a ticket to launch.

**Already settled** — this session answered, for an earlier ticket or because the developer named them up front: don't ask again. State which account and model are in force when you launch and move on.

**Not settled yet** — a fresh session, a single ad-hoc ticket included: read the defaults before you state them, rather than assuming them:

```bash
~/.claude/skills/small-ticket/scripts/launch.sh defaults
```

It changes nothing and prints one line per setting, plus the options for the account:

```
MODEL=opus (from /home/you/.claude/skills/ticket-models.env)
ACCOUNT=default (inherited by a new worktree in /home/you/repos — config root ~/.claude)
ACCOUNTS=default work
```

The `ACCOUNT=` name is the one a **new worktree** would inherit. That is not the same question as which account *this* session is running under, and the difference is the entire reason this is asked: a session in a worktree that overrode its own account would otherwise offer that account as the default and launch the ticket somewhere else. Quote what the command printed.

Then ask with **one** `AskUserQuestion` call, one question per setting:

| Setting | Question | Options, in order | How it reaches the launcher |
|---|---|---|---|
| Account | "Which Claude account should this session's tickets run on?" | the `ACCOUNT=` name first, labelled `(default — inherited)`, then the rest of `ACCOUNTS=` | `--account <name>` — and the inherited default passes **no flag at all**, since inheriting is what writes no link |
| Model | "Which model should implement this session's tickets?" | the `MODEL=` value first, labelled `(default)`, then the other two of Opus / Sonnet / Haiku, then **Other…** — the launcher takes any model id, a pinned one included | the positional `[model]`, always explicitly, even when it is the default, so the summary and the rendered prompt agree with what launched |

One call with one question per setting, not one question then another: a further setting is another row here and another field you carry, not another round of questions.

**Then hold them.** Every launch in this session passes both and names both in its report. Two overrides exist and they are different things:

- **For one ticket** — the developer names an account or a model for a single launch. It goes to that launch alone; the session's settings are untouched and the next ticket uses them again.
- **For the session** — the developer asks to change the setting itself. Replace it, say so, and use the new value for every launch after it.

Neither is a reason to re-ask on the next ticket; re-ask only when the developer asks you to. See `docs/agents/session-settings.md`.

## 5. Run the launcher

```bash
~/.claude/skills/small-ticket/scripts/launch.sh [--account <name>] "<label>" "<branch>" "<ticket-file>" "<model>"
```

Both values come from step 4. `--account <name>` is passed only where the session settled on
a named account; where it inherits, the flag is left off entirely and the ticket resolves the
developer's own directory link, which is what every ticket did before this knob existed. A
per-ticket override the developer named for *this* ticket replaces one value here and leaves
the session's settings alone. The summary's `ACCOUNT=` line reports which account ran either
way, verified in the pane; see `docs/agents/accounts.md` and `docs/agents/session-settings.md`.

The script: discovers the main repo root (even if this session is inside a worktree), updates the base branch (`git pull --ff-only origin main`, or the remote's default branch), and only then creates the worktree with a single synchronous `herdr worktree create --cwd <root> --branch <branch> --base <base> --path <root>/../<repo>--<branch> --label <label> --no-focus` — which returns the worktree's own Herdr workspace, tab and root pane, or fails with Herdr's own error — then lays that workspace out as three tabs, `agent` | `review` | `shell` (see below), starts Claude Code on the root pane in the `agent` tab (`--model <the chosen model> --permission-mode plan`, with `git commit`/`git push` blocked), and sends the rendered prompt from `templates/agent-prompt.md`. If the repo keeps a `docs/agents/project-memory.md` in its **main checkout**, the script folds it into that prompt as a `## Project memory` section, so the ticket starts knowing the repo; a repo without one launches exactly as before, and the summary's `PROJECT_MEMORY=` line says which happened — see `docs/agents/memory.md`. The chosen model also drives the `ticket-implementer` subagent (and this pane's plan-mode orchestrator); `ticket-reviewer` and `ticket-tester` follow `TICKET_REVIEW_MODEL` / `TICKET_TEST_MODEL` from `config/models.env` — see `docs/agents/models.md`.

Handle the exit code:

- **0** — all set. Go to step 6.
- **3** — Claude Code in the new tab stopped at a dialog (usually "trust this folder?", since the worktree is a new directory). Tell the user to open the tab, answer the dialog, and let you know. Once they confirm, run the `launch.sh prompt ...` command the script printed.
- **1, on an unknown account name** — the script stops before creating anything. Show the developer `claude-acc list` and ask which account they meant; don't guess a name.
- **1, on a pull failure or a root not on the base branch** — the script stops before creating the worktree. Explain the error to the user and stop. Do not checkout, stash, reset, or merge in the root on your own.
- **Other** — read the error. Every Herdr call reports Herdr's own message (`ERROR: herdr worktree create failed: ...`, `ERROR: herdr tab create (shell) failed: ...`), so read that rather than guessing. If it's a Herdr syntax change, check `herdr worktree`, `herdr tab`, `herdr pane`, and `herdr agent` and do the steps manually (section below). If it's a git problem (branch or directory already exists), pick another branch name and run again. Do not delete existing branches or worktrees.

## 6. Report

Reply in a few lines: workspace name, branch, worktree path, agent name, the account and model it launched on — the summary's `ACCOUNT=` line rather than what you asked for, since that one is verified in the pane — and that the plan will show up for approval in the workspace's `agent` tab. Don't wait around for the agent to finish.

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
