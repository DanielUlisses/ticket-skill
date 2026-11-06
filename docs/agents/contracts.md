# Contracts, validation and rescope

Tickets are planned together and built apart. Each one says what it **provides** and what it **consumes**, so a ticket that builds the wrong thing is caught when it merges, not halfway through the ticket that needed it. tk-hub keeps the ledger and runs the validator; this repo writes the lines, gathers the evidence and applies the rescopes.

## The lines

```
**Owner:** me
**Provides:** endpoint `GET /api/contracts`; table `contract_findings`
**Consumes:** function `store.read()` (from 02); rpc `run_planner` (existing); cli `tk.sh validate` (ticket-skill:03)
```

- Items are `;`-separated, each `<kind> <name>`. Kinds (`CONTRACT_KINDS` in `board-lib.sh`): `endpoint function method class type schema table column migration env config file cli rpc event message page component metric resource output variable secret deliverable`; any other first word makes the item `other`.
- A consume ends in where it comes from: `(from NN)`, `(<repo>:NN)`, or `(existing)`. `None` or no line is an empty list.
- Each item's `key` is `<kind>:<name>`, lowercased, backticks, spaces and a trailing `()` dropped. A consume and a provide with the same key match; the validator also matches by meaning.
- `**Owner:** me` (default `ai`): the developer's ticket. It moves through the same columns as an agent's (blocked, backlog, working, review, human, pr, done — never **needs you** for being theirs), drawn in magenta. The digest leaves it out of `FRONTIER` and prints `ACTION yours <NN>` once its blockers are resolved. `tk.sh launch` refuses it unless `--helper` is passed, which opens a helper session the developer drives — on their word only (ADR 0009). `tk.sh resolve <board> <NN> --no-code "<what was done>"` resolves it from `open` (done by hand) or once its helper is done with no change; a change ships as any ticket's.

`parse_ticket_file` adds `owner`, `provides`, `consumes` (parsed), `provides_raw`, `consumes_raw` and `dropped` to every ticket, so `tk.sh export` carries them to tk-hub.

## `tk.sh validate <board> [<NN>]`

JSON on stdout, read-only, no fetch:

- `tickets[]`: `nn title status owner kind doc_type blockers xrefs parent dropped declared provides consumes body` (`body`: from `**What to build:**`, run-state lines dropped, 1500 characters).
- `unprovided[]`: consumes no ticket on this board provides (neither `existing` nor a `<repo>:NN`).
- `order[]`: consumes whose provider here isn't among the consumer's blockers, directly or through another.
- `diff` (with `<NN>`): `{nn, source, range, stat, patch, truncated, docs}` — the worktree against the ticket's base when it is still there, else the branch, else the merge commit its `**Status:**` line names; `patch` capped at 80 kB; `docs[]` the Contracts rows `check_ead.py --contracts` / `check_tdd.py --contracts` read from each HTML file the change wrote (doc tickets with `**Doc type:** ead|tdd`, checker installed under `${TICKET_SKILLS_DIR:-~/.claude/skills}/{ead,tdd,technical-design-doc}`). `null` when there is no change to show.

The `validate-contracts` skill is the validator's brief and answer format. tk-hub's daemon prepends it to the hub's ledger when it runs the validator on the planner box (`claude -p`, no tools); by hand, run `/validate-contracts` on this command's output.

## Rescope

A rescope is a plan diff a planner session proposes and the developer applies. Nothing on the board changes before `rescope-apply`.

| step | who | what |
|---|---|---|
| `tk.sh rescope <board> <NN>[,<NN>] --reason "<why>"` | `/ticket rescope …` (from tk-hub's Rescope, or typed) | opens `<board>/rescope/<id>/` (`rescope.json`, state `open`) and prints the seed |
| write `plan.json` and `issues/<NN>-<slug>.md` there | the planner | the proposal |
| `tk.sh rescope-propose <board> <id>` | the planner | checks it against the board; state `proposed` |
| `tk.sh rescope-apply <board> <id>` | the developer (tk-hub's Apply, or a terminal) | applies it; state `applied` |
| `tk.sh rescope-discard <board> <id>` | the developer | state `discarded`, the board unchanged |

`plan.json`: `{"summary": "<one line>", "changes": [{"op", "nn", "file", "files", "why"}], "findings": [<id>, ...]}`. `findings` is optional: the tk-hub validator findings (their ids) the planner says the plan fixes. `rescope-propose` refuses anything but positive whole numbers there; `tk.sh export` carries them as the rescope's `findings` (`[]` when none), and tk-hub marks them **fixes** on the rescope. tk-hub folds every open finding on a proposed rescope's tickets into the rescope whatever this list says.

- `change NN file`: an open or in-progress ticket's new body. Its run-state lines (`Status Branch Base Model Effort Account Agent Worktree`) are kept; an in-progress ticket's agent is told (`TOLD`/`NOT TOLD` line).
- `add file`: a new ticket, its number from its heading, not on the board yet.
- `split NN files`: an open ticket into new ones; the old one is dropped with "split into …".
- `drop NN`: an open ticket gets `**Status:** dropped — rescope <id> on <date>` and `**Dropped:** <date> — <why> (rescope <id>)`. It shows in **done** (`dropped`) and is never launched; a dropped blocker still blocks, and `rescope-apply` warns about any open ticket left blocked by one.

`rescope-apply` checks the plan again against the board as it is then, and applies nothing when it no longer fits. `tk.sh export` lists the rescopes still `open` or `proposed` under `rescopes[]`, each with `findings` and its plan diff (`changes[]`: `op nn title why diff into`, a change's `diff` the unified diff of the ticket file, an add's the new file). Rescope folders are skipped when tickets are loaded.

## The agent's report

A ticket's coordinator writes a `## Missing contracts` section in its report when something its Consumes line names is missing or different (`templates/ticket-agent-prompt.md`). tk-hub reads it from the synthesized report and runs the validator at the `report` moment.

## Transcripts

`tk.sh export` gives each launched ticket `transcript`: the newest Claude Code JSONL its worktree left, under `$CLAUDE_CONFIG_DIR`, `~/.claude` and every `~/.claude-switch/accounts/*`; empty when none.
