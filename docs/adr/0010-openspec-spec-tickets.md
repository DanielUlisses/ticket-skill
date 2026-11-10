# 0010 — OpenSpec repos run tickets as `**Kind:** spec`

- **Status:** Proposed. Nothing here is built yet. This record is the integration plan for the
  first client project that does spec-driven development with OpenSpec.
- **Date:** 2026-11-10
- **Deciders:** Daniel Ulisses
- **Builds on:** [0007](0007-doc-tickets-on-the-board.md) (`**Kind:**` is an open list),
  [0005](0005-scratch-boards-retro-and-presales.md) §7–§9 (forge, merge, no attribution),
  [0008](0008-forge-less-remotes-are-local-mode.md) (local mode)

Some client projects plan to use spec-driven development with [OpenSpec](https://github.com/Fission-AI/OpenSpec)
as their framework. In those repos, a change in behaviour is expected to be written as an OpenSpec
**change** first, built from it, and folded into the repo's living spec when it lands. This record
says how our tickets do that without a second pipeline: OpenSpec gives the spec format and a CLI
check, and the board, the launcher, the gates and tk-hub keep running the work.

## What OpenSpec is (v1.11.0, August 2026)

- The living spec: `openspec/specs/<capability>/spec.md` (nested capability folders allowed).
- A change: `openspec/changes/<name>/` holding `proposal.md` (why and what), `specs/` (delta specs),
  an optional `design.md`, and `tasks.md` (numbered `## N.` groups of checkbox tasks, each saying how
  it is verified; nested boxes count).
- Delta specs: `## ADDED|MODIFIED|REMOVED|RENAMED Requirements`, each `### Requirement: <name>`
  (SHALL/MUST) with `#### Scenario: <name>` and `- **WHEN** …` / `- **THEN** …` lines. A MODIFIED
  requirement restates every scenario it keeps. `skip_specs: true` lets a refactor carry no deltas.
- Archive merges the deltas into `openspec/specs/` and moves the change to
  `openspec/changes/archive/YYYY-MM-DD-<name>/`. It exits non-zero when blocked (a scenario would be
  lost), and without a TTY it prints the flag it needs and a rerun command.
- CLI: `openspec init --tools <tool>`, `update`, `list`, `show <change> [--json] [--diff]`,
  `validate <change> [--strict]` (also `--all`, `--changes`, `--specs`, `--archived`),
  `status [--all]` (JSON), `instructions apply|archive`, `archive`.
- Claude Code slash commands, installed into the repo by `openspec init`: `/opsx:explore`,
  `/opsx:propose`, `/opsx:apply`, `/opsx:archive`, and with the expanded profile `/opsx:new`,
  `/opsx:continue`, `/opsx:ff`, `/opsx:verify`, `/opsx:update`, `/opsx:bulk-archive`.
- Several changes may be open at once. Releases come about weekly. The CLI sends anonymous
  telemetry unless `OPENSPEC_TELEMETRY=0` (or `DO_NOT_TRACK=1`).

**To confirm before building** (§9): the exact non-interactive flag of `openspec archive`, and how
`/opsx:apply` marks a task done in `tasks.md`.

## 1. Options considered

| | What it is | Verdict |
|---|---|---|
| **A** | The ticket brief tells the agent to run `/opsx:apply <change>` in its worktree. | Rejected. It drops our phases (scouts, testers, one criteria checker per criterion, the reviewer, the fix loop), the per-role models (ADR 0002), the test plan and `## Remember`. `apply` is built for a person watching it. |
| **B** | A new kind, `spec`: OpenSpec is the format and its CLI a gate; our pipeline builds, checks and merges. | **Chosen.** |
| **C** | `tk.sh import-openspec <board>`: turn changes a client team already wrote with `/opsx:propose` into `spec` tickets, skipping our grill. | Later, on top of B, when a client team writes its own proposals. |

## 2. One change per ticket

The ticket is our unit of parallel work: one worktree, one agent, one review, one merge. The change
is the same unit, named `<board>-<NN>-<slug>`. One change per board would have several worktrees
editing one `tasks.md` and archive only after every ticket had merged, so `main` would carry code
whose spec still reads as proposed.

| Ours | OpenSpec |
|---|---|
| `/ticket` grill and breakdown | `/opsx:explore` and `/opsx:propose` |
| The ticket's brief and scope | `proposal.md` (the ticket points at it, not a copy) |
| Acceptance criteria | The scenarios in the delta specs |
| Implementation notes | `design.md`, `tasks.md` |
| `**Provides:**` / `**Consumes:**` | none (requirements are behaviour, contracts are interfaces; both stay) |
| `tk.sh gates` | plus `openspec validate --strict` and every task done |
| Merge | `openspec archive`, in the ticket's branch (§6) |
| Test plan, `## Remember`, retro, batches | none (ours; unchanged) |

## 3. Opting in: a repo policy key

A repo opts in with `"spec": "openspec"` in `.scratch/policy.json` (repo layer only, read like
`base_branch`; `docs/agents/policy.md`). With it, `/ticket` writes every code ticket as
`**Kind:** spec`; doc tickets stay `doc`, and `**Owner:** me` tickets are unaffected. An `openspec/`
folder without the key changes nothing, so a repo that keeps OpenSpec for humans only is not
pulled in. `TICKET_KINDS` in `board-lib.sh` becomes `code doc spec`.

## 4. Planning: `/ticket` writes the change

After the grill, for each `spec` ticket, `/ticket`:

1. writes `openspec/changes/<board>-<NN>-<slug>/` with `proposal.md`, the delta specs (one
   scenario per acceptance criterion), `tasks.md`, and `design.md` when the grill settled a design;
   a refactor or a test-only ticket sets `skip_specs: true`;
2. runs `openspec validate <change> --strict` and fixes what it reports before handing off;
3. adds `**Spec:** openspec/changes/<change>` to the ticket and keeps the ticket's criteria list as
   the scenario names, so a reader of the board needs no second file.

The change files live in the repo's working tree, not `.scratch/`: they are the client's artifacts
and ship with the code. `/ticket` writes them on the base branch's checkout uncommitted, and the
ticket's worktree picks them up at launch the same way it picks up the base (the launcher copies
the change folder into the new worktree). Two tickets that change the same requirement get a
`**Blocked by:**` between them, so their archives never conflict in `openspec/specs/`.

