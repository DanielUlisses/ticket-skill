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
   (one `agent` tab, agent | shell side by side, as a launch makes), and starts the session on the same roster, model and effort.
   - With a transcript (the newest one `tk.sh export` reports for the worktree), the session
     starts as `claude --resume <session>` and gets only the note.
   - With none, with `--fresh`, when the transcript isn't under the config root the worktree
     resolves to, or when its last line was cut off by the kill, the session gets the full
     brief with the note on top.
5. Resets the ticket's phase file before it starts anything (`reset_phase`, as a launch does):
   line 1 becomes `resuming` (`launching` for a launch), line 2, the merge gates'
   `tests=… criteria=… review=…`, is kept, and `<phase file>.started` marks when this agent
   started. See *Finished or orphaned* below.
6. Records the new agent on the ticket (`**Agent:**`), so the board shows it working again.

Nothing is pulled, rebased, reset, stashed or deleted. The account is whatever the worktree's
`claude-acc` link already says; the launcher refuses when that isn't the account the ticket ran
on (`**Account:**`). Catalog skills stay linked from the first launch.

## After a rescope: `--respec`

`tk.sh rescope-apply` changes a ticket's spec and keeps its run state, and tells a live agent.
A ticket whose agent has already ended (it opened its PR and finished) has no one to tell, and
its branch holds work built on the old spec. `tk.sh resume <board> <NN> --respec [--rescope <id>]`
starts the new agent for that case:

- The same checks as above (in progress, its worktree there, not landed, no live agent), in any
  column: a ticket in **pr** resumes too.
- The note says the spec changed (which rescope, which PR) and carries the ticket file as it
  reads now, which wins over the brief the conversation started from. The agent keeps what still
  fits, changes what doesn't, runs the checks, review and report again, and stays on the branch:
  the PR takes the new commits and no second one is opened. An earlier approval doesn't carry over.

tk-hub sends it as `resume_ticket` with `respec` (its project chat's Relaunch card). See
ticket-board `docs/project-chat.md`.

## Finished or orphaned

A gone agent either finished and closed its session, or died with work left. Only the
second is an orphan to resume. The phase file says which, but only when *this* agent wrote
it: before the reset, a `done` an earlier agent left survived a resume and read as finished
while the new agent worked (tk-hub, #04 on dev-bss, 2026-11-06).

The board rows (`tk.sh export`, `tk.sh view`) read a ticket's phase as its current agent's
when the phase file is not older than its `.started` mark, and say so as `phase_fresh`:

- gone, phase `done`, fresh: **human review**, "agent finished (session closed)"; the
  digest says `ACTION review NN`, not orphan;
- gone otherwise (working when it died, a stale `done`, or no mark: an agent launched
  before the reset existed): **needs you**, "no live agent", `ACTION orphan NN`.

Work that is only on the box rides on a gone agent's card: `unpushed` in the export
(`14 uncommitted files`, `2 commits not pushed`; commits are not counted in local mode) and
` · unpushed: …` on the note. `/sweep-tickets` never removes a worktree with uncommitted
changes, `--force` or not, and needs `--force` for a branch that isn't merged.

## A launch that stopped half-way

A launch that fails after the launcher made the worktree (a Herdr call that errors, an agent
that won't start, the box killing the launch) used to leave the ticket `open` with its branch
made, and every relaunch then refused: "branch already exists". Now:

- The launcher prints `WORKTREE_MADE=<path>` as soon as `herdr worktree create` returns.
  When it then fails, `tk.sh launch` records the ticket `in-progress` on that branch with the
  launch's model and effort, and **no `**Agent:**` line** (`RECORDED NN in-progress on <branch>
  with no agent`). It still exits with the launcher's code.
- The board rows read "in progress, no agent recorded" as `gone`: **needs you**, "no live
  agent", next step `hub · resume`. `tk.sh resume` finishes the launch in that worktree; its
  note tells the new agent the launch stopped before any agent started.
- A ticket still `open` from before this, whose branch and worktree (`../<repo>--<branch>`)
  an earlier launch left, is adopted by its next `tk.sh launch` with the same type: recorded
  the same way, then resumed. A branch with that name anywhere else is refused, with how to
  remove it.

## After a rebase: `tk.sh rebase` and `--rebased`

A ticket at the human gate can wait for other work: tk-hub's park "when these merge" holds its
review until the tickets it names land (ticket-board `docs/unplanned.md`, Park). Once they have,
`tk.sh rebase <board> <NN>` brings it onto the base's tip:

- Refused unless the ticket is in progress, its worktree is on its branch, its agent is quiet (not
  working, not at a dialog), nothing is uncommitted, and no rebase or merge is in progress there.
- A branch something outside the box holds (a PR, or pushed) is never rebased: exit 13 `PUSHED`,
  and the base comes in by a merge instead (`merge-conflict.sh start`, ticket-merger).
- Clean (`REBASED`, or `UP TO DATE`): the new `**Base:**` is recorded (`BASE <NN> <sha>`), and the
  agent is asked to run the brief's checks again, review and report with "rebased onto <base>
  <sha>" at the top of its hand-off. A live agent gets the ask as a message; a gone one gets a new
  agent through `tk.sh resume --rebased <sha>`, whose note says the same. The report brings the
  card back to the human gate.
- A conflict: the rebase is aborted (the branch is as it was), exit 10 `CONFLICTS`, and the merge
  flow takes it.

tk-hub sends it as the daemon's `rebase_ticket` (exit 10 or 13 starts ticket-merger with the
ticket kept at the human gate; Commit merge leaves it there for review).

## Who calls it

- The developer, or the board session on the developer's word (`resume 07`).
- tk-hub, through the daemon's `resume_ticket` RPC: once per ticket per day on boards that
  launch on their own, a Resume button everywhere else. See ticket-board `docs/runs.md`. A box
  whose daemon doesn't run `resume_ticket` gets no Resume there, but "its daemon is out of
  date: run `install.sh daemon` there".

A ticket that is the developer's (`**Owner:** me`) resumes only with `--helper`, which only
their own click passes.

## Why a resume and not a fresh launch

Agents can't commit (`git add`/`commit` are disallowed tools), so a ticket's work in progress
lives only in its worktree's files. A fresh launch would need a new branch and worktree, and the
old one's work would sit beside it unused. The worktree survives an OOM: the kernel kills
processes, not files, and a git command killed halfway leaves at most the lock above.
