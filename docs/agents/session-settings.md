# The session's launch settings

Which Claude **account** a ticket bills to, which **model** implements it and at what
**effort** that model thinks are settled **once per session**, at the first launch, and every
launch in that session uses the answer. The knobs themselves are owned elsewhere —
[`accounts.md`](accounts.md) owns `--account`, [`models.md`](models.md) owns the model and the
effort. This is about *when the values are decided, and by whom*.

## What was wrong with asking per ticket, and with not asking at all

Two half-measures, neither of which fits how a session actually runs:

- `/small-ticket` asked **every** ticket which model should implement it. A session's work
  usually belongs to one model, so the second and third answers are the first one retyped.
- `/ticket` and `/implement-tickets` asked nothing about the account. It came from whichever
  directory link happened to apply, which made it inherited rather than chosen.

The second failure is not theoretical. Every ticket this repo launched up to 2026-09-24 ran
on a work account, because `~/.claude-switch/links` mapped the directory the worktrees land
in and nothing in the output said so. [#15](accounts.md) fixed the *reporting* — the
`ACCOUNT=` summary line, and post-start verification against the agent's own process. This
fixes the *choosing*.

## The shape

One question, asked once, covering every setting — not one question per setting and not one
per ticket. In a skill that is a single `AskUserQuestion` call carrying one question per
setting, and the answer is held for the rest of the session.

| Setting | Default | Reaches the launcher as |
|---|---|---|
| Account | inherited — **not asked**: each devbox has one Claude account | no flag; `--account <name>` only when the developer names one |
| Model | the ticket's suggestion, else `ticket-models.env` ([`models.md`](models.md)) | the positional `[model]`, always passed explicitly |
| Effort | the ticket's suggestion, else `medium` from `ticket-models.env` ([`models.md`](models.md)) | `--effort <level>`, always passed explicitly |

A further setting is another row and another field carried through the session, not another
round of questions — which is what the table shape is for. Effort was the first setting added
after that sentence was written, and it went in as a row.

Model and effort differ from the account in where their *default* comes from: the ticket
itself can suggest one. `/ticket` Phase 2 writes `**Suggested model:**` and
`**Suggested effort:**` lines into each ticket body, each with one clause of justification,
and the launch question offers them pre-selected instead of the launcher's bare defaults — the
coordinator suggests, the developer decides, the same asymmetry project memory has. A ticket
carrying no such line (every ticket written before them) falls back to `MODEL=` / `EFFORT=`.

Where a wave's tickets disagree, the question pre-selects **`As each ticket suggests`**: a
*policy* rather than a value. The session holds it exactly as it would hold a value — settled
once, never re-asked — and every launch under it passes that ticket's own suggestion. This
replaced "pre-select the highest of them", which made sense while one effort governed the
whole launched session; now that it reaches only the implementer
([`../adr/0002-model-tiers-and-agent-roster.md`](../adr/0002-model-tiers-and-agent-roster.md)),
a one-line ticket has no reason to pay for its neighbour's `high`.

What the session settles is the **implementer's** model and effort. The coordinator each launched
ticket runs on, and every helper role, come from `config/models.env`, and
`launch.sh defaults` names the coordinator's in a `COORDINATOR=` line so the question can say so.

Three rules follow from "settled once":

- **A session that launches nothing asks nothing.** The question goes immediately before the
  first launch, never on load: the board session asks after the developer has picked a wave,
  `/small-ticket` after it has a ticket, and a round that starts nothing asks nothing. `/ticket`
  never asks: since ADR 0004 it launches nothing — the board session does.
- **One launch can override without disturbing the session.** A value the developer names for
  a single ticket goes to that launch alone; the next ticket uses the session's settings again.
- **The session's setting changes only on request**, and then applies to every launch after it.
  Tickets already running keep what they launched on.

## Stating the defaults: `launch.sh defaults`

A question that offers a default has to name the right one, and both defaults are easy to get
wrong from inside a session. So the skills read them rather than assuming them:

```bash
$ ~/.claude/skills/ticket/scripts/launch.sh defaults
MODEL=opus (from /home/you/.claude/skills/ticket-models.env)
EFFORT=medium (from /home/you/.claude/skills/ticket-models.env)
EFFORTS=low medium high xhigh max
ACCOUNT=default (inherited by a new worktree in /home/you/repos — config root ~/.claude)
ACCOUNTS=default work
```

It reads, starts nothing, and needs neither a ticket nor a Herdr pane — it runs before the
developer has settled what to launch, sometimes before they have settled whether to. It does
need `git` and a checkout to stand in, since the account it reports is resolved at the
directory the worktrees are cut in.

- **`MODEL=`** says which value *and where it came from*: an exported `TICKET_IMPL_MODEL`, the
  installed `ticket-models.env`, or the launcher's built-in fallback. It has to be read before
  the config file is sourced to be able to say: the file sets its values with `:=`, so an
  exported variable wins silently and afterwards the two are indistinguishable.
- **`EFFORT=`** is the same line for the effort, with its source named the same way. On a
  machine whose `ticket-models.env` predates the effort knob it reads
  `(from the launcher's built-in fallback — nothing set it in <path>)`, which is `medium` and
  is the truth: `install.sh` never overwrites a destination config, so that file keeps saying
  nothing about effort. **`EFFORTS=`** is its option list, printed for the same reason
  `ACCOUNTS=` is — so the question doesn't carry its own copy of a list the launcher owns.
- **`ACCOUNT=`** is the account a **new worktree** would inherit — resolved at the directory
  the worktrees are cut in, which is the parent of the main checkout. That is a *different
  question* from which account the asking session is running under, and the difference is the
  whole point: a session inside a worktree that overrode its own account would otherwise offer
  that account as "the default" and quietly launch everything somewhere else.
- **`ACCOUNTS=`** is the option list. No skill has `claude-acc` in its `allowed-tools`, and
  none needs it: the names come from the same layout `account_exists` already checks.

Neither degraded case stops the question. No `claude-acc` on the machine prints
`ACCOUNT=default (claude-acc isn't installed …)`, which is the truth; a `claude-acc` that
can't resolve the directory prints `ACCOUNT=unknown …`, which is a reason to ask the
developer rather than to guess.

## Where a wave records what it chose

The board session (`tk.sh launch`) writes `**Model:**`, `**Effort:**` and `**Account:**` into each ticket's run
state at launch, from the launcher's own lines rather than from what was asked for — the
`ACCOUNT=` one in particular being verified in the pane. Those summary lines are bare values
(`MODEL=opus`, `EFFORT=high`) — they say what launched, where the same-named lines from
`defaults` carry a `(from …)` saying where a value *would* come from. Different commands,
different questions. `**Effort:**` there is a record of what
the ticket launched at, and is a different line from the body's `**Suggested effort:**`, which is
the author's recommendation and is never rewritten.
Two things hang off that: a resumed session pre-selects what the board is already running on
instead of drifting onto another model or another subscription, and a resolved ticket keeps
the record of what implemented it and what paid for it. A later change to the session's
settings never rewrites them — they say what that ticket is running on.
