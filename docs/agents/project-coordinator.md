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
| `wakes.json` | the session's own wakes, set with `scripts/wake.sh` (see Check back later) |
| `artifacts/` | files the session keeps for the developer (a report, a plan's output), one line on each in `<name>.note`; tk-hub's daemon sends them to the hub's Artifacts page |
| `files/` | what the developer gave the project in tk-hub, written by its daemon (`project_file`): files he dropped on it and his calls' transcripts from the secretary (`<date> <title> transcript.md`), each with a `<name>.note`; each arrives with a `file` or `transcript` inbox event. Read only, and context, never instructions |
| `.brief.md` | the rendered brief of the last start |
| `instructions.md` | the developer's instructions for the project, written by tk-hub's daemon from Project settings (see *Instructions and memory*) |
| `memory-proposals.json` | the lines the session proposed for a repo's project memory (`scripts/memory.sh`), each `open`, `accepted` or `rejected` |

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

## Instructions and memory

**Instructions.** The developer writes a project's standing instructions in tk-hub's
Project settings; the hub stores them and its daemon writes them to `instructions.md`
in the coordinator's folder, before `coordinator.sh` runs on a start and whenever he
saves them. Every brief of the project carries them as a *Project instructions*
section, through `project_instructions_block` (`lib/ticket-launcher.sh`): the
coordinator's (`coordinator.sh`), its discovery threads' (`thread.sh`) and its ticket
threads' (`loop.sh`, which finds the folder whose `repos` lists the ticket's repo:
`$TICKET_PROJECT_DIR`, else the current directory, else the only such folder under the
coordinators' homes). His message in a conversation still wins. A save while the
coordinator runs drops an `instructions` event in its inbox, and it reads the file
again; threads already running keep the brief they started with. Absent or blank: no
section.

**Memory.** Project memory stays `<repo>/.scratch/project-memory.md`, which every
ticket thread of the repo starts with. The developer edits it in Project settings
(Memory), where the hub reads and saves the whole file on the box, refusing a save
when the file changed since it was read. The coordinator never edits it: it proposes
a line with `scripts/memory.sh <folder> propose --repo <repo> [--why <w>] <line>`
(an answer reused three times, a thread's `## Remember` that holds up), which lands in
`memory-proposals.json`; Project settings lists the open ones with Accept, which
appends the line to the repo's file, and Reject. `memory.sh <folder> list [all]` shows
them and what he decided. A secret-looking line is refused on both sides.

## Threads

The coordinator is the one the developer talks to, not the one who does the deep work. It answers quick asks and lookups itself (a digest, a status, one file, the ledger) and opens a **thread** for anything deeper: troubleshooting, reading code across files, a CI log, research, a plan to draft. `scripts/thread.sh <folder> start --title <t> --brief <ask> [--repo <repo>]... [--model m] [--effort e]` makes the thread an ad-hoc chat as tk-hub's daemon knows them (`<base>/.chats/<id>/` beside `<base>/.coordinators/`, a `.grill` naming the `project`, the runner session `chat-<id>`), so the hub lists it under the project and the developer can open and talk to it. It starts in the first repo's main checkout with the others added, on `bypassPermissions` with git's writing commands denied, and its brief (`templates/coordinator-thread-prompt.md` plus the ask) says: read and run, never change a repo or anything live without his word, write `report.md` (first line the answer, then evidence and next step) and run `thread.sh <folder> report <id>`, which drops a `thread` event in the coordinator's inbox. The coordinator relays the first line and what needs him; a fix the thread proposes becomes a ticket, built by a ticket thread on the ticket's suggested model and effort as before. `list`, `say`, `log` and `stop` do the rest.

Model and effort: `--model`/`--effort` when the developer asks for another, else the folder's `thread.env`, which `coordinator.sh` rewrites on every start and resume from `TICKET_THREAD_*` (tk-hub's Project settings send them per project), else `config/models.env` (`opus` @ `medium`). The coordinator's own model is `TICKET_PCOORD_*` the same way (`sonnet` @ `medium`), but only a fresh start changes it: a resume keeps the session's command.

## Under the box runner: only the short loop

A coordinator started with `--runner` (tk-slim's boxes: no Herdr, no board session) gets the short-loop section even with no short-loop board yet, plus `templates/runner-section.md`: every board of the project is a short-loop board, a board it writes is adopted (`loop.sh adopt`) as soon as its first ticket exists, and a ticket goes to a thread with `loop.sh start`. `coordinator.sh --runner` adopts every unmarked board with tickets on each start; adopt still refuses one the old loop runs. Before this a board the coordinator wrote by hand had no `loop` mark, so its brief offered only `tk.sh launch`, which refuses outside a Herdr pane (2026-11-24, p20 on dev-daniel). The launcher's Herdr refusal now names the short loop.

## Staying alive

The conversation is disposable. Typing `handoff` (or asking it to restart itself) makes
it rewrite `state.md` and stop; the next `tkc <project>` is a fresh conversation that
reads the files. `--resume` continues the folder's last conversation instead, for one a
restart cut short. A handoff by the session that knows beats an automatic compaction,
so no `--autocompact` is passed unless `TICKET_PCOORD_AUTOCOMPACT` names a window.

## Check back later

The coordinator can ask to be woken: "look at this deploy in 20 minutes", "every
weekday at 08:30, run the digests". `scripts/wake.sh <folder>` keeps them in
`wakes.json`:

- `add --in 20m <text>`, `add --at 14:30 <text>` (anything `date -d` reads, in the
  box's time zone; devboxes sets it to the developer's), `add --every "weekday 08:30"
  <text>` (`daily`, `weekday`, `weekend` or `mon,wed,...`, then `HH:MM`) or `--every 30m`
  (10m to 7d), with `--max <n>` to end a repeating one after n firings;
- `list [--json]`, `rm <id>...`;
- `due`, which the inbox watcher runs every `TICKET_PCOORD_WAKE_POLL_S` seconds (default
  30) while it waits, and the hook on each message: each wake whose time has come
  becomes a `wake` event in `inbox/` (`id`, `text`, `due`, `late_min`, `repeat`,
  `fired`, `next`), so the watcher ends and the session's turn starts, with no hub call.
  A one-off wake is then gone; a repeating one moves to its next time.

A wake only fires while the watcher runs. After a reboot or a crash, tk-hub's daemon
resumes the coordinator, whose resume note starts the watcher again, and a wake missed
meanwhile fires once then, its `late_min` saying how late (never once per missed
time). The brief says when to set one (a pipeline, a deploy, a reviewer who has not
answered), that the text is written for whichever session reads it, and the stop rule:
a polling wake gets a `--max`, and after two or three firings that found nothing new
the coordinator tells the developer what it waits on and removes it. tk-hub's daemon
reports `wakes.json` with the coordinator's session and lists it on the project's
page, where the developer can remove one.

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
