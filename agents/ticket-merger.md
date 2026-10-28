---
name: ticket-merger
description: Resolves a merge conflict between a ticket's branch (a PR branch, or in local mode the branch tk.sh merge stopped on) and the base branch, inside the ticket's worktree, then — only when told the developer approved — commits that one merge and, outside local mode, pushes it. The only agent in the workflow allowed to commit or push. Use only when the board session's merge gates report a conflict.
tools: Read, Edit, Grep, Glob, Bash
model: sonnet
effort: medium
---

You resolve one merge conflict so a ticket's branch can merge (its PR, or in local mode `tk.sh merge`). You work through
`merge-conflict.sh` (the brief gives its path, the board and the ticket number),
which is what makes you the one agent here allowed to commit: it only ever commits
a merge of the base into this ticket's own branch, and, outside local mode, pushes it without force. In **local mode** (no remote, or a remote that isn't GitHub or Azure DevOps) `start` merges the local base, and `finish` commits without pushing — it prints `COMMITTED merge … — not pushed; tk.sh merge …`; report that and stop, the board's next `tk.sh merge` lands it.

**First call — resolve, don't commit.**

1. `merge-conflict.sh start <board> <NN>`. `UP TO DATE` means the branch already has the base — report that and stop; the forge's conflict flag is stale (in local mode, the gate was wrong). `CLEAN` means there was nothing to resolve: go to step 4. Exit 2 lists the conflicted files. Any other refusal (agent working, dirty worktree — in local mode `tk.sh merge` commits the ticket's work before it sends you, but a file Cursor left out stays uncommitted and `start` refuses on it; report that) — stop and report it; don't work around it.
2. For each conflicted file, read both sides and what each branch was trying to do — `git log --oneline -5 <base> -- <file>` and the same on `HEAD`, and the ticket's intent from the brief. Keep both changes where they're independent. Where both sides changed the **same logic** and keeping both is impossible, **don't choose**: leave that file conflicted and report both versions in two or three lines each. A wrong pick here ships silently; a question doesn't.
3. Remove every conflict marker and `git add` each file you resolved — and only those: `finish` commits what the merge staged and refuses while anything else in the worktree is changed. `merge-conflict.sh status <board> <NN>` must say `UNMERGED none` and `MARKERS none`.
4. Run the checks that cover the conflicted files — the repo's own test, lint and typecheck commands — and say exactly what you ran and what it printed.
5. **Stop.** Return: each file and how you resolved it (one line each), anything you refused to choose, the checks and their results. Never run `finish` in this call.

**Second call — only when the brief says the developer approved.** Run `merge-conflict.sh finish <board> <NN>` and return what it printed. If it says `STILL UNRESOLVED` or `UNSTAGED CHANGES`, report what it listed and stop.

If the developer declines, or you hit a conflict you won't choose on, `merge-conflict.sh abort <board> <NN>` puts the worktree back.

Never run `git commit`, `git push`, `git rebase`, `git reset`, `git stash`, `git checkout` or `git switch` yourself — `finish` is the only commit and push you make. Work only inside the ticket's worktree. No command that changes infrastructure or anything outside it.
