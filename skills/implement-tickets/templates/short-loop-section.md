## Short-loop boards: {{SHORT_BOARDS}}

These boards run on the short loop. On them, everything above about `tk.sh` launch, resume, say, answer, pr, push, merge, gates, the merge queue and `ticket-merger` does not apply: `tk.sh` refuses those verbs there. Your tool for them is `{{LOOP}}`, always as `{{LOOP}} -C <repo> <verb> …` with the repo's main checkout (that one shape runs without a prompt; a `cd <repo> && …` does not). `tk.sh digest` still reads them, but `loop.sh status` is the truth.

There is no board session, no phase file and no stored state. `loop.sh status <board>` derives each ticket's state every time from facts: the ticket file (resolved, dropped, `**Owner:** me`, `Blocked by`), git (branch, worktree, landed), the forge (the PR and its review) and the box runner (is the session alive, is it working).

| State | Means | You |
|---|---|---|
| `ready` | nothing started, every blocker done | start it, inside `max_parallel` |
| `blocked` | a `Blocked by` ticket isn't done (a gate ticket 01 included) | nothing; it frees itself when the blocker lands |
| `yours` | `**Owner:** me`: his ticket, a gate | tell him it waits on him; `loop.sh done <board> <NN> "<what>"` only when he says it is done |
| `working` | its session is working | nothing |
| `asking` | its session wrote a blocking question | answer, bring or hold, as under *Questions*; answer with `loop.sh answer` |
| `idle` | its session is at its prompt with no report | `loop.sh log` to see why (a limit, a dialog); `loop.sh say` or `loop.sh resume` |
| `stopped` | work exists, no live session | `loop.sh resume <board> <NN>` |
| `elsewhere` | the old loop works it: in another checkout (its `**Worktree:**` exists there, or its branch is nowhere here), or its Herdr agent still runs | nothing; never start it. Tell him. Once the old agent is closed, `loop.sh take <board> <NN>` brings it here; from another checkout, once that worktree is gone and the branch is pushed |
| `built` | its report is written beside real work | read the report, open the draft PR (below) |
| `review` | a PR is open (draft or not), no decision | nothing; it waits on him |
| `changes` | he requested changes | relay them: `loop.sh say` (or `resume --note`), then `loop.sh pr` again once it reports |
| `approved` | he approved the PR | tell him; merge only on his word (`merge=once-approved`: merge it now) |
| `done` / `dropped` | landed (git, or a merged PR), or the ticket says so. On landing, status writes the ticket's `**Status:** resolved` line and stops its finished session | nothing |

Every command below runs as `{{LOOP}} -C <repo> …`; the table leaves that part out.

| Command | Does |
|---|---|
| `loop.sh status <board> [NN] [--json]` | every ticket's state and why; `NEXT` lists the ready ones |
| `loop.sh start <board> <NN> [--type fix] [--model m] [--effort e]` | worktree and branch from the base, the thread brief, a detached session through the box runner. Model and effort default to the ticket's Suggested lines. Refuses anything not `ready` or `stopped` |
| `loop.sh resume <board> <NN> [--note <file>]` | the runner resumes its session; with none, a fresh start in the worktree as it stands |
| `loop.sh say <board> <NN> <file>` · `loop.sh log <board> <NN> [lines]` | talk to its session · read its screen |
| `loop.sh report <board> <NN>` | its report |
| `loop.sh answer <board> <NN> <file>` | as `tk.sh answer`: questions file, `## Answers`, the ledger, then the session |
| `loop.sh pr <board> <NN> --title <t> --body-file <f> [--message-file <f>] [--paths-file <f>] [--his-word "<his words>"]` | commit the worktree, push, open a **draft** PR with him as reviewer (`pr=ask-first`: only with his words); on an open PR, push the new commits |
| `loop.sh merge <board> <NN> [--his-word "<his words>"]` | on his word, or his forge approval on a `merge=once-approved` board: approved, checks green, no conflict; a draft is marked ready, then merged |
| `loop.sh done <board> <NN> "<what>"` | his own ticket (a gate), when he says it is done |

**Starting.** Start `ready` tickets yourself, in number order, while fewer than the policy's `max_parallel` are `working` (`loop.sh status --json` gives both). Never start a `blocked` or `yours` ticket, and never work around a refusal.

**Each board's rules.** `loop.sh status` prints them on its `RULES` line (`--json`: `policy`); he sets them per project in the hub's Project settings, which writes them to the board's policy file. Read them again before every PR and merge:

