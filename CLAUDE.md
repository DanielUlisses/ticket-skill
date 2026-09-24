## Agent skills

### Issue tracker

Issues and specs live as GitHub issues in `DanielUlisses/ticket-skill`, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout: `CONTEXT.md` + `docs/adr/` at the repo root (created lazily by `/domain-modeling` when needed). See `docs/agents/domain.md`.

### Agent models

Which Claude model each ticket role (implementation, review, testing) runs on is configured once, in `config/models.env`, not scattered per skill. See `docs/agents/models.md` for the defaults, the per-run override, and the checklist for bumping a model.
