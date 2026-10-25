# Board policy: `tk.sh policy` and `policy-set`

A board's rules — may it open a PR before a human has looked, may it merge on its own, may it
talk to the forge at all — are one JSON object. tk-hub and the local Haiku board session read
the same one, so a rule set in either place holds in both.

```
tk.sh policy     <board>                 # the resolved policy, as JSON
tk.sh policy-set <board> key=value...    # change it for this board only
```

Both run from the repo (any worktree of it resolves the main checkout), and need only the board's
directory: no remote, no base branch and no tickets are all fine.

## Layers

Later wins. Each layer is a JSON object, merged with jq's `*`: objects merge key by key (so
`synthesis.timeout` from the board keeps `synthesis.backends` from the box), anything else —
arrays included — is replaced whole.

| Layer | File |
|---|---|
| defaults | built in (below) |
| box | `$TICKET_BOX_POLICY`, default `~/.config/tk-daemon/policy.json` — which tk-hub's `install.sh daemon` is planned to seed |
| repo | `<main checkout>/.scratch/policy.json` |
| board | `<main checkout>/.scratch/<board>/policy.json` — the only file `policy-set` writes |

Then `forge` is settled last:

1. Env `TICKET_FORGE` (`github|azure|none`), when set, beats every layer.
2. A repo with no remote has `forge: none` whatever the layers or the env say — there is nothing to
   call (the same rule `forge_detect` has always had).

A missing file, or an empty one, is an empty layer: a repo with no policy files at all prints the
defaults. Malformed JSON, a file that isn't one JSON object, or a known key with the wrong type is
an error naming the file, and nothing is printed. Numbers are printed as integers when they are
whole (`2.0` prints as `2`).

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `forge` | `github` \| `azure` \| `none` | detected from the remote URL (`none` without a remote) | where PRs live. `none` is git-only mode (ADR 0005 §7): no `gh`/`az` call; `pr`, `gates`, `ready` and `merge` refuse, except with no remote, where `gates`, `ready` and `merge` take the local path (ADR 0007 §4) and only `pr` and `push` refuse |
| `require_human_before_pr` | bool | `true` | a PR (or, in tk-hub, a push) needs a human step first. In the board session that step is the developer naming the ticket ("open a PR for 03"); unattended automation (night shift) opens none |
| `auto_merge` | bool | `false` | a ticket whose PR passes every gate may be merged without the developer naming it |
| `night_shift` | bool | `false` | tk-hub: run the board as `auto` plus PR/push after review passes; merge only with `auto_merge` |
| `autonomy` | `assist` \| `auto` | `assist` | tk-hub's scheduler: `auto` launches frontier tickets as they unblock, within the caps, stopping at `human` and `needs`; `assist` launches only on a click. `auto` is allowed on at most one board per devbox (enforced by tk-hub, ticket-board:40); ▶ Run waves acts only on `night_shift` boards |
| `max_parallel` | whole number, 1–1000 | `4` | tk-hub: tickets running at once on the box |
| `usage_gate_pct` | number 0–100 | `90` | tk-hub: a Claude usage window at or above this stops automatic launches on the box |
| `synthesis` | object | `{"backends": ["agy"], "timeout": 300}` | tk-hub's summary runner; passed through, not checked inside |

Any other key is passed through untouched, at any layer — `tk.sh policy` prints it, nothing here
reads it.

Client policy — `require_human_before_pr` and `forge: none` — always beats tk-hub's scheduler and
night shift.

### Why these defaults

- `auto_merge` and `night_shift` are `false`: both let a board act without the developer, so a
  repo opts in.
- `require_human_before_pr` is `true`: a human sees each ticket before its PR exists, unless a repo
  or the box opts out by setting it `false`. In the board session nothing changes for the
  developer — a PR already opens only for a ticket they name, and naming it is the human step. The
  cost lands on automation: a repo that turns `night_shift` on still gets no PR from it until that
  repo (or the box) also sets `require_human_before_pr` to `false`. That is deliberate — opening PRs
  unattended is a second opt-in, not a side effect of the first.
- `autonomy`, `max_parallel`, `usage_gate_pct` and `synthesis` are the tk-hub design's own values.

## Who obeys it

- **Every `tk.sh` verb** (and `pr-open.sh`, `merge-conflict.sh`): `board_init` reads the layers'
  `forge` and uses it as `TICKET_FORGE` when the env sets none. So `forge: none` in a policy file
  stops the `gh`/`az` calls in `digest`, `view` and `why` too, not only the verbs the session
  chooses to run. Their git-only messages name where it came from: `forge: none (policy)` or
  `forge: none (TICKET_FORGE=none)`.
