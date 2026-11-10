# Batches

A **batch** is a set of tickets one end-to-end test proves together, run by
the developer on the deployed environment once every ticket of it has landed.
Testing per ticket costs a deploy and a context switch each; a batch costs one,
and it tests what the tickets do together. A **harness** ticket is the one that
builds what the test needs (a pipeline, seed data, a script): it is in the
batch like any other ticket.

## The batch file

`/ticket`'s planning names the batches with the developer and writes one file
per batch, `.scratch/<board>/batches/<name>.md` (the name lowercase letters,
digits, `.`, `_`, `-`):

```markdown
# Batch: dev-pipeline

**Proves:** the app deploys to dev from a tag and serves its health page.

**Env:** dev

**Tickets:** 01, 02, 04

**Harness:** 04 — the seed script the test needs

## Test plan
- Push a tag → the dev pipeline runs green
- Open /health on dev → 200 with the build sha
```

The test plan here is the skeleton: the steps that prove the batch's goal.
Each ticket of the batch carries `**Tested in:** <name>` and its report's
`## Test plan` starts "Tested in <name>." and lists only what it adds
(docs/agents/test-plan.md); tk-hub joins the skeleton and those into the
batch's one plan. The board loader never reads `batches/` as tickets.

## A batch across repos

A plan that changes several repos is one board per repo under one name
(docs/agents/jira-parent.md), and a batch may take tickets from any of them:
`/ticket` writes the same batch file into each repo that has a ticket in it
(a copy's **Tickets:** line may name every repo's tickets; another repo's is
that repo's copy to carry), and a ticket moves with `tk.sh batch` run from its
own repo. tk-hub joins the
same-named batches of a board name's boards on one box into one batch with one
test, ready once every repo's tickets have landed, and names its tickets
`<repo> #NN`. Nothing in `tk.sh` changes: each board still exports its own
copy.

## Moving a ticket

`tk.sh batch <board> <NN> <batch|none>` writes the ticket's `**Tested in:**`
line (below `**Blocked by:**`) and keeps the batch files' `**Tickets:**`
lines in step; `none` takes it out, and the ticket is tested alone again. It
refuses a batch with no file. A ticket's `**Tested in:**` line is what counts:
a batch's tickets are its `**Tickets:**` line plus every ticket naming it.
tk-hub's project chat sends it when the developer moves a ticket.

## What tk-hub does with it

`tk.sh export` carries `batches`: `[{name, file, proves, env, tickets, harness,
test_plan}]`. tk-hub raises no per-ticket Verify for a batched ticket; once all
the batch's tickets have landed it posts the batch as ready in the project
chat with its joined test plan, the developer gives it hours and it becomes one
task, and the result is Green (the batch is proved) or Red (what failed goes
to the project chat, and the fixes join the next run).
