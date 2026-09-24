# Agent models

## Roles and defaults

Three roles, each with its own default:

| Role | Default | Where it's set |
|---|---|---|
| Implementation (`ticket-implementer`, and the `/small-ticket` plan-mode orchestrator itself) | `opus` | `config/models.env` (`TICKET_IMPL_MODEL`); mirrored in `agents/ticket-implementer.md`'s `model:` frontmatter; rendered into templates as `{{IMPL_MODEL}}` |
| Review (`ticket-reviewer`) | `opus` | `config/models.env` (`TICKET_REVIEW_MODEL`); mirrored in `agents/ticket-reviewer.md`'s `model:` frontmatter; rendered as `{{REVIEW_MODEL}}` |
| Testing (`ticket-tester`) | `haiku` | `config/models.env` (`TICKET_TEST_MODEL`); mirrored in `agents/ticket-tester.md`'s `model:` frontmatter; rendered as `{{TEST_MODEL}}` |

**Effort** is a fourth knob in the same file (`TICKET_IMPL_EFFORT`, default `medium`) but not a
fourth row: it is one level for the whole launched session rather than one per role, and it has
no frontmatter counterpart, because a subagent has no effort of its own. Its own section is
below.

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

## Effort: how hard the implementation model thinks

A model is only half the choice. Claude Code takes `--effort <low|medium|high|xhigh|max>`, and
until this knob existed every ticket ran at whatever the CLI defaulted to — chosen by nobody.
`TICKET_IMPL_EFFORT` in `config/models.env` is the other half, defaulting to **`medium`**.

There is one effort, not three. It is the *session's*, set on the `claude` process the launcher
starts, so unlike the model it can't be handed separately to a subagent: `ticket-reviewer` and
`ticket-tester` run at whatever their pane runs at. `config/models.env` says as much next to the
line.

### Resolution order

Highest wins, the same four steps the model has: **the `--effort <level>` flag** →
**an exported `TICKET_IMPL_EFFORT`** → **`config/models.env`** (installed as
`ticket-models.env`) → **the in-script fallback `medium`** in `lib/ticket-launcher.sh`.

`launch.sh defaults` prints the answer that order gives, as `EFFORT=<level> (from <source>)`,
naming its source exactly as the `MODEL=` line names its own — and for the same reason: the
config file sets its values with `:=`, so an exported variable wins silently and afterwards
the two are indistinguishable. It also prints `EFFORTS=low medium high xhigh max`, the option
list for the launch question, so no skill has to keep its own copy of the five levels.

One place legitimately does keep a copy: `/ticket` Phase 2 names the five levels inline, because
it writes each ticket's `**Suggested effort:**` long before the session reaches a launcher call
and so has no `EFFORTS=` to read. That is the exception, and the only one — anything asked *at*
launch time reads the list rather than repeating it.

### A flag, not a fifth positional

`--effort <level>` / `--effort=<level>`, alongside `--account`, not a fifth positional argument
next to the model. `--account` had already established the shape for a parameter that is
usually absent, and the model's positional slot is only bearable because the model is the one
thing that varies every run; a fifth bare word would make the call site a row nobody can read
back. The flag also wins over an exported `TICKET_IMPL_EFFORT` for the reason the model's
positional does: the skills' `allowed-tools` entries are prefix patterns like
`Bash(~/.claude/skills/ticket/scripts/launch.sh *)`, which a `TICKET_IMPL_EFFORT=x ~/.claude/...`
prefix would no longer match.

### Why the launcher validates

`claude --effort bogus` is **not** an error. It prints

```
Warning: Unknown --effort value 'bogus' — ignoring it and using the default effort. Valid values: low, medium, high, xhigh, max.
```

and runs anyway. A typo would therefore launch a whole unattended ticket at an effort nobody
chose, with nothing in the summary saying so. So the launcher refuses anything outside the five
levels — from the flag, from the environment, or from the config file — and exits non-zero
before the worktree exists. The check is exact and case-sensitive, matching the CLI: `LOW` and
the empty string are refused like any other unknown value.

