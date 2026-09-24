# Agent models

## Roles and defaults

Three roles, each with its own default:

| Role | Default | Where it's set |
|---|---|---|
| Implementation (`ticket-implementer`, and the `/small-ticket` plan-mode orchestrator itself) | `opus` | `config/models.env` (`TICKET_IMPL_MODEL`); mirrored in `agents/ticket-implementer.md`'s `model:` frontmatter; rendered into templates as `{{IMPL_MODEL}}` |
| Review (`ticket-reviewer`) | `opus` | `config/models.env` (`TICKET_REVIEW_MODEL`); mirrored in `agents/ticket-reviewer.md`'s `model:` frontmatter; rendered as `{{REVIEW_MODEL}}` |
| Testing (`ticket-tester`) | `haiku` | `config/models.env` (`TICKET_TEST_MODEL`); mirrored in `agents/ticket-tester.md`'s `model:` frontmatter; rendered as `{{TEST_MODEL}}` |

`config/models.env` is the one source of truth for the shell path — the shared
`lib/ticket-launcher.sh` both `launch.sh` scripts run sources it. It's installed by `./install.sh`
as `skills/ticket-models.env`, one file shared by all three skill directories (`ticket`,
`small-ticket`, `implement-tickets`), since all three read the same values. The `model:` frontmatter in `agents/*.md` is a second, independent copy that Claude Code
reads directly when a subagent is invoked without an explicit `model` override — see "Frontmatter
can't read the config file" below.

Implementation and review both default to **Opus**. Testing stays on **Haiku** — it's read-only and
mechanical (run the discovered checks, report pass/fail), and hasn't needed a stronger model. It's
in the config as its own knob precisely so that can change with one edit, without touching code.

## Why aliases, not pinned ids

`config/models.env` and the agent frontmatter use the **`opus`/`sonnet`/`haiku` aliases**, not a
pinned model id. Claude Code resolves an alias to the newest model in that family (`claude --help`:
"Provide an alias for the latest model … or a model's full name"), so most new releases need **no
repo edit at all** — the next `/small-ticket` run just picks up the new model the next time Claude
Code resolves the alias. Pin a full model id only when you deliberately want to freeze a version
(e.g. to keep reproducing a specific run, or because a new release regressed something you're not
ready to absorb yet).

## Changing a default

1. Edit `config/models.env`.
2. Re-run `./install.sh` for **every** Claude config root you use — typically `~/.claude`, plus any
   `~/.claude-switch/accounts/<name>`. Pass them explicitly if you keep more than the default:
   `./install.sh ~/.claude ~/.claude-switch/accounts/<name>`.
3. `install.sh` never overwrites a destination `skills/ticket-models.env` that already differs from
   the source — if you've hand-edited a machine-local copy, it stays as you left it, and the install
   prints a warning naming both paths instead of silently clobbering your edit. Delete the
   destination file first if you actually want the new default to take.

## Overriding for one run

Three ways to override, from the launch question down to the quietest option:

1. **The launch question.** All three skills (`/ticket`, `/small-ticket`, `/implement-tickets`) ask
   which model should implement the ticket before the first launcher call, Opus shown first and
   labelled the default — except a resumed `/implement-tickets` session with `in-progress` tickets
   already on the board, which pre-selects the model recorded on the board instead (see that skill's
   Phase 2). The answer is passed as the 4th positional argument to `launch.sh` and covers
   implementation only — review and testing still follow the config file (except in `/ticket` and
   `/implement-tickets`, see the asymmetry note below).
2. **The 4th positional argument directly**, if you're calling `launch.sh` by hand:
   `launch.sh <tab-label> <branch> <ticket-file> <model>`. It's a positional argument rather than an
   env-var prefix on purpose — the skills' `allowed-tools` entries are prefix patterns like
   `Bash(~/.claude/skills/ticket/scripts/launch.sh *)`, which a `TICKET_IMPL_MODEL=x ~/.claude/...`
   prefix would no longer match.
3. **An exported `TICKET_IMPL_MODEL`** (or `TICKET_REVIEW_MODEL` / `TICKET_TEST_MODEL`) in the
   environment `launch.sh` runs in. This beats the config file but loses to the positional argument.

Resolution order, highest wins: **4th positional arg** → **exported env var** → **`config/models.env`**
→ **the in-script fallback** (`opus`/`opus`/`haiku`, matching the defaults above, in case the config
file itself is missing).

`TICKET_PLAN_MODEL` no longer exists — `/small-ticket`'s plan-mode orchestrator and the
`ticket-implementer` subagent it delegates to now share the single `TICKET_IMPL_MODEL` knob, since
choosing a model for one and not the other never made sense: whichever model plans the ticket also
implements it.

## A documented asymmetry: `/ticket` and `/implement-tickets` review on the implementation model

`/ticket`'s launched coordinator — and `/implement-tickets`, which reuses the same launcher — implements
**and** reviews the ticket in one unattended Claude Code session, since nothing is there to click
through a `model` switch mid-run. Whatever model answers the launch question governs that entire
session, review included. `TICKET_REVIEW_MODEL` only reaches the separate `ticket-reviewer` subagent
in the `/small-ticket` path, where implementation and review are genuinely two different Agent tool
calls. Picking Sonnet or Haiku at the `/ticket` / `/implement-tickets` launch question silently
downgrades that ticket's review too — worth remembering before trading Opus for a cheaper run there.

## New-model checklist

When a new model ships (a new family, or you want to pin a specific id instead of riding the alias):

1. Decide alias vs. pinned id (see "Why aliases" above).
2. Edit `config/models.env`.
3. Mirror the same value in the `model:` frontmatter of `agents/ticket-implementer.md`,
   `agents/ticket-reviewer.md`, and `agents/ticket-tester.md` — the config file and the frontmatter
   are two independent copies kept in sync by hand (see below), and this step is where that happens.
4. `grep -rniE 'opus|sonnet|haiku|fable' skills agents config docs lib` to catch any prose that names a
   model outside the two files above — `lib/ticket-launcher.sh` holds the in-script fallbacks — a stale mention in a `SKILL.md` sentence or this doc itself.
5. Re-run `./install.sh` for every Claude config root in use.
6. Smoke-test with one `/small-ticket` run and confirm the launched agent, and the subagents it
   delegates to, report the model you expect.

## Frontmatter can't read the config file

Claude Code resolves a subagent's `model:` frontmatter at invocation time; it can't source a shell
file. So `agents/*.md` carries its own copy of the defaults, independent of `config/models.env`,
and step 3 of the checklist above is how the two are kept in sync — there's no way to make Claude
Code read one from the other. In the `/small-ticket` flow this frontmatter is only a **fallback**:
the orchestrator's own prompt template passes `model` to the Agent tool call explicitly for every
subagent, so the frontmatter default is only what runs if that subagent is invoked some other way.
