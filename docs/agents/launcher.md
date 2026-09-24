# The shared shell library

Three scripts in this repo do overlapping work: `skills/ticket/scripts/launch.sh`,
`skills/small-ticket/scripts/launch.sh` and `skills/sweep-tickets/scripts/sweep.sh`.
What they share lives in `lib/`, sourced rather than executed. Nothing in `lib/` runs
on its own.

| File | Holds | Sourced by |
|---|---|---|
| `lib/ticket-git-repo.sh` | `die`/`log`/`need`, `resolve_repo_root`, `resolve_base_branch`, `run_git_net` | all three scripts |
| `lib/ticket-account.sh` | the `claude-acc` helpers: link resolution, the `flock`ed link/unlink, the account names to choose between, reading the links file back for entries claude-acc can no longer reach, and reading a started agent's `CLAUDE_CONFIG_DIR` | all three scripts |
| `lib/ticket-launcher.sh` | the worktree/tab/agent mechanics, project-memory resolution, `fill_prose`, `trust_worktree_mise`, `load_ticket_models`, `print_launch_defaults`, `launcher_main` | the two launchers |

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

## `launch.sh defaults` launches nothing

`launcher_main` answers two subcommands. `prompt` re-sends a rendered prompt after a trust
dialog, once the usual preconditions have been checked; `defaults` prints what a launch that
named neither account nor model would use, and starts nothing.

`defaults` is dispatched **ahead of every launch requirement** — before the `HERDR_ENV` check,
before `need herdr`, before anything reads a ticket. The skills run it to state the defaults in
the question they ask once a session, which happens before the developer has settled what to
launch and sometimes before they have settled whether to; that question must not depend on this
repo being ready to launch anything. It does still need `git` and a checkout, because the
account it reports is resolved at the directory the worktrees are cut in and that directory is
`dirname` of the main checkout — the same value `launcher_main` builds the worktree path from.
[`session-settings.md`](session-settings.md) has the output and what each line means.

## The one place the tab sequence forks

`launcher_main` builds the `agent` tab two ways, and the fork is not a preference — a pane
resolves its Claude account once, when its shell starts. Inheriting the account (the
default, and every launch before this existed) nothing is written, so the worktree's own tab
is renamed and the agent keeps the root pane. Overriding it, that pane's shell predates the
link, so the agent gets a tab created afterwards and the stale one is closed. Both skills
take the same fork; neither needed the function split. [`accounts.md`](accounts.md) has the
table and the reasoning.

## Trusting the new worktree's mise config

A ticket's worktree is a directory that has never existed before, and mise trusts by
path — so in a repo with a `mise.toml` the new worktree starts out **untrusted**. What
the agent then gets is not a warning: `mise` in that pane either asks to trust the path
or refuses to read the config at all (`Config files in <path> are not trusted`), and the
shell it starts in has none of the repo's toolchain on `PATH`. The `ga`-based launcher
covered this by accident, with a `sleep 2` after its `cd` that its own comment described
as letting "the cd + mise trust finish"; the synchronous `herdr worktree create` that
replaced it has no such gap, and nothing replaced the trust.

`trust_worktree_mise` runs once, in `launcher_main`, between the worktree being verified
onto disk and `link_ticket_account`. It is **best-effort and silent unless it acts**:

- No `mise` on `PATH`, or no mise config in the worktree, and it returns having printed
  nothing and written nothing. A repo like this one launches exactly as it always has.
- A failure logs a warning and the launch carries on, the way the launchers treat every
  other best-effort step. An agent without mise trust is worse off; a launch that dies
  because mise is having a bad day is worse still.
- It adds no line to the summary block, so nothing downstream has a new key to parse.

Three things about `mise` itself are load-bearing, and all three were confirmed against
the binary rather than the documentation:

- **`mise trust --show -C <dir>` is the detector**, not a list of config filenames. It
  writes one `<dir>: trusted|untrusted` line per directory to *stdout*, finds `mise.toml`,
  `.mise.toml`, `.config/mise/config.toml` and `.tool-versions` alike, and says
  `No trusted config files found.` on *stderr* when there is none. It changes nothing.
  What it really gives is stronger than a filename list: it sees what the agent's pane
  will see. A `mise.<env>.toml` shows up only when that environment is active, and the
  launcher inherits the developer's environment, so where mise would load a config this
  finds it, and where mise wouldn't there is nothing to trust.