It runs *after* the resolution order has settled, never before it: a bad exported
`TICKET_IMPL_EFFORT` fails a launch that named no level, but it does not veto one that passed
`--effort high`, because the flag outranks it. `launch.sh defaults` takes no flags, so there it
is the resolved value that gets checked — a `defaults` that quoted a level Claude Code would
silently ignore would be worse than one that refuses to answer.

### Where it shows up

`herdr agent start ... -- --model "$IMPL_MODEL" --effort "$IMPL_EFFORT" ...`, the launcher's
`starting '<agent>' (claude, opus, effort medium, bypassPermissions)` log line, and the
`EFFORT=` line of the summary every launch prints, next to its new `MODEL=` line and the
`ACCOUNT=` line that was already there.

### A `ticket-models.env` installed before this existed

`install.sh` needs no change for this knob, and deliberately gets none — but it also never
overwrites a destination `skills/ticket-models.env` that differs from the source, so a machine
installed before this ticket keeps a config file with no `TICKET_IMPL_EFFORT` line in it. That
is covered, and covered by design: the file simply sets nothing, the in-script fallback gives
`medium`, and `launch.sh defaults` says so in as many words —
`EFFORT=medium (from the launcher's built-in fallback — nothing set it in <path>)`. Nothing is
broken and nothing needs doing. Deleting the destination file and re-running `./install.sh` is
how you pick up the new commented default, and is only worth it if you want to edit it there.

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
   which model should implement the ticket — and, in the same call, at which effort — **once a
   session**, before its first launcher call,
   together with the account and with the default named by `launch.sh defaults` rather than assumed
   (`session-settings.md`). Every later launch in that session reuses the answer, waves included; a
   resumed `/implement-tickets` session with `in-progress` tickets already on the board pre-selects
   the model recorded there instead (see that skill's Phase 2). The answer is passed as the 4th
   positional argument to `launch.sh` and covers implementation only — review and testing still
   follow the config file (except in `/ticket` and `/implement-tickets`, see the asymmetry note
   below). A model the developer names for one ticket goes to that launch alone and leaves the
   session's setting standing.
2. **The 4th positional argument directly**, if you're calling `launch.sh` by hand:
   `launch.sh <tab-label> <branch> <ticket-file> <model>`. It's a positional argument rather than an
   env-var prefix on purpose — the skills' `allowed-tools` entries are prefix patterns like
   `Bash(~/.claude/skills/ticket/scripts/launch.sh *)`, which a `TICKET_IMPL_MODEL=x ~/.claude/...`
   prefix would no longer match.
3. **An exported `TICKET_IMPL_MODEL`** (or `TICKET_REVIEW_MODEL` / `TICKET_TEST_MODEL`) in the
   environment `launch.sh` runs in. This beats the config file but loses to the positional argument.

Resolution order, highest wins: **4th positional arg** → **exported env var** → **`config/models.env`**
→ **the in-script fallback** (`opus`/`opus`/`haiku`, matching the defaults above, in case the config
file itself is missing). Effort follows the same four steps with `--effort` in the first slot — see
"Effort: how hard the implementation model thinks" above.

`launch.sh defaults` prints the answer that order would give for the implementation model, and says
which of the three it came from — which is what the launch question states as its default. The
source has to be read before the config file is sourced: `models.env` sets its values with `:=`, so
an exported `TICKET_IMPL_MODEL` wins silently and afterwards the two are indistinguishable.

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

**The same applies to effort, and more widely.** Whatever effort answers the launch question is
the `claude` process's for that whole session, so in `/ticket` and `/implement-tickets` it
governs the review as well as the implementation — picking `low` there buys a shallower review
along with a cheaper run. Effort has no `/small-ticket` escape hatch either: there is no
`TICKET_REVIEW_EFFORT`, because effort is a property of the session, not an argument the
orchestrator can pass to an Agent tool call the way it passes `model`. In `/small-ticket` the
level governs the plan-mode orchestrator, and the subagents it delegates to inherit the pane's.

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
