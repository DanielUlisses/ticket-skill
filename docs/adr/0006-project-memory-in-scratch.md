# 0006 — Project memory lives in `.scratch/project-memory.md`, never in tracked code

Date: 2026-10-23. Amends the project-memory location in ADRs 0002 and 0004
(`docs/agents/project-memory.md`), which stay as written.

**Decision.** Memory is one file per repo, `<main checkout>/.scratch/project-memory.md`,
gitignored and never committed. The developer decided that memory must never be written
inside committed code.

**What changes.** Launchers read the new path from the main checkout (`TICKET_MEMORY_FILE`
still overrides). For one release, if the new file is absent and the old
`docs/agents/project-memory.md` exists, the launcher reads the old one and logs a line
saying to move it; it never creates or moves files. A repo that doesn't ignore `.scratch/`
gets a logged warning, nothing more. `tk.sh retro`, `retro-apply` (M todos read
`add to .scratch/project-memory.md: …`), `ticket-retro` and the help text name the new path.
Nothing writes the file. Board discovery ignores it: `tk.sh boards` lists directories only,
and `load_file_board` and `tk.sh export` skip `project-memory.md`.

**What is lost.** The old file was tracked, so a lesson reached future tickets only after a
reviewed merge. That gate is gone. The developer gate is now the approval in
`tk.sh retro-apply` (or the hub's memory ticket) plus the developer's own edit. Memory is
also per clone and per box: it no longer travels with the repo.

**What is kept.** It is still read from the main checkout, never a worktree, and
`/sweep-tickets` never touches the main checkout's `.scratch`, so it survives sweeps.