- **It walks parents too**, so "stdout was non-empty" is the wrong test. Every worktree
  here is cut as a sibling of the main checkout, so one `mise.toml` above `<parent>/`
  would make every repo on the machine look like a mise repo. The worktree's *own* line
  is what is matched — against the **resolved** path, because mise canonicalises what
  `-C` gives it and a `$WT` with a symlinked component prints as its real path.
- **`-C <dir>`, never a config-file argument.** mise resolves a trust argument to a trust
  root lexically and says so when it refuses one: a path that isn't there "would act on
  its parent directory instead" — here, the directory holding every worktree *and* the
  main checkout. That is also why the call sits after the worktree has been proved onto
  disk rather than a line before it.

Trust is also **shared across a repo's worktrees**: a worktree of a main checkout the
developer has already trusted arrives trusted, and this does nothing at all. That is the
common case on a machine where the repo is in daily use — `lanvera/appofapps`, the repo
that motivated this, has its main checkout trusted already — which is why "already
trusted" is a real answer worth checking for rather than a call worth making anyway. What
is left for this to fix is the case where sharing doesn't apply: a main checkout that was
never trusted, and mise's paranoid mode, which turns sharing off precisely because a
worktree can hold different config contents.

### Two things it does not do, on purpose

**It trusts configs mise might not have asked about.** `mise trust --help` carves out
"safe" configs in normal mode — `min_version`, plain `[tools]` versions, `[tasks]` with
no templates or tool options — which mise reads untrusted. `--show` still calls them
`untrusted`, and there is no way to ask mise "would this one have needed it?" short of
parsing the config here, which is the brittleness the detector exists to avoid. So a repo
whose config was safe all along gains one symlink under `trusted-configs/`. That is the
deliberate trade: one inert entry, against silently skipping the repos — anything with an
`[env]` block, a templated task, or paranoid mode switched on — that do need it.

**It does not reach the worktree's own root pane.** `herdr worktree create` opens that
pane as part of creating the worktree, so its shell starts in the untrusted directory a
moment before this runs, and nothing the launcher does afterwards re-runs a `mise activate`
hook that has already fired in it. On the inheriting path — the default — that pane *is*
the agent's, so a developer who activates mise in their shell can still get an agent whose
own prompt never picked the toolchain up. It is narrower than it sounds: mise shims
resolve trust when a tool is exec'd rather than when the shell starts, and the agent's own
`Bash` shells are new shells that re-resolve after the trust landed. Closing it properly
would mean replacing or re-`cd`ing that pane, which is a change to the tab sequence
([above](#the-one-place-the-tab-sequence-forks)), not to this function — and trusting
earlier is not an option, because the directory does not exist yet and mise would act on
its parent.

### Why `/sweep-tickets` does not untrust

Deliberately not, and it is not an oversight. mise keeps trust as one symlink per
directory under `~/.local/state/mise/trusted-configs/`, so a removed worktree does leave
an entry — but that entry is **dangling and inert**: it names a path that is gone, so it
grants trust to nothing, and every one of them is visible in a single read-only command
(`find ~/.local/state/mise/trusted-configs -xtype l`), which clears the lot with `-delete`
on the end.

That is the opposite of the leak the sweep's fourth source exists for. A `claude-acc`
link survives with *no tool able to reach it* — `claude-acc unlink` takes no path and
unlinks the directory it stands in, which no longer exists — so the sweep is the only
thing that can clear it. mise's own tool is in the same bind here and worse:
`mise trust --untrust <path>` **refuses a path that no longer exists**, which is the
state every sweepable item is already in by the time it is offered. So the sweep could
only untrust *before* removal, and only for groups 1 and 2, the ones whose directory is
still on disk. Groups 3, 4 and 5 — a merged branch, an `orphan-workspace`, an
`orphan-link` — are defined by the directory already being gone, so mise could not be
asked about any of them even in principle.

Against that: a **fifth source** and a sixth group would need a row kind, a flag, its own
verb, its own refusals and its own `AskUserQuestion` option, in a skill whose contract is
already four sources and five groups — and it would be writing into a third-party tool's
state directory, which nothing else in this repo does. The sweep's own rule for
`~/.claude-switch/links` ("it is the developer's own file") applies here with more force,
not less.

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
