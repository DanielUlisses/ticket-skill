## Agent skills

### Issue tracker

Issues and specs live as GitHub issues in `DanielUlisses/ticket-skill`, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout: `CONTEXT.md` + `docs/adr/` at the repo root (created lazily by `/domain-modeling` when needed). See `docs/agents/domain.md`.

### Project memory

Each repo may keep a `docs/agents/project-memory.md` — short, factual, hand-curated — which every ticket launcher folds into the brief it sends, so a ticket starts knowing the repo. Agents report durable lessons under `## Remember` and never write to the file; what the repo remembers is the developer's call. Absent is a supported state. See `docs/agents/memory.md`.

### Shared shell library

The worktree/tab/agent mechanics and the repo-root/base-branch resolution the skills' scripts share live in `lib/ticket-*.sh`, sourced — never executed — by both `launch.sh` scripts and by `/sweep-tickets`' `sweep.sh`. A skill installs as a self-contained directory, so `install.sh` puts these one level up, as `~/.claude/skills/ticket-*.sh`, the same place `config/models.env` lands. See `docs/agents/launcher.md`.

### Agent accounts

Which Claude subscription a ticket bills to is chosen per launch (`--account`, or
`TICKET_ACCOUNT`), by linking the worktree directory with `claude-acc`. No account named
means no link is written and the worktree inherits the developer's own — today's behaviour,
now reported and verified rather than assumed. See `docs/agents/accounts.md`.

### Agent models

Twelve roles, configured once in `config/models.env`: the **implementer**, whose model and effort vary per ticket (its `**Suggested model:**` / `**Suggested effort:**` lines, the launch question, `--effort`); and fixed ones — each ticket's **coordinator** (`opus @ low`), the **reviewer** (`opus @ medium`, `high` for a ticket nothing can test — Seams `None`, e.g. Terragrunt) — or, for a `/small-ticket --doc` document, the **doc reviewer** (`opus @ medium`) — the Haiku swarm of **testers**, **scouts**, **researchers** and **criteria checkers**, and on the board side the **board** session itself (`haiku @ low`), the **merger** (`sonnet @ medium`), the **PR creator** (`sonnet @ low`) and the **retro** (`sonnet @ medium`). Every launch redefines the `ticket-*` subagents through `claude --agents` with those values, so the `agents/*.md` frontmatter is only a fallback kept in step. See `docs/agents/models.md` for the roster and the checklist for bumping a model, and `docs/adr/0002-model-tiers-and-agent-roster.md` for why each role sits where it does.

### Planner and board sessions

A feature runs in two sessions, not one. `/ticket` is the **planner** — grilling and breakdown, on the model that judgement needs — and ends by printing the command that starts the **board** session — `skills/implement-tickets/scripts/board.sh <board>`, never run inside the planning session. The board runs on Haiku (`TICKET_BOARD_*`) with a small prompt and few tools, because every check is a script (`tk.sh`: digest, launch, the five merge gates, resolve, relay). It launches waves, merges on the developer's word, sends `ticket-merger` (Sonnet — a merge commit only, after approval) on a conflict and `ticket-pr-creator` (Sonnet, the mattpocock `pr` skill) when asked to open a PR — the only two agents that commit and push, each through its own guarded script — relays messages, opens a live Trello-style status board in a `tickets` tab (`tk.sh view`, a script — no model), and closes the board with `ticket-retro` — mattpocock's `retro` over the tickets' reports and transcripts, proposing project-memory and environment changes — before `/sweep-tickets`. See `docs/adr/0003-planner-and-board-sessions.md` and `docs/adr/0004-haiku-board-session.md`.

### Commands and aliases

`tk.sh help` is the one command reference — what to type in the board session (`help` there prints it verbatim), the status board's keys, and the shell aliases. `install.sh` installs the aliases as `~/.claude/skills/ticket-aliases.sh` (`tkb` start a board, `tkv` watch it, `tkd` digest, `tkr` ready, `tkg` gates, `tks` show, `tkuse` set the shell's board, `tkhelp`) and adds one guarded line to `~/.bashrc` to load them — `TICKET_NO_BASHRC=1` skips that, `TICKET_BASHRC` names another rc file.

### Document tickets

`/small-ticket` also takes a ticket whose deliverable is a document — a presales scope, proposal or estimate, Markdown and maybe a PDF — launched with `--doc`: the orchestrator scopes it with the developer (grilling where the scope is open) and outlines it as the plan; subagents draft, review (`ticket-doc-reviewer`: commitments, accuracy, numbers, coverage) and render it. Such repos often have no remote; every launcher then branches from the local base as it stands. See `docs/adr/0005-scratch-boards-retro-and-presales.md`.

### Session launch settings

The account, the implementer's model and its effort a session's tickets run on are asked **once**, at its first launch,
by whichever launching skill gets there first, and hold for every launch after it — a session
that launches nothing asks nothing. `launch.sh defaults` is what names the defaults in that
question, including the account a *new* worktree would inherit, which is not the one the
asking session runs under. See `docs/agents/session-settings.md`.

### Jira parent

`/ticket` takes a Jira id as the first word of its task (`/ticket itm-9909 add the export button`),
lowercased and stripped before the interview. It names the board — `.scratch/<id>/` — in place of the
feature slug, and every ticket carries `**Parent:** <id>`. A second
run on the same id appends to that board. No id, no change. See `docs/agents/jira-parent.md`.
