# Project memory — ticket-skill

<!-- Injected into every ticket brief launched in this repo. Short and factual:
     it costs tokens on every launch. Edited by hand; see docs/agents/memory.md. -->

## Layout

- Everything here is **bash + Markdown**. There is no runner, no test suite and no CI —
  verify by direct exercise (`bash -n`, and running the real script), and report a
  missing suite as a result rather than filling the gap by building one.
- `skills/<name>/SKILL.md` is the prose an agent follows; `scripts/launch.sh` and
  `templates/*.md` are what actually run. The `{{PLACEHOLDER}}` tokens in a template are
  substituted by that skill's `launch.sh`, nowhere else.
- `/implement-tickets` and `/sweep-tickets` are real skills with no launcher of their own:
  `/implement-tickets` reuses `/ticket`'s `launch.sh` verbatim, and `/sweep-tickets`
  launches nothing.

## Conventions

- **Editing this repo changes nothing that runs.** The skills execute from `~/.claude`
  (and any `~/.claude-switch/accounts/<name>`); `./install.sh` is what copies them there,
  and it must be re-run for every config root in use.
- `skills/small-ticket/scripts/launch.sh` and `skills/ticket/scripts/launch.sh` are
  near-identical copies. A change to one almost always belongs in the other — diff them
  before assuming they've diverged on purpose.
- Config shared by several skills is installed one level up, beside the skill
  directories (`~/.claude/skills/ticket-models.env`), never duplicated per skill.
- Agents launched by these skills **never commit**. Work is handed back unstaged and the
  developer commits it; the guardrail is `--disallowedTools` on the `herdr agent start`
  call, and it is load-bearing.

## Hard-won facts

- **Every PR in this repo is squash-merged**, so `git merge-base --is-ancestor` and
  `git branch --merged` report a landed branch as unmerged, every time. Anything deciding
  whether work landed needs a second leg (`gh pr list --head <branch> --state merged`, or
  patch ids).
- A freshly created ticket branch sits *at* the base with no commits of its own, and
  ancestry calls that "merged" too. Count commits since the base sha before trusting it.
- The launchers never assume a Herdr flag exists: `--no-focus` is probed with
  `herdr <cmd> --help` first, because the installed binary is the authority here, not
  these files. Add flags the same way. (`docs/adr/0001` records the version evaluated,
  as a dated fact — don't read it as the version installed now.)
- The `review` tab's pane belongs to the `persiyanov.reviewr` plugin, which places itself
  from its own config and ignores anything the launcher passes. The launcher waits for it
  and moves it; it cannot direct it.
- Worktrees are pinned to `../<repo>--<branch>` by `--path`, and `/sweep-tickets` reports
  against exactly that convention.
