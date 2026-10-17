---
name: implement-tickets
description: Runs a board of already-written tickets — files under `.scratch/<board>/` — in a dedicated Haiku board session started by scripts/board.sh, never inside a planning session. The board session launches waves, merges PRs on the developer's word behind scripted gates (sending a Sonnet merger on a conflict), relays messages to ticket agents, resolves what landed and launches what each merge unblocks. For a rough idea that still needs grilling and splitting, use /ticket; for a single ad-hoc ticket, use /small-ticket.
argument-hint: "[a Jira id like ITM-9909, a feature slug under .scratch/, or a path]"
disable-model-invocation: true
allowed-tools: Bash(~/.claude/skills/implement-tickets/scripts/board.sh *)
---

# /implement-tickets

Board received (may be empty):

<board>
$ARGUMENTS
</board>

**The board doesn't run in this session.** It runs in its own Claude Code session on Haiku, with a small prompt, the few tools it uses and no MCP servers — Haiku reprices above 100K prompt tokens, and a planning session carries far more than that. Every check (frontier, has-it-landed, the five merge gates, run-state writes) is a script, so the model there only reads results and decides. See `docs/adr/0004-haiku-board-session.md`.

Check the board resolves, without starting anything:

```bash
~/.claude/skills/implement-tickets/scripts/board.sh --print <board>
```

If that fails, show its error — it names the choices when the board is ambiguous — and stop. If it works, tell the developer to open a **new Herdr tab** at the repo and run:

```
~/.claude/skills/implement-tickets/scripts/board.sh <board>
```

Then stop. Don't launch, merge or digest from here.

## What the board session does

- **Launches** frontier tickets in waves — the account, the implementer's model and effort asked once a session, `As each ticket suggests` when the tickets disagree, `fable` offered for `xhigh`/`max` tickets; research a wave shares asked once and folded into every brief.
- **Opens PRs on request** ("open a PR for 03"): `ticket-pr-creator` (Sonnet) commits exactly the ticket's files through `pr-open.sh`, pushes the branch and opens the PR, its body shaped by the mattpocock `pr` skill.
- **Merges on request** ("merge 03", "merge everything ready") behind five scripted gates — open PR, ready, mergeable, checks green, review approved. A conflict sends `ticket-merger` (Sonnet), which resolves it in the ticket's worktree and commits and pushes that one merge only after the developer approves.
- **Relays** the developer's words to a ticket's agent verbatim, never into a dialog.
- **Resolves** what landed (ancestry or a merged PR, behind the empty-branch guard) and launches what it unblocks. A ticket that delivers nothing committable (gitignored files, say) is resolved on the developer's word with `tk.sh resolve <board> <NN> --no-code "<reason>"` — refused if its branch has commits ahead of the base or its worktree has uncommitted tracked changes.
- **Closes the board with a retro**, before `/sweep-tickets`: `ticket-retro` (Sonnet) runs mattpocock's `retro` over the tickets' reports and transcript extracts and proposes id'd project-memory and environment changes, saved by `tk.sh retro-save` to `<board>/retro/proposals.md`. The developer marks them by id — approve, reject, defer — and `tk.sh retro-apply` writes the marks and regenerates `<board>/retro-results.md`, the approved checklist later tickets are pointed at (`docs/agents/retro.md`). The developer applies what they want.

Its prompt is `templates/board-prompt.md`; its hands are `scripts/tk.sh`, and its two agents that write to git go through `scripts/merge-conflict.sh` and `scripts/pr-open.sh`.