`/ticket rescope` edits the change with the ticket: change keeps run state and rewrites the change
files, split makes a second change, drop deletes the change folder (`tk.sh rescope-apply`).

## 5. Building: the spec brief

`tk.sh launch` gets a `spec)` arm that passes `--spec <change>`. The launcher renders
`skills/ticket/templates/ticket-spec-prompt.md`, a variant of `ticket-agent-prompt.md`:

- **Recon** also reads the change and the current `openspec/specs/` files its deltas touch.
- **Implement**: `ticket-implementer` works `tasks.md` group by group and ticks each task as it
  lands, with the evidence the task names. TDD seams are unchanged; a scenario is a natural test.
- **Verify**: one `ticket-criteria-checker` per scenario; `ticket-reviewer` gets the delta specs next
  to the diff and checks the code against the requirements, not only against the ticket's words.
  A finding that the spec itself is wrong goes back as a question (`docs/agents/questions.md`), never
  as an edit to the spec by the reviewer.
- **Report**: unchanged, plus one line: `SPEC <change> tasks=<done>/<total> validate=pass|fail`.

Models and effort come from `config/models.env` as for a code ticket. No new role.

## 6. Gates and archive

- One more gate for `spec` tickets, `spec`, after the existing ones: passes when
  `openspec validate <change> --strict` exits 0 and `openspec status` shows every task done.
  Recorded in run state like `tests=`.
- `tk.sh pr`, `tk.sh push` and the local `tk.sh merge` run `openspec archive <change>` non-interactively
  in the ticket's worktree after the gates and before the commit, so the one commit (and the PR)
  holds the code, the updated `openspec/specs/` and the archived change. A blocked archive stops
  the step with the CLI's message and exit 14; nothing is pushed.
- A conflict in `openspec/specs/` at merge is a merge conflict like any other: `ticket-merger`
  resolves it, then re-runs `openspec validate --specs --strict`.
- Archiving only after the deploy is proven (some teams do) would need a policy switch
  `spec_archive: pr|after-deploy` and a follow-up commit on the base, which our flow avoids. Not
  built until a client asks.

## 7. tk-hub

Nothing in tk-hub reads `kind`, so `spec` tickets show, launch, merge and deploy as code tickets
do, with no hub change. Later, optional: `tk.sh export` adds `spec` (the change id) per ticket and
the daemon an RPC returning `openspec show <change> --json --diff`, which the ticket thread shows in
the side pane next to the code diff. The contract validator does not read specs in the first version.

## 8. Devboxes

The `openspec` CLI (npm `@fission-ai/openspec`) becomes a devboxes package at a pinned version,
bumped on purpose because validation rules have changed between minor releases. `OPENSPEC_TELEMETRY=0`
is set box-wide. The slash commands stay in the client repo (`openspec init --tools claude` is the
client team's call) and are never installed into `~/.claude`.

## 9. Building it

When a project needs it, in this order (each one ticket):

1. **Spike** in a scratch repo: `openspec init`, a change by hand, `/opsx:apply` once to see how it
   ticks tasks, and `openspec archive` with no TTY to learn its flag. Update this record.
2. Devboxes package and env (§8).
3. The kind and policy key (§3), `TICKET_KINDS`, the `spec)` arm, `--spec` in the launcher, and
   `TICKET_DRY_RUN=1` showing it.
4. `/ticket` writes and validates changes (§4), including rescope.
5. `ticket-spec-prompt.md` (§5).
6. The `spec` gate and archive in `tk.sh` (§6), on the forge and in local mode.
7. Optional: the hub's spec pane (§7). Optional: option C's import.

Then this record moves to Accepted and `CLAUDE.md` and `docs/agents/` gain the usual pages.

## 10. Consequences

- A repo that never sets the key sees no change.
- In an OpenSpec repo, tickets carry two linked artifacts (the ticket and its change); the ticket
  stays the one the board, the hub and the developer read.
- The pinned CLI is one more thing `devbox-sync` keeps current.