- **`tk.sh digest`** prints the policy every turn as one line, right under `BOARD`:
  `POLICY forge=… require_human_before_pr=… auto_merge=… autonomy=…`, then a
  `WARN policy: <key> is <value> — want … (tk.sh policy <board> names the file)` per known key of
  the wrong type. It is the same resolution as `tk.sh policy`, but lenient: a bad value doesn't
  stop the digest, it shows up as printed plus its WARN. If the policy can't be read at all
  (malformed JSON with `TICKET_FORGE` set, say) the line is `POLICY unknown — tk.sh policy <board>
  says why`. The line is in the digest's text only — not in its state file or the
  `/tmp/implement-tickets-digest-*.txt` that `/sweep-tickets` reads.
- **The board session** (`templates/board-prompt.md`) reads the digest's `POLICY` line every turn
  (the first turn's `--full` digest included), and runs `tk.sh policy` right before any PR or merge,
  acting on the latest read. `forge: none` beats every other key: it runs no PR or merge verb on its
  own and dispatches neither `ticket-pr-creator` nor `ticket-merger`, whatever `auto_merge` says.
  Asked for a PR or a merge, it runs `tk.sh pr` / `tk.sh merge` anyway and shows the refusal: both
  refuse before doing anything with the policy or env's `none`, as `no forge access here (policy)` /
  `(TICKET_FORGE=none)` — `push, open and merge the PR on the forge yourself`. A repo with **no
  remote** is the exception: `tk.sh merge` is a local merge there (ADR 0007; four local gates, the ticket's
  work committed through the guarded path, `--no-ff` into the local base), run on the developer's
  word or under `auto_merge` like any merge; only `tk.sh pr` and `push` refuse. With
  `require_human_before_pr` it opens a PR only for a ticket the developer names, and that request
  is the human step — it doesn't ask again. It merges without being asked only when `auto_merge`
  is `true`, and only what `tk.sh ready` lists (`READY none` is nothing to merge), stopping at the
  first that isn't `MERGED`. A conflict (exit 10) during an auto-merge dispatches nothing: the
  session says the ticket conflicts and waits for the developer's "merge NN", which takes the
  normal path (`ticket-merger`). The scheduler keys are tk-hub's — the session still launches only
  what the developer names.
- **tk-hub** (planned) reads the same JSON and writes a change made in its UI to the board file.

`board_init` checks only what it uses: malformed JSON, a file that isn't one object, or a bad
`forge` value stops every verb on that board with an error naming the file — fix the file, not the
verb. A wrong type on any other key (in the box file, say) doesn't stop a board; `tk.sh policy` and
`policy-set` report it.

## `policy-set`

```
tk.sh policy-set <board> auto_merge=true autonomy=assist
tk.sh policy-set <board> max_parallel=3 synthesis.timeout=600
tk.sh policy-set <board> 'synthesis={"backends":["cursor","claude"]}'
tk.sh policy-set <board> forge=          # an empty value removes the key from the board file
```

- Writes `.scratch/<board>/policy.json`, creating it, keeping every key it doesn't name.
- A value is JSON when it parses (`true`, `5`, `"x"`, `{...}`), otherwise a string. A dotted key sets
  inside an object; a plain key replaces its whole value.
- Every known key in the result is checked — booleans, `max_parallel` a whole number from 1 to
  1000, `usage_gate_pct` from 0 to 100, `assist|auto`, `github|azure|none` — before anything is
  written; a bad value dies with `not written — …` and the file is unchanged. A board file that is
  already malformed JSON is never overwritten; one with a bad value is checked like the rest, so
  `policy-set` can be what fixes it. Whole numbers are written as integers (`2.0` → `2`).
- `nan` parses as JSON `null` (jq's reading), so `max_parallel=nan` is refused as `null`, and an
  unknown key set to `nan` is stored as `null`.
- The read-merge-write holds `flock` on `.scratch/<board>/.policy.lock` (waiting up to 10s), so two
  writers can't lose each other's change; without `flock` installed it runs unlocked.
- Writes through a temp file in the same directory and `mv` (`write_atomic` in `board-lib.sh`,
  which `retro-apply` uses too), so a reader never sees half a file; the file keeps its mode (a new
  one gets the umask's). Prints `WROTE <file>`; `tk.sh policy` shows
  the result.

The repo and box layers are edited by hand (the box one may be seeded by tk-hub's installer).
