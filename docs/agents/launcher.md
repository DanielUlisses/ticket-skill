# The shared shell library

Three scripts in this repo do overlapping work: `skills/ticket/scripts/launch.sh`,
`skills/small-ticket/scripts/launch.sh` and `skills/sweep-tickets/scripts/sweep.sh`.
What they share lives in `lib/`, sourced rather than executed. Nothing in `lib/` runs
on its own.

| File | Holds | Sourced by |
|---|---|---|
| `lib/ticket-git-repo.sh` | `die`/`log`/`need`, `resolve_repo_root`, `resolve_base_branch`, `run_git_net` | all three scripts |
| `lib/ticket-account.sh` | the `claude-acc` helpers: link resolution, the `flock`ed link/unlink, and reading a started agent's `CLAUDE_CONFIG_DIR` | all three scripts |
| `lib/ticket-launcher.sh` | the worktree/tab/agent mechanics, project-memory resolution, `fill_prose`, `load_ticket_models`, `launcher_main` | the two launchers |

`ticket-account.sh` is shared three ways for the same reason the git half is: the launchers
write the links and `/sweep-tickets` takes them away again, and both halves have to agree on
what counts as a link a ticket owns. See [`accounts.md`](accounts.md).

## Why one level up

A skill installs as a self-contained directory — `~/.claude/skills/<skill>/scripts/…` —
and `install.sh` copies each skill's `scripts/` and `templates/` wholesale. There is
nowhere *inside* a skill to put a file two skills share. So `install.sh` copies
`lib/ticket-*.sh` one level up, to `~/.claude/skills/ticket-*.sh`, which is exactly
where `config/models.env` has always landed as `ticket-models.env`.

Each script finds them with the same bootstrap block: `$TICKET_LIB_DIR` if set,
otherwise one level up from its own skill directory (the installed layout), otherwise
`<repo>/lib` (the source tree, so the scripts still run from a checkout). Setting
`TICKET_LIB_DIR` *replaces* that search rather than joining the front of it — a typo
in it is an error, not a silent fall-through to another copy.

Unlike `ticket-models.env`, which `install.sh` never overwrites because it is
config a developer may have hand-edited, the libraries are code and are overwritten
on every install.

## The launchers are parameters, not forks

`/ticket` and `/small-ticket` differ in six things, and only six: `SKILL_DIR`,
`TEMPLATE`, `RUN_NAME`, `PERMISSION_MODE`, `PERMISSION_LABEL` and `DISALLOWED_TOOLS`.
Each `launch.sh` sets those and calls `launcher_main "$@"`. The differences are real
and must not be flattened — `/small-ticket` starts in plan mode with a developer
watching, `/ticket` starts unattended with eight git verbs blocked — but they are
values, not code paths.

`load_ticket_models` is called by the launcher *before* it sets those parameters,
because `ticket-models.env` may set any `TICKET_*` variable and anything resolved
from the environment has to be resolved after the config file has been read.

The account is a launch-time argument rather than one of those six parameters: it varies
per ticket, not per skill, so `--account` (or `TICKET_ACCOUNT`) is parsed inside
`launcher_main` and both skills get it from the one definition.

## The one place the tab sequence forks

`launcher_main` builds the `agent` tab two ways, and the fork is not a preference — a pane
resolves its Claude account once, when its shell starts. Inheriting the account (the
default, and every launch before this existed) nothing is written, so the worktree's own tab
is renamed and the agent keeps the root pane. Overriding it, that pane's shell predates the
link, so the agent gets a tab created afterwards and the stale one is closed. Both skills
take the same fork; neither needed the function split. [`accounts.md`](accounts.md) has the
table and the reasoning.

## Why `/sweep-tickets` shares the git half

`/sweep-tickets` removes worktrees and branches. Two of its guards are the reason
the git half is shared rather than copied: it refuses the main checkout **even with
`--force`**, and a dirty worktree returns exit 2 that `--force` **cannot** override.
Both rest on `ROOT` and `SELF` resolving to exactly what the launcher that created
the worktree resolved. One definition is how that stays true.

A third guard now rests on the same resolution, and on the launcher's path convention
besides. `herdr workspace list` is machine-wide, so the sweep's orphaned-workspace
source decides which of those workspaces are this repo's from `ROOT`, `REPO_NAME` and
`<parent>/<repo>--<branch>` — the very expression `launcher_main` builds `WT` from. If
the launcher ever cuts worktrees somewhere else, that scoping rule moves with it, or
the sweep starts missing its own leftovers.
