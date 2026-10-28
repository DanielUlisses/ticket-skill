# 0008 — A remote on no forge we know is local mode

- **Status:** Accepted
- **Date:** 2026-10-27
- **Deciders:** Daniel Ulisses
- **Amends:** 0005 §7 (detection: "anything else GitHub" becomes "anything else none") and 0007 §4
  (the local merge applies to local mode, not only to a repo with no remote); both stay as written

0005 §7 read the remote's URL and called anything that wasn't Azure DevOps GitHub. A repo whose
remote is a bare SSH repo, a Gitea, a NAS share or a local path then had every PR verb call `gh`
against a host `gh` doesn't know, and fail. 0007 §4 gave such repos nothing either: its local merge
ran only when there was no remote at all.

## Decision

- **Detection.** `forge_detect` matches the URL's host case-insensitively. `dev.azure.com` /
  `visualstudio.com` is Azure DevOps. A `github.com` host, an ssh alias starting `github.com-` or
  `github.com_`, or an SSH host whose `HostName` is `github.com` (read offline with `ssh -G`) is
  GitHub. Any other host is `none`.
- **Local mode** (`local_mode`) is no remote, or `none` *detected* with no forge named by
  `TICKET_FORGE` or a policy. `gates`, `ready` and `merge` take 0007 §4's local path. With a
  remote they add a fifth gate, `base`: the base is fetched once per run, and the local base must
  not be behind `<remote>/<base>` or diverged from it. `pr` and `push` refuse. The local base is
  never pushed, and landing is checked against the local base, not `<remote>/<base>`.
- **`forge: none` named** by a policy or the env stays push-only (0005 §7, §9), on any host.
- **The way out** for GitHub Enterprise, or an alias ssh can't resolve, is `TICKET_FORGE` or a
  policy `forge` of `github` / `azure`. The digest says so once, in a `WARN`, when a remote is
  detected as `none`.
- `tk.sh export` carries `merge_mode` (`pr` | `push` | `local`) so tk-hub needn't rebuild this rule.

See `docs/agents/policy.md` for the messages and the gate lines.
