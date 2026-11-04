# The project manager

tk-hub reviews each active project the way a project manager would: once a week in depth, once each working day for what changed. This repo ships the brief, the `project-manager` skill (`skills/project-manager/SKILL.md`); tk-hub builds the input, runs it and keeps the answer (tk-hub `docs/project-manager.md`).

| run | when | model | answer |
|---|---|---|---|
| weekly review | Monday 07:30 (`TK_HUB_PM_WEEK_AT`) | Opus, high | health, forecast, risks, decisions owed, up to three improvements (a task of the developer's, or a rescope), a client status draft or a personal project's keep/pause/drop call |
| daily check | working days 07:45 (`TK_HUB_PM_DAY_AT`) | Haiku, low | health now, whether it changed, risks and decisions |

The hub's daemon prepends the skill's body to the hub's input when it runs `claude -p` on the planner box (`run_planner` with `skill: project-manager`, no tools), the way `validate-contracts` runs. The planner box therefore needs this repo's `install.sh` run, or the runs fail with "the project-manager skill isn't installed on this box".

Nothing the review proposes changes anything until the developer accepts it on tk-hub's Health tab: a task becomes one of the developer's tasks blocking the tickets it names; a rescope starts `/ticket rescope <board> <NN> <why>` on the board's box (contracts.md); pause and drop change the project's stage.

By hand: give `/project-manager` the hub's input for one project (`kind` `week` or `day`); the answer is the JSON the brief describes.

## Blocking checks

The ticket summary's by-hand checks ("test it on a phone", "run that check") stay a plain checklist on the ticket and never block anything. Only a step later tickets can't run without — create a token and put it in a repo or pipeline variable, register an app, grant an account access — is a *blocking check*: tk-hub's synthesis marks it on the ticket it came from (`blocking_checks`, with the tickets that need it), and the hub turns each one into a task of the developer's blocking those tickets, so the scheduler holds them until it is done. At planning time the same kind of step is an `**Owner:** me` ticket (contracts.md); a blocking check is one that only showed up once the work was done.
