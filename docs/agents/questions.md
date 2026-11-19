# Questions: what an agent asks the developer

An agent that needs something only the developer has (a value for a placeholder,
which of two repos the ticket means, a scope call) asks instead of guessing. It
writes `{{QUESTIONS_FILE}}`, which the launcher points at
`$XDG_STATE_HOME/ticket-skill/<repo>/questions/<branch>.json`:

```json
[{"id": "q1", "q": "Which apps in stg are missing secrets?", "blocks": true},
 {"id": "q2", "q": "I'll use stg-apps. Right?", "blocks": false}]
```

- `blocks: true`: the agent stops (phase `asking`) with `Waiting on the developer: q1`.
  Once it is idle with an unanswered blocking question, the card moves to
  **needs you** with the note `asks: <question>` and the hint `answer <NN> q1 <answer>`.
- `blocks: false`: the agent goes on with the assumption it stated. A doc ticket
  writes each of its marked assumptions this way and never stops.
- Never a secret's value: the agent asks where it lives.

`tk.sh export` carries each in-progress ticket's `questions` (`{id, q, blocks, a, at}`;
`a` is null until answered). tk-hub reads them for its Questions card.

## Answering

`tk.sh answer <board> <NN> <answer.json>`, the file `{"id": "q1", "a": "..."}` for a
question the agent asked, or `{"q": "...", "a": "..."}` for one asked elsewhere (a
task in tk-hub that blocks this ticket):

1. Appends the question and answer, dated, under the ticket file's `## Answers`
   (made on first use). Every later launch, resume or rescope reads it there.
2. Marks the question answered in the questions file (`a`, `at`).
3. Sends it to a live agent (idle, done or working) as a message. At a dialog it
   exits 20 and with no live agent 21, as `tk.sh say` does; the answer is written
   either way. A ticket that isn't in progress has nothing to send to: its launch
   reads the answer.

## An answer that arrives as a plain message

The developer may answer in a message instead (`tk.sh say`, a card in tk-hub's project
chat, typing in the agent's own session). Nothing but `tk.sh answer` used to mark the
question, so the agent did the work while its card stayed in **needs you** as `asks: …`
(Chelan #07, 2026-11-11). Now:

- the agent marks it: its brief tells it to set the entry's `a` (the developer's words)
  and `at` in its questions file before acting on the message, and `tk.sh say` reminds
  it of the ids still open (a `<system-reminder>` block after the message, which
  tk-hub's transcript reader leaves out of the chat);
- `tk.sh digest` and `tk.sh resume` copy every answered question that isn't under the
  ticket's `## Answers` yet into it (`record_answers`), so a later launch, resume or
  rescope reads it. `tk.sh export` stays a read.

`tk.sh resume` puts the ticket's `## Answers` in its resume note, because a
resumed conversation is sent only the note, not the ticket again.

## The ledger

An answer under one ticket's `## Answers` is read by that ticket only, so the next
ticket's agent asked the same thing again. Every answer is therefore also appended to
the repo's **answers ledger**, `.scratch/answers.md` in the main checkout (beside project
memory: gitignored, never committed), by `tk.sh answer` and by `record_answers`:

```
- **itm-7010#03 q1** (2026-11-18T14:02Z, project) Which subscription is dev?
  Answer: sub-dev-01
```

- **Scope.** `"scope": "project"` in the answer file marks an answer that holds for
  every ticket of the repo (a subscription id, where a secret lives). Anything else is
  `ticket`. An answer copied from a plain message is `ticket`.
- **Briefs carry it.** Every launch folds the entries that bear on the ticket into its
  brief as `## Answers already given` (the `{{ANSWERS_LEDGER}}` placeholder, after
  project memory): every project-scope entry, and the ticket-scope ones of its own
  board, newest first, at most `TICKET_ANSWERS_MAX_BYTES` (4096). Its own entries are
  left out: they are in its `## Answers`. `tk.sh resume` adds the same block to its
  note. The launch summary says `ANSWERS_LEDGER=<n> entries (…)` or `none`.
- **Reading it.** `tk.sh answers <board> [NN]` prints what a ticket of the board is
  told; `--all` prints every entry of the repo.
- **Fixing it.** The file is the developer's: edit or delete an entry by hand. The same
  question of the same ticket is written once. `TICKET_ANSWERS_FILE` names another file.

No ledger, or no entry that bears on a ticket, changes nothing in its brief. tk-hub
matches exact repeats on its side and answers them with the earlier words; a near
repeat is the [project coordinator](project-coordinator.md)'s call.
