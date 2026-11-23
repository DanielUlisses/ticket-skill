## Short-loop boards: {{SHORT_BOARDS}}

These boards run on the short loop. On them, everything above about `tk.sh` launch, resume, say, answer, pr, push, merge, gates, the merge queue and `ticket-merger` does not apply: `tk.sh` refuses those verbs there. Your tool for them is `{{LOOP}}`, run from the repo it is about (`cd <repo> && loop.sh …`). `tk.sh digest` still reads them, but `loop.sh status` is the truth.

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
| `elsewhere` | the old loop started it in another checkout and works it there (its `**Worktree:**` exists there, or its branch is nowhere here) | nothing; never start it. Tell him; it comes here once that worktree is gone and the branch is pushed |
| `built` | its report is written beside real work | read the report, open the draft PR (below) |
| `review` | a PR is open (draft or not), no decision | nothing; it waits on him |
| `changes` | he requested changes | relay them: `loop.sh say` (or `resume --note`), then `loop.sh pr` again once it reports |
| `approved` | he approved the PR | tell him; merge only on his word |
| `done` / `dropped` | landed (git, or a merged PR), or the ticket says so. On landing, status writes the ticket's `**Status:** resolved` line and stops its finished session | nothing |

| Command | Does |
|---|---|
| `loop.sh status <board> [NN] [--json]` | every ticket's state and why; `NEXT` lists the ready ones |
| `loop.sh start <board> <NN> [--type fix] [--model m] [--effort e]` | worktree and branch from the base, the thread brief, a detached session through the box runner. Model and effort default to the ticket's Suggested lines. Refuses anything not `ready` or `stopped` |
| `loop.sh resume <board> <NN> [--note <file>]` | the runner resumes its session; with none, a fresh start in the worktree as it stands |
| `loop.sh say <board> <NN> <file>` · `loop.sh log <board> <NN> [lines]` | talk to its session · read its screen |
| `loop.sh report <board> <NN>` | its report |
| `loop.sh answer <board> <NN> <file>` | as `tk.sh answer`: questions file, `## Answers`, the ledger, then the session |
| `loop.sh pr <board> <NN> --title <t> --body-file <f> [--message-file <f>] [--paths-file <f>]` | commit the worktree, push, open a **draft** PR with him as reviewer; on an open PR, push the new commits |
| `loop.sh merge <board> <NN> [--his-word "<his words>"]` | only on his word: approved, checks green, no conflict; a draft is marked ready, then merged |
| `loop.sh done <board> <NN> "<what>"` | his own ticket (a gate), when he says it is done |

**Starting.** Start `ready` tickets yourself, in number order, while fewer than the policy's `max_parallel` are `working` (`loop.sh status --json` gives both). Never start a `blocked` or `yours` ticket, and never work around a refusal.

**The draft PR is yours.** The ticket's session never commits, pushes or opens a PR. When a ticket is `built`:

1. `loop.sh report`, and read it. If the reviewer left a blocking finding, or the criteria aren't met, send it back with `loop.sh say` instead.
2. Write the commit message and the PR body to files: what changed and why, how it was verified, the report's `## Test plan`. The title and body name the Jira id where there is one, never an internal ticket number ("ticket 05"), never a model, an AI tool, a `Co-authored-by` or any attribution line. `loop.sh pr` refuses those.
3. Pass `--paths-file` with only the files the change is made of when the worktree holds anything else (a test's leftovers).
4. Tell him the link in one line. The PR waits for his review: an approval on the forge, or his word here.

**Merging.** Only when he says so in this chat. `loop.sh merge` refuses without a forge approval; when he opened the PR himself the forge can't take his approval, and then his words here are the approval: pass them with `--his-word`. A refusal (red checks, a conflict, changes requested) goes to him as printed, with what you would do about it.
