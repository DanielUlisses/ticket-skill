# 0008 — A remote on no forge we know is local mode

- **Status:** Accepted
- **Date:** 2026-10-27
- **Amended:** 2026-10-28 — GitHub Enterprise hosts `gh` knows are detected as `github`
- **Deciders:** Daniel Ulisses
- **Amends:** 0005 §7 (detection: "anything else GitHub" becomes "anything else none") 0007 §4
  (the local merge applies to local mode, not only to a repo with no remote) and 0005 §9 (the merger
  works in local mode); all stay as written

0005 §7 read the remote's URL and called anything that wasn't Azure DevOps GitHub. A repo whose
remote is a bare SSH repo, a Gitea, a NAS share or a local path then had every PR verb call `gh`
against a host `gh` doesn't know, and fail. 0007 §4 gave such repos nothing either: its local merge
ran only when there was no remote at all.

## Decision

- **Detection.** `forge_detect` matches the URL's host case-insensitively. `dev.azure.com` /
  `visualstudio.com` is Azure DevOps. A `github.com` host, an ssh alias starting `github.com-` or
  `github.com_`, or an SSH host whose `HostName` is `github.com` (read offline with `ssh -G`) is
  GitHub, and so is a GitHub Enterprise host `gh` already knows: a
  `*.ghe.com` host, the host `GH_HOST` names, or one `gh auth token --hostname <host>` finds a token
  for (offline, tried on the URL's host and its `ssh -G` HostName; with `GH_ENTERPRISE_TOKEN` unset
  for the probe, which would otherwise match every host). Without `gh` on PATH, none of these apply.
  Any other host is `none`.
- **Local mode** (`local_mode`) is no remote, or `none` *detected* with no forge named by
  `TICKET_FORGE` or a policy. `gates`, `ready` and `merge` take 0007 §4's local path. With a
  remote they add a fifth gate, `base`: the base is fetched once per run, and the local base must
  not be behind `<remote>/<base>` or diverged from it. `pr` and `push` refuse. The local base is
  never pushed, and landing is checked against the local base, not `<remote>/<base>`.
- **Conflicts go to `ticket-merger`.** `merge-conflict.sh` merges the local base (`refs/heads/<base>`),
  fetches nothing, and `finish` commits without pushing; `tk.sh merge` then lands it. Because the
  gates judge the branch plus its uncommitted work, `merge_local` first commits the ticket's work
  through `pr-cursor.sh --commit` when the conflict gate is the only failure (exit 10) — the
  developer's "merge NN" authorises it — so the worktree is clean for the merger. If paths are left
  out and it stays dirty, `start` refuses and the merger reports that.
- **`forge: none` named** by a policy or the env stays push-only (0005 §7, §9), on any host.
- **The way out** for a GitHub Enterprise host `gh` isn't logged into (`gh auth login --hostname
  <host>` fixes it; someone authenticated only through `GH_ENTERPRISE_TOKEN` sets `GH_HOST=<host>`),
  or an alias ssh can't resolve, is `TICKET_FORGE` or a policy `forge` of `github` / `azure`. The digest says so once, in a `WARN`, when a remote is
  detected as `none`.
- `tk.sh export` carries `merge_mode` (`pr` | `push` | `local`) so tk-hub needn't rebuild this rule.

See `docs/agents/policy.md` for the messages and the gate lines.
