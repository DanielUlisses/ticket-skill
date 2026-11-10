# Next step per ticket

`tk.sh export` gives every ticket one `next`: who has to act on it and what that
act is. tk-hub builds the developer's day from it (its `day.py`): the list is the
tickets whose step is his, in finish-first order, plus what he typed himself.
Nothing is stored: the step is computed from the row the status board draws, on
every export, so it never goes stale and nothing has to be marked done. When the
ticket moves, its step changes.

```json
"next": {"owner": "daniel", "step": "merge", "since": "2026-11-09T10:12:03Z",
         "reason": "PR #41 ready to merge"}
```

| owner | step | when (the row's `col`, `note`, `pr`, `state`) |
|---|---|---|
| `agent` | `build` | working: the agent scouts or implements |
| `agent` | `review` | agent review: verifying, reviewing, fixing findings, reporting |
| `agent` | `fix` | a PR with changes requested or failed checks |
| `hub` | `launch` | backlog, an agent's ticket: ready to launch |
| `hub` | `resume` | needs you, no live agent: `tk.sh resume` starts a new one |
| `hub` | `resolve` | done but not resolved: it landed, `tk.sh resolve` records it |
| `hub` | `pr` | human, under `night_shift` with `require_human_before_pr: false` and the review passed |
| `hub` | `merge` | a PR ready to merge, with `auto_merge: true` |
| `daniel` | `review` | human (the gate), or a PR awaiting review |
| `daniel` | `merge` | a PR ready to merge, a PR that conflicts with the base (`merge NN` sends the merger: nothing else starts it), or a branch pushed with the forge off |
| `daniel` | `answer` | an agent's blocking question, an agent at a dialog, a landing nobody can tell, a ticket on the wrong repo's board |
| `daniel` | `start` / `work` | an `**Owner:** me` ticket in backlog / working |
| `none` | `blocked` | open, waiting on tickets not resolved |
| `none` | `wait` | a draft PR (one that also conflicts is `merge`: the conflict comes first), or its checks running |
| `none` | `done` | resolved or dropped |

`since` is when the ticket last changed: the newest of its file, its phase file
and its questions file, ISO UTC; null when none can be read. `reason` is one line
in words (the card's note, or the question asked).

## What only tk-hub adds

The skill can't see these, so tk-hub lays them over the export's step:

- **Deploy.** A ticket that landed is the developer's to deploy (in most cases
  the merge into the forked repo and a check on the live cluster), with its
  `## Test plan`; he ticks it on the hub. No agent deploys.
- **Test.** A batch whose tickets all landed is one Test step (docs/agents/batches.md);
  its tickets raise no Deploy of their own.
- **Park.** A ticket the developer parked has no step until it wakes.
- **A refused hub step.** A resolve or merge the hub tried and the box refused
  stays the hub's step, with its reason and a Retry on the ticket. It never
  becomes a task for the developer.

An older ticket-skill's export has no `next`; tk-hub derives the same step from
`col`, `note` and `pr`.
