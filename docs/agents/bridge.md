# Offline boards and the bridge repo

For a box tk-hub can never reach: a client's machine on its own network, where the real
files and environments are, that can only call out. It runs its boards on the short loop
like any box, with its own project coordinator and no hub connection, and pushes the
boards' ticket files to a small private **bridge repo**. A box the hub does reach pulls
that repo and shows the tickets as their files read. Why: [ADR 0013](../adr/0013-offline-boards-over-a-bridge-repo.md).

```
the running box (say gusto-mac)             the bridge repo             a reading box (say dev-pythian)
<repo>/.scratch/<board>/   --publish-->   .scratch/<board>/   --pull, every minute-->   ~/work/<repo>/.scratch/<board>/
coordinator + short loop                  ticket files only                             tk-slim, a read-only coordinator
```

Nothing travels the other way. The hub monitors; it starts, answers and merges nothing there.

## The marker

A board is offline when its folder holds a file `offline` naming the box that runs it:

```
echo gusto-mac > .scratch/<board>/offline
```

The name is what `hostname -s` prints on that box, or what `TICKET_BOX` is set to there.
The file is published with the board, so every clone carries it.

- **On the box it names**, the board is an ordinary short-loop board (`loop` = `short`):
  `loop.sh` runs it, and each pass of the coordinator's inbox watcher ends with
  `loop.sh publish <board>`.
- **On any other box**, `loop.sh status` and `loop.sh watch` read the ticket files as
  they stand and every other verb refuses, `adopt` included; `coordinator.sh` lists the
  board as offline and adds `templates/offline-section.md` to the brief. tk-hub's slim
  daemon reports it the same way (ticket-board `docs/hub-next.md`, Offline boards).

## What a reading box believes

Only the ticket file, first match wins:

| The file says | `loop.sh status` there | Hub column |
|---|---|---|
| `**Status:** dropped` | `dropped` | done |
| `**Status:** resolved …` | `done` | done |
| an open `**Blocked by:**` ticket | `blocked` | blocked |
| `**Status:** in-progress` | `working` | working |
| `**Owner:** me` | `yours` | backlog |
| none of these | `ready`: what the running box starts next | backlog |

No session, branch, worktree, PR, report or question is looked at, and none is published.
The running box's loop already keeps those lines true: `loop.sh start` writes
`**Status:** in-progress`, and a ticket that landed gets `**Status:** resolved` on the
next `status` or `watch`. Nobody writes a status by hand.

## Publishing

`loop.sh publish <board>`, on the running box only:

1. copies `issues/*.md`, `batches/*.md`, `board.md`, `loop` and `offline` into
   `<bridge clone>/.scratch/<board>/`, with a `.source` file naming the working repo;
2. commits that folder (`<board>: ticket files`) when it changed;
3. `git pull --rebase`, then pushes when there is something to push.

The bridge clone is named once per working repo, in `<repo>/.scratch/bridge` (one line,
a path; `.scratch` is git-ignored in the working repo, so it never leaves) or by
`TICKET_BRIDGE_DIR`. One bridge repo per working repo: a board another repo published is
refused. On the reading box the clone goes in `~/work` under the working repo's name, so
cross-repo blockers (`<repo>:<NN>`) resolve as they do everywhere.

Output: `PUBLISHED`, `UNCHANGED`, or an error. A pull or push that fails keeps the commit
and the next pass retries. A commit the bridge repo's pre-commit hook refuses is
`REFUSED`: nothing is committed or pushed, the clone is put back as the remote has it,
and the coordinator rewrites the ticket text. The copy is the only thing that leaves the
box, so that hook sees everything that does.

## What may be in a ticket of an offline board

The bridge repo is outside the client's environment. Ticket text holds what to do, the
criteria, counts, ticket and PR numbers and where evidence lives on the running box;
never the client's real names (groups, users, projects, tenants, hosts), ids, emails,
code, plan or command output, or a secret. Things are named by role. The running
coordinator's brief says so (`templates/bridge-section.md`), and the bridge repo's hook
refuses what it recognises: emails, key and token shapes, and a deny list kept on the
running box only.

## The two coordinators

- **Running box:** `coordinator.sh --runner <project> <repo>`, as on any box. Its brief
  gains `templates/bridge-section.md` (publishing is a script, a refusal means rewrite,
  nothing comes in through the bridge). The bridge repo's own `COORDINATOR.md` holds what
  is particular to the project.
- **Reading box:** a coordinator whose repo is the bridge clone. It tells Daniel what is
  done, in progress, next and blocked, and answers questions about the tickets from their
  files. Its watcher turns a pull that changed a state into `landed` and `start` events,
  which are news to pass on. It starts nothing and never commits in the clone.

## Setting one up

Running box, once: clone the bridge repo, point its `core.hooksPath` at its hooks,
`echo <clone path> > <repo>/.scratch/bridge`, and for each board
`echo <box name> > <repo>/.scratch/<board>/offline`.
Reading box: devboxes clones the bridge repo into `~/work` and pulls it every minute (a
client's `bridges`).

### macOS

The short loop and the box runner are written for Linux and GNU tools. On a Mac they need,
from Homebrew and ahead of the system's on `PATH`: `bash` (4 or newer), `coreutils` and
`findutils` (their `gnubin` folders: `timeout`, `stat -c`, `date -d`, `readlink -f`,
`find -printf`), `gnu-sed`, `grep`, `gawk`, `flock`, `jq`, `tmux` and `git`. This has been
read from the scripts, not run on a Mac: the first session there is the test, and what it
finds is fixed here.
