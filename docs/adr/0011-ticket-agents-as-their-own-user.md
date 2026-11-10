# 0011 — Ticket agents run as their own user

- **Status:** Accepted, behind a switch that is off (proof on a box pending — see *Unproven*)
- **Date:** 2026-11-10
- **Deciders:** Daniel Ulisses
- **Builds on:** [0005](0005-scratch-boards-retro-and-presales.md) §9 (guarded commits), `docs/agents/accounts.md`

## Context

A ticket's agent runs unattended with `bypassPermissions`, as the developer. Its only guardrail is the
`--disallowedTools` list. Everything the developer's user holds is therefore one prompt injection away:
the 1Password service account token, `gh`, `az`, SSH keys, the Docker socket (root by another name),
sudo. A ticket reads text from outside (an issue, a PR comment, a dependency's README), so "talked into
something" is a real path, not a thought experiment.

## Decision

With the switch on, every ticket agent (and a helper session) runs as `<user>-agent`, a user devboxes
creates with none of that (`agent_user: true` in the client file; see devboxes' README, *Ticket agents
as their own user*). The developer's user keeps doing what needs credentials: the worktree, commits,
pushes, PRs, merges.

**How claude gets started as another user.** Herdr starts the agent (`herdr agent start --kind claude`),
not the launcher, so the launcher can't put `sudo` in front of it. Instead the developer's shell puts a
`claude` shim first on PATH while its directory is a ticket worktree of group `tkwork` (a prompt hook
in devboxes' `.bashrc`). The shim calls `sudo -n -u <agent> /usr/local/libexec/tk-agent-claude`, a
root-owned wrapper that builds the agent's environment from nothing and refuses to start anywhere but a
`<work>/<repo>--<branch>` worktree of group `tkwork`. Herdr still sees a claude in the pane.

**Where the switch is.** The box policy's `agent_user` (devboxes writes it into
`~/.config/tk-daemon/policy.json`), read from that layer only, so no repo or board can turn it on or
off; `TICKET_AGENT_USER` overrides it, and empty is off. The box's layout (group, shared state dir,
work dir) is in `/etc/tk-agent.conf`, root-owned. `lib/ticket-agent.sh` holds everything that changes.

**What the agent may write.** Its worktree's files (group `tkwork`, group-writable), and three files
outside it, each made by the launcher in `/var/lib/tk-agent/<user>/` and linked from where the board
reads them: the report, the phase file and the questions file. Their directories are not writable by
the agent, so it can rewrite a file but not swap it for a link. Never git metadata: the main repo's
`.git` (config, hooks, `worktrees/<name>/index`) stays the developer's and read-only to the agent,
whose git runs with `GIT_OPTIONAL_LOCKS=0`.

**The developer's account, the agent's config root.** claude-acc's link still picks the account. The
shim passes its name; the wrapper maps it to a config root in the agent's home (`~/.claude`, or
`~/.claude-switch/accounts/<name>`), never the developer's: a config root holds settings, hooks and
plugins the developer's own sessions load. The login inside it is the box's, which exists for its
agents (Daniel, 2026-11-10): devboxes links its `.credentials.json` to the developer's for the same
account, the agent may read and write that one file (a refresh rewrites it) and nothing else in his
root. A `claude setup-token` token in the agent's home wins over it.

## The paths back to the developer, and how each is closed

Anything the developer's user executes from the worktree runs the agent's code with his credentials.

| Path | Closed by |
|---|---|
| Repo hooks: `core.hooksPath` can point into the tree (husky, pre-commit, `.githooks`); `pr-open.sh` commits, `merge-conflict.sh` and `tk.sh merge` merge, `tk.sh rebase` rebases, a push runs `pre-push` | `agent_git_guard` in `repo_init`: `core.hooksPath=/dev/null` for every git the board's scripts run (git's environment config) |
| `.git/config`, `.git/hooks`, `info/attributes`, `config.worktree` (`core.fsmonitor`, `core.sshCommand`, filter drivers) | never group-writable; the agent can't write them |
| A replaced `.git` file pointing at a git dir the agent made | git's ownership check refuses it; the developer never sets `safe.directory` for worktree paths |
| A trusted mise config the agent edits, run by the developer's shell | the launcher no longer runs `mise trust`; the wrapper trusts it in the agent's own store |
| The shell pane in the worktree | its `claude` is the agent's too (the shim); the developer's own commands there are his to choose |
| Cursor writing PR text: `cursor-agent --trust` in the worktree would load its `.cursor/` rules and MCP servers | runs in an empty directory; the prompt already holds the diff |
| `ticket-merger` running the repo's checks | runs them through `sudo -n -u <agent> /usr/local/libexec/tk-agent-run --cwd <worktree> --` (`merge-conflict.sh` prints the prefix as `RUN_CHECKS_AS`) |
| `/proc/<pid>/environ` of another user's process can't be read (the account check) | with the agent user on, the check is that a process of the agent's runs in the pane; a claude that started as the developer dies before the prompt is sent |
| Transcripts land in the agent's home | `tk.sh` (`ticket_transcript`), resume and tk-hub's daemon also look there (devboxes' ACL lets the developer read them) |

**Not closed: text.** The board session, `ticket-merger` and the PR creator run as the developer and read
what the agent wrote (its report, the diff). That is persuasion, not execution. The merger has Read,
Edit, Grep, Glob and Bash; the board session runs `tk.sh` and `herdr`; the PR text goes through Cursor
(no tools, an empty directory) or `ticket-pr-creator`. Each still asks the developer before a merge.

## Unproven

Four assumptions, to be tried by hand on a box before the switch goes on anywhere:

1. Herdr starts `claude` through the pane's shell, so the shim on PATH is the `claude` it runs, and it
   still reports idle/working/blocked, takes `herdr agent prompt` and reads the pane for a process
   owned by another user (with `sudo` between them).
2. The shared login holds: Claude Code rewrites `.credentials.json` in place on a refresh (through
   the agent's link, keeping the file's ACL) rather than replacing it, from either user, and
   neither side's refresh logs the other out.
3. Rootless Docker runs for the agent inside an unprivileged LXC: subordinate ids the container has
   mapped, `docker run hello-world` and a PostgreSQL container.
4. The agent's work needs no git write: `git status` and `git diff` with `GIT_OPTIONAL_LOCKS=0`, and
   whatever the reviewer and tester subagents call; Claude's Write tool can rewrite a pre-created file
   in a directory it can't write.

## Consequences

- Off by default, and nothing changes with it off: every new line is behind `agent_on`.
- Repo hooks don't run for commits the board makes with the switch on. A repo whose pre-commit hook
  is a safety check (devboxes' secret scan) should also run it in CI.
- Turn it on only on a box with no ticket running: transcripts of running agents stay in the
  developer's home, so their resume starts from the full brief.
- An agent loses `az` until per-project read-only MCPs exist; a box whose agents need it stays off.
- The agent's Claude has no user-level skills or plugins of the developer's: its subagents come
  through `--agents` (on by default), catalog skills through the worktree.
