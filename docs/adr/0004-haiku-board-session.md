# 0004 — The board session runs on Haiku, because its checks are scripts

- **Status:** Accepted (not yet run against a live Herdr / GitHub — see *Risks*)
- **Date:** 2026-10-08
- **Deciders:** Daniel Ulisses
- **Supersedes:** the "Launch here" path and the Sonnet default of [0003](0003-planner-and-board-sessions.md)

## Context

[0003](0003-planner-and-board-sessions.md) split the developer's session into an Opus planner and a
board session, but kept the board on Sonnet: its safety lived in ~7,700 words of prose — the
empty-branch guard, the squash-merge leg, lenient blocker parsing, the merge gates — and a small
model at low effort is the one most likely to skip a step.

Two facts make Haiku worth the work of moving that prose into code:

- **Price.** Haiku 5.5 is $0.10 / $0.50 per MTok — but only for prompts up to 100K tokens; above
  that it is $0.50 / $2.50. A resident session that keeps a large skill, every MCP server's tool
  schemas and the skill listing in its prompt crosses 100K early and pays five times as much.
- **The board's work is decisions on facts.** Which tickets are unblocked, has this branch landed,
  do the gates pass: none of that needs judgement once a script answers it.

## Decision

1. **The checks are scripts.** `skills/implement-tickets/scripts/`:
   - `board-lib.sh` — finds the board (either home), parses tickets to JSON, resolves free-text
     blockers to ticket numbers, answers "has it landed" (empty-branch guard → ancestry → merged PR).
   - `tk.sh` — the board's one tool: `digest` (prints only what changed, plus `FRONTIER`,
     `ACTION` and `WARN` lines the model acts on), `launch` (names, brief, launcher, run state),
     `gates` / `ready` / `merge` (the five gates; exit 10 = conflict, 11 = checks pending,
     12 = another gate), `resolve`, `say` (refuses a `blocked` agent), `show`, `helpers`, `reports`.
   - `merge-conflict.sh` — `ticket-merger`'s guard rails (below).
2. **The board session is started by `board.sh`, never inside the planning session.** It runs
   `claude --model haiku --effort low` with an ~870-word appended prompt, `--strict-mcp-config`
   (no MCP tool schemas), `--disable-slash-commands` (no skill listing), a fixed `--tools` list,
   `--autocompact 100k` (compaction before the price step), its three agents via `--agents`, and
   its scripts pre-approved. `/ticket` no longer launches anything: Phase 3 prints the `board.sh`
   command and stops. `/implement-tickets` is now a pointer to `board.sh`.
3. **Conflicts go to `ticket-merger` (Sonnet @ medium)** — the one agent in the workflow that
   commits and pushes, and only through `merge-conflict.sh`, which only ever makes a merge of the
   base into the ticket's own branch: `start` refuses while the ticket's agent is working or the
   worktree is dirty, merges without committing; the merger resolves, refuses to choose where both
   sides changed the same logic, runs the checks, and stops. The board shows the developer the
   result and asks; only on **Commit and push** does a second merger call run `finish`, which
   refuses while any unmerged path or conflict marker remains, commits the merge and pushes without
   force. The gates run again after CI.
4. **`ticket-memory-curator` (Haiku @ medium)** proposes a diff to `docs/agents/project-memory.md`
   from the tickets' `## Remember` sections. To give it something to read, every ticket now saves
   its final report to `~/.local/state/ticket-skill/<repo>/reports/<branch>.md` (`{{REPORT_FILE}}`),
   the one file a ticket writes outside its worktree. It never writes the memory file.
5. **From 0002's list, 5 and 6 are in, 3 and 4 dropped.** `fable` is offered for tickets that
   suggest `xhigh`/`max` (and `/ticket` may suggest it); a research topic two or more tickets in a
   wave share gets one researcher, folded into every brief under *Research for this wave*.

6. **PRs on request: `ticket-pr-creator` (Sonnet @ low)** — a second change, on the same
   pattern as the merger. Only when the developer names a ticket ("open a PR for 03") does the
   board dispatch it. It goes through `pr-open.sh`: `check` refuses while the ticket's agent is
   working or at a dialog, when a PR is already open, or when nothing changed, and prints the
   changed files, any `RISKY` ones (`.env`, keys, credentials), the ticket's report and the
   installed mattpocock `pr` skill's path. The agent Reads that skill — it can't call it, since the
   board runs with skills disabled — writes the body to it (`Refs #<issue>`, never `Closes`: the
   board resolves on merge), and names the files to commit. `open` refuses any path the ticket
   didn't change and any risky one, commits exactly those, pushes without force, opens the PR and
   reports what it left uncommitted. So exactly two agents ever commit or push — the merger and
   the PR creator — each only through its own script.

## Consequences

- The board's correctness no longer depends on the model executing prose faithfully; it depends on
  `board-lib.sh` and `tk.sh`, which can be tested — and were, in a sandbox with a real git remote
  and stubbed `herdr`/`gh`/launcher: frontier, unknown-blocker warnings, the empty-branch guard,
  ancestry and merged-PR landing, resolve, all five gates and their exit codes, the merger's
  refusals (working agent, leftover markers) and its push, `say` refusing a dialog, and
  `pr-open.sh` refusing a working agent, an unchanged path, a `.env` and an already-open PR,
  then committing exactly the named file and leaving the rest reported.
- `tk.sh digest` keeps writing the old text digest under `/tmp`, so `/sweep-tickets`' cross-check
  is unchanged.
- A board session can't run `/ticket` inline — design questions go to a planning session by
  design, and the board's prompt says so.

## Risks

- **`--tools` and subagents.** If a session's `--tools` bounds what its subagents may use, the
  merger needs Edit/Grep/Glob and the researcher the web tools, so they're in the list — a few
  thousand tokens of definitions the board itself never calls. Trim once confirmed either way.
- **The mattpocock skills need v1.3 or later** for `pr` and `retro`; `pr-open.sh check` and
  `tk.sh retro` print `none found` for a missing one, and the agents fall back to the template or
  the categories in their own prompt.
- **`--disable-slash-commands`** may also hide `mattpocock-skills:resolving-merge-conflicts` from
  the merger; its prompt carries the procedure itself. `TICKET_BOARD_SKILLS=1` brings skills back.
- **Not yet run live.** First real board: check `board.sh --print`, then that the first digest,
  one launch and one `merge` behave as in the sandbox.
