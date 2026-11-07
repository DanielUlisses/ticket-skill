# Test plan

Every ticket's coordinator report ends its work with a `## Test plan`
(`templates/ticket-agent-prompt.md`, Phase 3; a helper session's report too):
3 to 6 plain `- ` steps the developer runs on the deployed environment, each
ending with the evidence that proves it ("open /health on dev: 200 with the
build sha"). It replaces the by-hand checklist synthesis used to write: the
developer is a DevOps engineer, and a ticket is done when its deploy is
proven, so the plan is the test after the merge.

A ticket with a `**Tested in:** <batch>` line is proved by its batch's test,
not on its own: its plan starts "Tested in <batch>." and lists only what this
ticket adds to that test. `board-lib.sh` parses the line as `tested_in`.

`tk.sh export` carries both per ticket: `tested_in` (empty when none) and
`test_plan`, the report's `## Test plan` lines (from
`.scratch/<board>/reports/<branch>.md`, bullets stripped, at most 20; [] when
the report has none). tk-hub makes the plan the ticket's **Merge and verify**
and **Verify after deploy** checklist, and raises no per-ticket Verify for a
ticket tested in a batch.
