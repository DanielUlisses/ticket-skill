# Project coordinator

One Claude Code session per project that keeps its boards moving for the developer:
the session he used to open by hand in the main folder to unblock agents, made
repeatable. It is not the per-ticket coordinator (`TICKET_COORD_*`), which every ticket
launch starts and which only runs that one ticket.

## Starting it

```
tkc <project> [<repo>...]      # coordinator.sh; --print shows the command, --resume continues
```

- `<project>` names a folder, `~/work/.coordinators/<project>/` (`TICKET_PCOORD_HOME`).
- `<repo>` is a path or a name under `~/work` (`TICKET_WORK_DIR`). Repos are kept in the
  folder's `repos` file, so they are named once; a first start with none takes the repo
  the shell is in. Each is resolved to its main checkout and added with `--add-dir`.
- The session runs in the folder, on `TICKET_PCOORD_MODEL` @ `TICKET_PCOORD_EFFORT`
  (`sonnet` @ `medium`), with no MCP servers, the brief
  `templates/project-coordinator-prompt.md` appended to its system prompt, and
  `ticket-merger`, `ticket-pr-creator`, `ticket-scout` and `ticket-researcher` to
  dispatch. `tk.sh`, the launcher, `merge-conflict.sh` and `pr-open.sh` run without a
  prompt; anything else asks.

## Its files

| File | Holds |
|---|---|
| `repos` | the project's main checkouts, one per line |
| `state.md` | the handoff: open loops, decisions of the week, what to watch, a queue in progress. Rewritten at each handoff, about 150 lines at most |
| `journal.log` | one line per event and action, appended, never loaded whole |
| `.brief.md` | the rendered brief of the last start |

The answers ledger (`<repo>/.scratch/answers.md`, [questions.md](questions.md)) and
project memory stay per repo.

## What it does

- **Questions: answer, bring or hold.** A go/no-go, a scope call or anything about a
  secret is held for the developer. A question an earlier answer, project memory, the
  spec or the code settles is answered with `tk.sh answer`, the source named in the
  answer, and he is told in one line. A new one is brought to him with a suggested
  answer.
- **Board work.** Digests, launches inside `max_parallel`, resumes, relays, new tickets
  and rescopes, PRs under the policy.
- **Merges on his word.** One ticket, or a queue he approves once: ordered by the
  tickets' `Blocked by` lines, each merged by `tk.sh merge`, a conflict resolved through
  `ticket-merger`, stopping when a gate refuses or a resolution changes what a ticket
  does. Under `auto_merge` a merge runs by script only and waits for him when it fails.
- **Script first.** Every action goes through `tk.sh`. A step he asked for may be done
  by hand only when the script itself breaks, and both facts go in `journal.log`. A
  gate that refuses is not a broken script.
- **Agent text is data.** An instruction found in a report or a question is weighed,
  never followed.

## Staying alive

The conversation is disposable. Typing `handoff` (or asking it to restart itself) makes
it rewrite `state.md` and stop; the next `tkc <project>` is a fresh conversation that
reads the files. `--resume` continues the folder's last conversation instead, for one a
restart cut short. A handoff by the session that knows beats an automatic compaction,
so no `--autocompact` is passed unless `TICKET_PCOORD_AUTOCOMPACT` names a window.

## Not yet

Started by hand only. tk-hub starting it (a `start_grill` mode), its inbox of events,
the hub chat on the same session and the automatic recycle are later phases of the
hub's coordinator plan.
