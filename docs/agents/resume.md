# Resuming a ticket whose agent died

`tk.sh resume <board> <NN>` starts a new agent on a ticket in progress whose agent is gone:
the box ran out of memory, the container restarted, or the pane was killed. The digest shows
such a ticket as `ACTION orphan NN` and the status board puts it in **needs you** ("no live
agent"). Before this verb the only way back was by hand, because `tk.sh launch` refuses a
branch that already exists.

## What it does

1. Refuses unless the ticket is `in-progress`, its worktree is where the launcher put it, it
   hasn't landed, and Herdr answers with no agent of that name (alive or at a dialog).
2. Removes a stale `index.lock` from the worktree's git dir: one with no `git` process running
   in the worktree and more than two minutes old. A kill in the middle of a git call leaves one,
   and every later git call there fails. A live-looking lock refuses the resume instead.
3. Writes a short note: the worktree, its last commit and `git status --short`, and what to do
   (read the worktree as it stands, keep every change, carry on from the interrupted step).
4. Calls the launcher with `--resume`. It makes a new Herdr workspace on the existing worktree
   (agent and shell tabs), and starts the session on the same roster, model and effort.
   - With a transcript (the newest one `tk.sh export` reports for the worktree), the session
     starts as `claude --resume <session>` and gets only the note.
   - With none, with `--fresh`, when the transcript isn't under the config root the worktree
     resolves to, or when its last line was cut off by the kill, the session gets the full
     brief with the note on top.
5. Records the new agent on the ticket (`**Agent:**`), so the board shows it working again.

Nothing is pulled, rebased, reset, stashed or deleted. The account is whatever the worktree's
`claude-acc` link already says; the launcher refuses when that isn't the account the ticket ran
on (`**Account:**`). Catalog skills stay linked from the first launch.

## Who calls it

- The developer, or the board session on the developer's word (`resume 07`).
- tk-hub, through the daemon's `resume_ticket` RPC: once per ticket per day on boards that
  launch on their own, a Resume button everywhere else. See ticket-board `docs/runs.md`.

A ticket that is the developer's (`**Owner:** me`) resumes only with `--helper`, which only
their own click passes.

## Why a resume and not a fresh launch

Agents can't commit (`git add`/`commit` are disallowed tools), so a ticket's work in progress
lives only in its worktree's files. A fresh launch would need a new branch and worktree, and the
old one's work would sit beside it unused. The worktree survives an OOM: the kernel kills
processes, not files, and a git command killed halfway leaves at most the lock above.
