# Retro: save, mark, apply

A board closes with a retro (ADR 0005), before `/sweep-tickets`. Its proposals are kept in
files, so they outlive the board session, are answered by id, and reach later tickets.

## The flow

1. **Run.** The board session runs `tk.sh retro <board>` and dispatches `ticket-retro` with its
   output. The agent returns id'd proposals under `## Project memory` (`M1`, `M2`…),
   `## Environment` (`E1`, `E2`…) and `## Dropped` (no ids) — the format is in
   `agents/ticket-retro.md`.
2. **Save.** `tk.sh retro-save <board> < output` writes it verbatim to
   `.scratch/<board>/retro/proposals.md`. A previous `proposals.md` is moved to
   `proposals.<timestamp>.md` first, never lost.
3. **Mark.** The developer answers by id — "approve E1 M2, reject E2, defer M1" — and the board
   runs `tk.sh retro-apply <board> approve E1 M2 reject E2 defer M1`. Each named block in
   `proposals.md` gets one `**Mark:** approved|rejected|deferred` line under its heading,
   replacing any earlier mark. Marking by hand in the file works too: `tk.sh retro-apply <board>`
   with no marks only reads the ones already there. Mark words may be given as `approve` or
   `approved` (likewise `reject`, `defer`), in the args or the file; ids are case-insensitive, and
   trailing `,` `.` `;` on an argument are ignored. By hand, edit the block's existing `**Mark:**`
   line rather than adding another: a block with two is refused until one goes.
4. **Results.** Every run regenerates `.scratch/<board>/retro-results.md` from the marks — never
   appended to:
   - **Approved** — a checklist, `- [ ] <id> <title>`, with the change, source and reason under
     each. An approved `M` item reads `add to docs/agents/project-memory.md: <fact>`.
   - **Deferred** — `- <id> — <title>`, so a later retro can pick them up.
   - **Rejected** — `- <id> — <title>`, so the next retro doesn't propose them again.

   Unmarked ids are pending: listed on stdout (`PENDING M3 E4 …`), not written as approved.

`retro-apply` validates every id and mark word — and any mark already in the file — before it
writes anything, and writes each file through a temp file and `mv`. It dies, changing nothing,
on an unknown id, an unknown mark word, a block with more than one `**Mark:**` line, or a board
with no `retro/proposals.md`. Inside a fenced code block (```` ``` ```` or `~~~`) nothing counts as a
heading or a field, so code in a `**Change:**` reaches the results as written.

## What it never does

- **It never writes `docs/agents/project-memory.md`.** Memory stays hand-applied
  (`docs/agents/memory.md`, *Folding a lesson back in*); an approved `M` item is a todo.
- **Agents never tick the boxes.** The file is guidance for tickets and a todo for the developer,
  who turns open items into work. Every run writes the boxes unticked: the file is regenerated,
  not edited.

## Where the file is read

`retro-results.md` sits at the board's root in the **main checkout**, beside the ticket files
(the board's ticket discovery skips it). Launches point every ticket at each
`.scratch/*/retro-results.md` by path, and the `/ticket` planner reads them before grilling — see
`docs/agents/memory.md`, *Retro results*.
