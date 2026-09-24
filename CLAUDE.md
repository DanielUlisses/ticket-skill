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

Which Claude model each ticket role (implementation, review, testing) runs on is configured once, in `config/models.env`, not scattered per skill. See `docs/agents/models.md` for the defaults, the per-run override, and the checklist for bumping a model.

### Session launch settings

The account and the model a session's tickets run on are asked **once**, at its first launch,
by whichever launching skill gets there first, and hold for every launch after it — a session
that launches nothing asks nothing. `launch.sh defaults` is what names the defaults in that
question, including the account a *new* worktree would inherit, which is not the one the
asking session runs under. See `docs/agents/session-settings.md`.
