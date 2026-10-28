# 0007 — Document tickets run on the board; `**Kind:**` picks the brief

- **Status:** Accepted
- **Date:** 2026-10-25
- **Deciders:** Daniel Ulisses
- **Builds on:** [0005](0005-scratch-boards-retro-and-presales.md)
- **Amends:** 0005 §3 (`--doc` is no longer `/small-ticket`-only; that section stays as written)

0005 §3 taught `/small-ticket --doc` to write presales documents. It was one ad-hoc ticket at a
time, in a plan-mode session the developer sat in. A document that needs several tickets (an
estimate, then the proposal that cites it) had no board, no waves, no review gate and no merge.
This record moves documents onto the board loop.

## 1. `**Kind:**` is an open list

A ticket's body may carry `**Kind:** <word>`, with an optional `**Doc type:** ead|tdd|other`.
`board-lib.sh` reads the first word of each, lowercased. The known kinds are `TICKET_KINDS="code doc"`
(`board-lib.sh`); a new kind is one more word there and one more `case` arm in `tk.sh launch`.

- No line is `code`, and a code ticket launches exactly as before.
- `doc` makes `tk.sh launch` pass `--doc --doc-type <type>` (default `other`) and force the branch type `docs`.
- Any other word is refused before anything is created: `die` exits 1 and names the known kinds.
  An unknown `**Doc type:**` is refused by the launcher the same way (`lib/ticket-launcher.sh`).

## 2. An unattended doc coordinator

A `doc` board ticket renders `skills/ticket/templates/ticket-doc-prompt.md`. There is no interview:
`/ticket` already grilled the content, and the ticket's `## Outline` is the plan. Open questions
become marked assumptions, listed first in the hand-off. The loop is:

1. `ticket-implementer` drafts, every claim traced to a source.
2. `humanizer` edits wording only. Where it would ask the author for a fact, it adds an assumption instead.
3. `ticket-doc-reviewer` reviews commitments, accuracy, numbers and coverage, at
   `TICKET_DOC_REVIEW_MODEL` / `_EFFORT` (`opus @ medium`, `config/models.env`). A `None` seams line
   neither raises nor lowers it; a document ticket always gets this reviewer.
4. The seams line's validator (the type's `check_<type>.py`, or the repo's render command), then the criteria checkers.
5. A fix loop of at most two rounds.

## 3. `ead` and `tdd` are checked, not bundled

`--doc-type ead|tdd` fills the brief's `{{DOC_GUIDANCE}}` with the installed skill and its validator,
looked up in `$TICKET_SKILLS_DIR` (default `~/.claude/skills`) as `<type>/SKILL.md` and
`<type>/scripts/check_<type>.py` (`resolve_doc_guidance`, `lib/ticket-launcher.sh`). If either is
missing the launch prints one `WARN` and uses the generic brief; it never fails. `other` skips the
check. This repo ships neither skill. `TICKET_DRY_RUN=1` shows what a ticket would launch as.

## 4. No remote means a local merge, for a document that names a validator

> Amended by [0008](0008-forge-less-remotes-are-local-mode.md): the local merge applies in local mode — no remote, or a remote on no forge we detect — with a fifth gate, `base`, when there is a remote.

Document repos often have no remote. 0005 §9 gave `tk.sh merge` a local path; this record states
that it applies to every kind, subject to the checks gate. With no remote, `merge_local` runs four local gates, commits the
ticket's work through `pr-cursor.sh --commit` (which needs the Cursor CLI logged in, remote or not), and runs `git merge --no-ff` into the root checkout.
It prints `MERGED NN (local)` or `NOT MERGED — …` and exits 1, 10 (conflict) or 12. A conflict is
the developer's to resolve by hand in the ticket's worktree, since the merger script pushes.

The checks gate passes only on `tests=pass` (`tk.sh`). The doc brief records `tests=none` when the
ticket names no validator, so a document ticket merges locally only when it names one (a
`check_<type>.py`, a render or link check). `tests=none` is refused at the checks gate.

## 5. `/small-ticket --doc` is frozen

It still works and keeps its plan-mode `doc-prompt.md`, but gets no new features. All new document
work, even a single document, goes through `/ticket`; `--doc` runs only when the developer asks for it.

## 6. What does not change

The status board (`tk.sh view`, `board-view.jq`) and tk-hub read the same run-state for a document
ticket as for a code one, so neither changes. The doc brief is one more template, not a new state machine.