| Rule | Means |
|---|---|
| `max_parallel=N` | start ready tickets while fewer than N are `working` |
| `pr=draft-when-built` | open the draft PR as soon as a ticket is `built` (below) |
| `pr=ask-first` | when a ticket is `built`, tell him it is built and what it did, and open the PR only once he says so: `loop.sh pr … --his-word "<his words>"` (the script refuses without them) |
| `merge=his-word` | merge only when he says so in this chat |
| `merge=once-approved` | his approval on the forge is the go: on `approved`, merge with `loop.sh merge` (no `--his-word`) when checks are green and nothing conflicts, then tell him. A refusal goes to him as printed |
| `skills=…` | catalog skills `loop.sh start` links into each new thread's worktree; nothing for you to do |

**The draft PR is yours.** The ticket's session never commits, pushes or opens a PR. When a ticket is `built` (and, on an `ask-first` board, once he said so):

1. `loop.sh report`, and read it. If the reviewer left a blocking finding, or the criteria aren't met, send it back with `loop.sh say` instead.
2. Write the commit message and the PR body to files: what changed and why, how it was verified, the report's `## Test plan`. The title and body name the Jira id where there is one, never an internal ticket number ("ticket 05"), never a model, an AI tool, a `Co-authored-by` or any attribution line. `loop.sh pr` refuses those.
3. Pass `--paths-file` with only the files the change is made of when the worktree holds anything else (a test's leftovers).
4. Tell him the link in one line. The PR waits for his review: an approval on the forge, or his word here.

**Merging.** Only when he says so in this chat, or on an `approved` PR of a `merge=once-approved` board. `loop.sh merge` refuses without a forge approval; when he opened the PR himself the forge can't take his approval, and then his words here are the approval: pass them with `--his-word`. A refusal (red checks, a conflict, changes requested) goes to him as printed, with what you would do about it.

**Watching.** Nobody else watches these boards for you: while your inbox watcher waits, it runs `loop.sh watch` on each of them every two minutes, and a ticket that moved becomes an event in your inbox like any other (`board`, `nn`, `repo`, `state`, `from`, `text`, `pr`):

| Event | Means | You |
|---|---|---|
| `start` | a blocker landed (or a new ticket appeared) and it is `ready` | start it if fewer than `max_parallel` are `working` |
| `built` | its report is written beside real work | as under *The draft PR is yours* |
| `question` | its session wrote a blocking question | as under *Questions*; answer with `loop.sh answer` |
| `idle` | at its prompt with no report, two checks in a row | `loop.sh log`; then `say` or `resume` |
| `resume` | its session is gone, two checks in a row | `loop.sh resume` it, and tell him only if it dies again |
| `changes` | he requested changes on the PR | relay them to its session |
| `fixed` | a new report while its PR is open (a fix round finished) | read it; `loop.sh pr` pushes the fix |
| `approved` | he approved the PR | `merge=his-word`: tell him; merge only on his word. `merge=once-approved`: `loop.sh merge`, then tell him |
| `landed` | merged, or resolved | nothing; a slot is free |
| `message` | a thread wrote to another (or to you): `text` says who, to whom, whether it was delivered | read it. Step in when it changes a ticket's scope (that is his call), makes one ticket wait on another, or was not delivered (`loop.sh say` it when the target runs, or answer it yourself). A thread may never touch another's worktree |

After any batch of events, run `loop.sh status` on that board and start what is `ready` within `max_parallel`: a freed slot sends no event of its own. On *Every start*, run `loop.sh status` on each short-loop board in place of the digest.

**Threads talk through you.** Each thread's brief lists the board's other open tickets, and a thread may write to another only when their work depends on each other. You deliver nothing by hand: the watcher passes each message on and shows it to you as a `message` event. It reaches the target's session through `tk-relay`, under `[relay from <sender's session>]`, so the hub shows it on both threads. `loop.sh say` and `answer` relay the same way, from you.

**Your chat is his window.** He reads this conversation in the hub, often on his phone: say outcomes and what needs him, in a few lines, never a replay of commands. A file he should look at (a plan, a mock, a diff, a report) goes in `{{DIR}}/artifacts/`, with `<name>.note` beside it holding one line on what it is; when it is about one ticket, start that line with its number (`07: the draft PR's diff`), so the hub shows it in that ticket's thread. Images he sends in the chat arrive as paths under `.hub-images/` at the end of his message: open each with the Read tool (the hub already lists them as artifacts). A thread's agent leaves its own files in its worktree's `.hub-artifacts/`, and the box files them here for you as `<NN>-<name>`.

**Nothing recycles you.** When the box runner runs you (session `pc-…`, no terminal of his), there is no daily handoff and nobody types `tkc`: you run until he stops you, and a crash or a reboot resumes this conversation with a note to start the watcher again. Keep `state.md` current at each real change (a decision, a queue, what you hold for him). When your context grows long, rewrite `state.md` as under *Handoff* and carry on (Claude Code compacts the conversation on its own); a fresh session only when he asks for one, by stopping and starting you from the hub.

**Adopting.** Never run `loop.sh adopt` yourself: a board moves to the short loop only on his word, and then only once the old loop's agents on it are gone (`adopt` refuses otherwise and names them).
