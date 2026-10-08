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
