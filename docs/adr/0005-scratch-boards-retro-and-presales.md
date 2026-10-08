# 0005 — `.scratch` is the only board home; retro closes a board; `/small-ticket` writes documents

- **Status:** Accepted
- **Date:** 2026-10-08
- **Deciders:** Daniel Ulisses
- **Builds on:** [0004](0004-haiku-board-session.md)

## 1. Boards live only under `.scratch/`

Boards could live in two homes: files under `.scratch/<board>/`, or GitHub issues under a
`ticket:<board>` label. In practice the developer uses `.scratch/`, and the GitHub home was a
second parser, run-state written as issue comments, labels, native dependencies, and every board
script in two branches. It is gone:

- `/ticket` always writes `.scratch/<board>/issues/<NN>-<slug>.md`, whatever tracker the repo has.
- `board-lib.sh` resolves a Jira id, a slug or a path to one folder and parses only files;
  `tk.sh`, `pr-open.sh` and `merge-conflict.sh` lost their GitHub-board branches.
- **PRs still live on GitHub.** "Has it landed" still asks `gh` for a merged PR, and the merge
  gates, the merger and the PR creator still work against GitHub PRs — that is about where the
  code goes, not where the board is.
- **A repo with no remote is supported.** The board scripts take the local base as the merge
  target, skip the fetch and the PR leg, and the PR verbs say to merge locally instead.

## 2. Retro closes a board, before the sweep

0004 added `ticket-memory-curator`, which turned the tickets' `## Remember` sections into a
project-memory diff. That is one slice of what mattpocock's `retro` skill (v1.3+) does: it reads a
session's own logs and proposes improvements to the agent's environment — navigation hints,
automated checks, coding standards, steering files, tool economy, no-op instructions, information
access. The curator is replaced by **`ticket-retro`** (Sonnet @ medium), which does both:

- `tk.sh retro <board>` gathers its input deterministically: each ticket's saved report, the Claude
  Code transcripts its worktree left (found under every config root by the worktree's encoded path,
  since an `--account` ticket logs under its own), and a cheap extract of each — how often each tool
  ran, and the most frequent tool errors. A ticket transcript can be megabytes; the agent starts from
  the extract and `grep`s for evidence rather than reading one whole.
- The agent Reads `retro` and `writing-for-agents` from the installed skills (the board session runs
  with skills disabled; `retro` is user-invoked anyway) and returns a project-memory diff first, then
  environment changes by severity. It writes nothing.
- It runs **before `/sweep-tickets`**, as the board's last step: the board prompt offers it when every
  ticket is resolved and only then points at the sweep.
