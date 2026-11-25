# 0013 — Offline boards over a bridge repo

Date: 2026-11-25. Status: accepted.

## Context

One client's work has to run on the client's own machine: the real files and cloud
environments are reachable only from there, the machine is on a locked network that only
calls out, and client data must not leave it. tk-hub is on the tailnet and takes no call
from outside it, so the box's daemon can neither connect nor be reached, and its RPCs
(transcripts, diffs, files) would carry client content anyway. Until now the project was
built on our side and synced over a GitHub repo, with a Claude Code session started by
hand on the machine and no view of it in the hub.

## Decision

The machine is a devbox with no hub connection. It runs the short loop and its own project
coordinator, and publishes each board's ticket files, and nothing else, to a private
bridge repo (`loop.sh publish`, on every watcher pass). A board says it is run this way
with an `offline` file naming its box. Every other box that holds the board (a clone of
the bridge repo, pulled on a timer) only reads it: states come from the ticket files
alone, `loop.sh` and tk-hub's daemon refuse to act on it, and a coordinator there answers
what is done, next and blocked.

## Considered

- A daemon dialing out through a tunnel: needs network software on a client machine or a
  public door into the hub, and the daemon's RPCs carry client content.
- A two-way bridge (messages, answers and launches as files, an adapter presenting the
  repo to the hub as a full box): about twice the work, and a path by which whoever can
  push to the repo steers a session that holds the client's cloud rights. Not needed: the
  developer drives the machine's coordinator in person.
- Status the running coordinator writes by hand, or a published `status.json` of derived
  states: the loop already writes `in-progress` and `resolved` on the ticket, and done,
  blocked, in progress and next are all the hub needs.

## Consequences

- The hub shows less for these boards: no question, PR, review, report or session, and a
  state as old as the last push. Launch, resume, say and answer are refused.
- A stored line (`**Status:**`) is believed where the short loop otherwise derives. It is
  the running box's derived state, written by its scripts.
- What may be in a ticket's text becomes a rule (no client names, ids or output), held by
  the brief and by the bridge repo's pre-commit hook.
- The loop has to run on that machine's OS. The first one is a Mac
  (`docs/agents/bridge.md`, macOS).
