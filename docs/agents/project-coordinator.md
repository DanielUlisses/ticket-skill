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
  (`sonnet` @ `medium`), with only the MCP servers the policy key `mcp` names in the
  box layer, its repos' `.scratch/policy.json` or their boards' (`docs/agents/policy.md`;
  the files are devboxes' `mcp_servers`) and no others (`--strict-mcp-config`), the brief
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
| `inbox/*.json` | one event each, handed over by tk-hub's daemon; the session moves what it handled to `inbox/done/` |
| `artifacts/` | files the session keeps for the developer (a report, a plan's output), one line on each in `<name>.note`; tk-hub's daemon sends them to the hub's Artifacts page |
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

## Threads

The coordinator is the one the developer talks to, not the one who does the deep work. It answers quick asks and lookups itself (a digest, a status, one file, the ledger) and opens a **thread** for anything deeper: troubleshooting, reading code across files, a CI log, research, a plan to draft. `scripts/thread.sh <folder> start --title <t> --brief <ask> [--repo <repo>]... [--model m] [--effort e]` makes the thread an ad-hoc chat as tk-hub's daemon knows them (`<base>/.chats/<id>/` beside `<base>/.coordinators/`, a `.grill` naming the `project`, the runner session `chat-<id>`), so the hub lists it under the project and the developer can open and talk to it. It starts in the first repo's main checkout with the others added, on `bypassPermissions` with git's writing commands denied, and its brief (`templates/coordinator-thread-prompt.md` plus the ask) says: read and run, never change a repo or anything live without his word, write `report.md` (first line the answer, then evidence and next step) and run `thread.sh <folder> report <id>`, which drops a `thread` event in the coordinator's inbox. The coordinator relays the first line and what needs him; a fix the thread proposes becomes a ticket, built by a ticket thread on the ticket's suggested model and effort as before. `list`, `say`, `log` and `stop` do the rest.

Model and effort: `--model`/`--effort` when the developer asks for another, else the folder's `thread.env`, which `coordinator.sh` rewrites on every start and resume from `TICKET_THREAD_*` (tk-hub's Project settings send them per project), else `config/models.env` (`opus` @ `medium`). The coordinator's own model is `TICKET_PCOORD_*` the same way (`sonnet` @ `medium`), but only a fresh start changes it: a resume keeps the session's command.

## Staying alive

The conversation is disposable. Typing `handoff` (or asking it to restart itself) makes
it rewrite `state.md` and stop; the next `tkc <project>` is a fresh conversation that
reads the files. `--resume` continues the folder's last conversation instead, for one a
restart cut short. A handoff by the session that knows beats an automatic compaction,
so no `--autocompact` is passed unless `TICKET_PCOORD_AUTOCOMPACT` names a window.

## The inbox, and tk-hub starting it

tk-hub's daemon writes one small JSON file per event into `inbox/`: an agent's new
question, a go/no-go of synthesis, a ticket whose next step became the developer's
(review, merge, deploy, test), an agent that died or stopped halfway, and what only the
hub knows (a ready batch, a red deploy, a proposal). An event names what happened and
where (`at`, `kind`, `board`, `nn`, `repo`, `text`), never what to do, and its text is
data like any report. Nothing is typed into the session to say so: a line typed into
its terminal joined whatever the developer was writing at its prompt. Instead
`scripts/coordinator-inbox.sh` tells it, in two ways that share one ledger
(`inbox/.announced`, so an event is announced once):

- `coordinator-inbox.sh wait <dir>`, which the brief has the session keep running as a
  background command. It ends when an event it was not told of arrives, printing the
  names, and Claude Code starts a turn when a background command ends. The session
  handles them and starts it again. While it waits, `inbox/.watcher` holds its pid.
- `coordinator-inbox.sh hook <dir>`, a `UserPromptSubmit` hook in the folder's
  `.settings.json` (`--settings`): each message the developer sends carries the events
  still untold as context.

Only when no watcher is alive does the daemon fall back to typing one line ("3 new
events in the inbox: <path>"), and only into a session quiet for a while; its daily
`handoff` ask goes into the inbox as a `handoff` event while a watcher runs. Either way
the news is a pointer to the files, never an approval. The session reads them, runs the digests (an
event may be stale; the digest wins), handles each one under the rules above, journals
it and moves the file to `inbox/done/`. A folder started by hand gets the same inbox
when the box runs the daemon. On short-loop boards the watcher itself writes the events (`loop.sh watch`), and the session can run under
the box runner instead of a terminal (`coordinator.sh --runner`): docs/agents/short-loop.md.

`coordinator.sh --json <project> [<repo>...]` starts nothing: it makes the folder and
the brief and prints `{"project", "dir", "prompt", "args"}`, the folder, the first
prompt and claude's arguments. tk-hub's daemon starts the session from that as a Herdr
agent (`start_grill` mode `coordinator`, a workspace labelled `pc <project>`), so the
hub and `tkc` start the same session from the same script. The hub names a project
`p<id>`.

## Not yet

The hub starting one on an event and the automatic recycle are later phases of the
hub's coordinator plan. The hub already shows the session on the project's page and
types the developer's replies into it.
