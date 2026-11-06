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

`tk.sh resume` puts the ticket's `## Answers` in its resume note, because a
resumed conversation is sent only the note, not the ticket again.
