# Agent models

## Roles and defaults

Eleven roles. One varies per ticket; the rest are fixed per machine. The *why* behind each
placement is [ADR 0002](../adr/0002-model-tiers-and-agent-roster.md).

| Role | Agent | Default | Varies per ticket? |
|---|---|---|---|
| Implementation | `ticket-implementer` (and `/small-ticket`'s plan-mode orchestrator) | `opus` @ `medium` | **yes** — the ticket's `**Suggested model:**`/`**Suggested effort:**`, the launch question, the 4th positional and `--effort` |
| Coordination | the session each launched ticket runs | `opus` @ `low` | no — `TICKET_COORD_MODEL` / `TICKET_COORD_EFFORT` |
| Board | the board session (`board.sh`) | `haiku` @ `low` | no — `TICKET_BOARD_*` |
| Merge conflicts | `ticket-merger`, dispatched by the board | `sonnet` @ `medium` | no — `TICKET_MERGE_*` |
| Memory curation | `ticket-memory-curator`, dispatched by the board | `haiku` @ `medium` | no — `TICKET_CURATE_*` |
| Opening PRs | `ticket-pr-creator`, dispatched by the board | `sonnet` @ `low` | no — `TICKET_PR_*` |
| Review | `ticket-reviewer` | `opus` @ `medium` | no — `TICKET_REVIEW_*` |
| Testing | `ticket-tester`, one per check | `haiku` @ `low` | no — `TICKET_TEST_*` |
| Repo discovery | `ticket-scout`, one per question | `haiku` @ `low` | no — `TICKET_SCOUT_*` |
| External research | `ticket-researcher`, one per question | `haiku` @ `medium` | no — `TICKET_RESEARCH_*` |
| Acceptance | `ticket-criteria-checker`, one per criterion | `haiku` @ `low` | no — `TICKET_CHECK_*` |

All of it lives in `config/models.env`, installed by `./install.sh` as `skills/ticket-models.env`,
one file shared by the three launching skills. The shared `lib/ticket-launcher.sh` sources it and
turns it into two things:

- the **session's own** `--model`/`--effort` — the coordinator's for `/ticket` (its launcher sets
  `COORDINATOR=config`), the implementer's for `/small-ticket` (`COORDINATOR=impl`), since that
  orchestrator plans with the developer and planning is where the thinking pays;
- an **`--agents` JSON** that re-issues every installed `agents/ticket-*.md` — prompt and tools
  unchanged — with the model and effort this launch resolved for its role. A definition passed
  there outranks `~/.claude/agents/` for that session only, which is what lets one ticket's
  implementer run on `sonnet @ high` while the next one's runs on `opus @ low`, without writing a
  file anywhere.

The summary every launch prints carries `MODEL=`/`EFFORT=` (the implementer's — what run state
records), `COORDINATOR=` (the session's) and `SUBAGENTS=` (every role, `name=model/effort`).
`TICKET_SESSION_AGENTS=0` turns the `--agents` half off; subagents then run on their frontmatter,
which carries the same defaults.

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

Effort used to be one level for the whole launched session, because a subagent had no effort
of its own. It has one now: Claude Code reads an `effort:` field from a subagent's definition,
and `--agents` carries it per launch. So `TICKET_IMPL_EFFORT` (and `--effort`) is the
*implementer's* effort, and every other role has its own `TICKET_<ROLE>_EFFORT`. Under
`/small-ticket` the implementer's effort is also the orchestrator's; under `/ticket` the
coordinator runs on `TICKET_COORD_EFFORT`.

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

`herdr agent start ... -- --model "$COORD_MODEL" --effort "$COORD_EFFORT" --agents '<json>' ...`
(the coordinator's pair is the implementer's under `/small-ticket`), the launcher's
`starting '<agent>' (claude, opus, effort low, bypassPermissions) … — implementer sonnet, effort high`
log line, and the summary's `EFFORT=`, `COORDINATOR=` and `SUBAGENTS=` lines.

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
   positional argument to `launch.sh` and covers implementation only — every other role
   follows the config file. Where the session's tickets suggest different models or efforts, the
   question offers `As each ticket suggests`, a policy under which each launch passes its own
   ticket's suggestion (`session-settings.md`). A model the developer names for one ticket goes to that launch alone and leaves the
   session's setting standing.
2. **The 4th positional argument directly**, if you're calling `launch.sh` by hand:
   `launch.sh <tab-label> <branch> <ticket-file> <model>`. It's a positional argument rather than an
   env-var prefix on purpose — the skills' `allowed-tools` entries are prefix patterns like
   `Bash(~/.claude/skills/ticket/scripts/launch.sh *)`, which a `TICKET_IMPL_MODEL=x ~/.claude/...`
   prefix would no longer match.
3. **An exported `TICKET_IMPL_MODEL`** (or any other `TICKET_<ROLE>_MODEL` / `_EFFORT`) in the
   environment `launch.sh` runs in. This beats the config file but loses to the positional argument.

Resolution order, highest wins: **4th positional arg** → **exported env var** → **`config/models.env`**
→ **the in-script fallback** (matching the defaults above, in case the config
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

## The asymmetry that's gone

Until ADR 0002, `/ticket`'s launched session implemented **and** reviewed in one process, so
picking Sonnet or a `low` effort at the launch question silently downgraded the review too.
That session is now a coordinator that delegates both: the implementer gets the ticket's model
and effort, the reviewer gets `TICKET_REVIEW_*` whatever the implementer runs on. A cheap
implementer is now reviewed by the configured reviewer — the combination that most wants it.

The trade that replaced it: `/ticket` no longer runs `mattpocock-skills:code-review` in the
coordinator's own context. Its two axes are covered by `ticket-reviewer` (standards, plus
correctness and security) and `ticket-criteria-checker` (spec, criterion by criterion).

## New-model checklist

When a new model ships (a new family, or you want to pin a specific id instead of riding the alias):

1. Decide alias vs. pinned id (see "Why aliases" above), and where it belongs in the roster
   (ADR 0002's tiers: does the new model move a role?).
2. Edit `config/models.env`.
3. Mirror the same values in the `model:` and `effort:` frontmatter of every `agents/ticket-*.md`
   — the fallback for `TICKET_SESSION_AGENTS=0` and for an agent invoked outside a launch.
4. `grep -rniE 'opus|sonnet|haiku|fable' skills agents config docs lib` to catch any prose that
   names a model outside the files above — `lib/ticket-launcher.sh` holds the in-script fallbacks.
5. Re-run `./install.sh` for every Claude config root in use.
6. Smoke-test with one `/ticket` launch and one `/small-ticket` launch: the summary's
   `COORDINATOR=` and `SUBAGENTS=` lines say what was asked for, and `/agents` in the pane lists
   the `ticket-*` agents with those models.

## Frontmatter is the fallback, `--agents` is the source

Claude Code resolves a subagent's `model:`/`effort:` frontmatter at invocation time and can't
source a shell file, so `agents/*.md` carries its own copy of the defaults. It used to be the only
copy that reached an effort. Now every launch redefines the `ticket-*` agents through `--agents`
from the resolved config, so the frontmatter only applies when that's switched off
(`TICKET_SESSION_AGENTS=0`) or when an agent is invoked outside a launch. Keep it in step anyway
(step 3 above) — a stale fallback is a quiet wrong answer. The briefs still pass `model` on each
Agent tool call; it agrees with `--agents` and keeps the `general-purpose` fallback honest.
