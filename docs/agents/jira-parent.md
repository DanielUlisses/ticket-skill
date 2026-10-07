# Jira parent

How `/ticket` ties a board to a Jira issue. Naming only: nothing here calls Jira, and nothing
links to it.

## The first word decides

```
/ticket itm-9909 add the export button
```

The task's **first word** is a Jira id when it matches `^[A-Za-z][A-Za-z0-9]+-[0-9]+$`. It is
lowercased (`ITM-9909` → `itm-9909`) and stripped from the task before Phase 1's interview, so
the interview sees `add the export button`.

Only the first word counts. `/ticket add the export button for ITM-9909` has no id — the
key-shaped token is just text — and runs exactly as `/ticket` always has.

## What the id changes

| | Without an id | With `itm-9909` |
|---|---|---|
| File home | `.scratch/<feature-slug>/issues/<NN>-<slug>.md` | `.scratch/itm-9909/issues/<NN>-<slug>.md` |
| GitHub home | label `ticket:<feature-slug>` | label `ticket:itm-9909` |
| Ticket body | no parent line | `**Parent:** itm-9909`, just above `**Blocked by:**` |

The parent line is written identically in both homes, on every ticket of the run, always
lowercase. The coordinator's brief template is unchanged: the line rides along in the ticket
body it already receives.

Not changed by the id: branch names, `/small-ticket`, and the coordinator prompt.

## A second run appends

A feature slug is coined fresh each run; a Jira id is not. A second `/ticket itm-9909 …` finds
the board the first one wrote and **adds to it**:

- **File home** — `.scratch/itm-9909/issues/` already holds tickets. Numbering continues from the
  highest `NN` among the file names.
- **GitHub home** — the `ticket:itm-9909` label already exists. Numbering continues from the
  highest `NN:` title prefix among its issues, open and closed.

New tickets may name existing ones as blockers. Existing tickets are never rewritten or
renumbered. Before writing, `/ticket` announces it — "appending 04–05 to the existing itm-9909
board" — so the developer approves the numbers that will actually be written.

`/implement-tickets` reads an appended board like any other: it is one folder, or one label.
