#!/usr/bin/env bash
# The agent user: ticket agents running as their own user instead of the
# developer's (ADR 0011, docs/agents/accounts.md, Agent user).
#
# Sourced, never executed, by ticket-git-repo.sh, so every script that resolves
# a repo has these. Installed as ~/.claude/skills/ticket-agent.sh beside it.
#
# Off unless the box says otherwise. The box is devboxes with `agent_user: true`:
# it writes the agent user's name into the box policy (`agent_user`, read from
# that layer only: a repo or board can't turn it on or off) and its layout into
# /etc/tk-agent.conf (root-owned). TICKET_AGENT_USER overrides the policy, and
# an empty or unset name everywhere is today's behaviour, untouched.
#
# What changes with it on is all here, so the callers stay one line each:
#   - agent_prepare_worktree: the worktree's files group-writable, its git
#     metadata not, so nothing the agent writes runs as the developer;
#   - agent_state_file: the report, phase and questions files the agent writes,
#     made one by one in the box's shared state dir and linked from where the
#     board reads them;
#   - agent_git_guard: no repo hooks for the developer's git in a worktree
#     (core.hooksPath can point into the tree, which the agent edits);
#   - agent_config_dir_for / agent_config_roots: the agent's own Claude config
#     roots, where its transcripts land.

TKA_CONF="${TICKET_AGENT_CONF:-/etc/tk-agent.conf}"
TKA_WRAPPER=/usr/local/libexec/tk-agent-claude
TKA_RUNNER=/usr/local/libexec/tk-agent-run

# Sets TKA_USER (empty: off), and with it on TKA_HOME, TKA_GROUP,
# TKA_STATE and TKA_WORK from the box's conf. Dies when the policy names
# an agent user the box isn't set up for: launching as the developer then
# would be the silent fallback the switch exists to prevent.
resolve_agent_user() {
  TKA_USER="${TICKET_AGENT_USER-}"
  if [[ -z "${TICKET_AGENT_USER+x}" ]]; then
    local f="${TICKET_BOX_POLICY:-$HOME/.config/tk-daemon/policy.json}"
    [[ -s "$f" ]] && TKA_USER="$(jq -r '.agent_user // "" | strings' "$f" 2>/dev/null || true)"
  fi
  TKA_HOME="" TKA_GROUP="" TKA_STATE="" TKA_WORK=""
  [[ -n "$TKA_USER" ]] || return 0
  [[ "$TKA_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid agent user '$TKA_USER' (TICKET_AGENT_USER or the box policy's agent_user)"
  [[ -r "$TKA_CONF" ]] \
    || die "the box policy names the agent user '$TKA_USER', but $TKA_CONF is missing — devbox sync sets it up (agent_user: true); TICKET_AGENT_USER= launches as you"
  local c; c="$(sed -n 's/^AGENT_USER=//p' "$TKA_CONF" | head -1)"
  [[ "$c" == "$TKA_USER" ]] || die "the agent user is '$TKA_USER', but $TKA_CONF sets up '${c:-nobody}'"
  TKA_GROUP="$(sed -n 's/^GROUP=//p' "$TKA_CONF" | head -1)"; TKA_GROUP="${TKA_GROUP:-tkwork}"
  TKA_STATE="$(sed -n 's/^STATE=//p' "$TKA_CONF" | head -1)"
  TKA_WORK="$(sed -n 's/^WORK=//p' "$TKA_CONF" | head -1)"
  TKA_HOME="$(getent passwd "$TKA_USER" 2>/dev/null | cut -d: -f6)"
  [[ -n "$TKA_HOME" ]] || die "no user '$TKA_USER' on this box (devbox sync with agent_user: true makes it)"
  [[ -n "$TKA_STATE" && -d "$TKA_STATE" ]] || die "$TKA_CONF names no shared state dir, or it is missing (${TKA_STATE:-unset})"
}

agent_on() { [[ -n "${TKA_USER:-}" ]]; }

# The agent's config root for a claude-acc account name: its own ~/.claude for
# default, else ~/.claude-switch/accounts/<name> under its home. The same rule
# as the wrapper's.
agent_config_dir_for() {
  local name="${1:-default}"
  if [[ -z "$name" || "$name" == default || "$name" == unknown ]]; then echo "$TKA_HOME/.claude"
  else echo "$TKA_HOME/.claude-switch/accounts/$name"; fi
}

# Every config root of the agent's, for transcript lookups (the developer reads
# them through the ACL devboxes sets). Prints nothing with the agent user off.
agent_config_roots() {
  agent_on || return 0
  local r
  [[ -d "$TKA_HOME/.claude" ]] && echo "$TKA_HOME/.claude"
  for r in "$TKA_HOME"/.claude-switch/accounts/*; do [[ -d "$r" ]] && echo "$r"; done
  return 0
}

# The worktree the agent works in: group TKA_GROUP, directories group-writable
# and setgid, files group-writable, a default ACL so what the developer adds
# later (a merge) stays editable. Not the `.git` file, and nothing of the main
# repo's git directory: the agent never writes git metadata (config, hooks,
# index), which is what would run as the developer the next time his git runs.
# If the agent replaces the `.git` file anyway, the developer's git refuses
# the worktree as another user's ("dubious ownership"): never set
# safe.directory for worktree paths.
agent_prepare_worktree() {
  local wt="$1" me; me="$(id -un)"
  [[ -d "$wt" ]] || die "no worktree $wt to prepare for the agent user"
  # Where the wrapper agrees to start: <work>/<repo>--<branch>.
  [[ "$(dirname "$wt")" == "$TKA_WORK" && "$(basename "$wt")" == *--* ]] \
    || die "$wt is not a ticket worktree under $TKA_WORK — the agent user's wrapper starts only in $TKA_WORK/<repo>--<branch>"
  # Only what the developer owns (a resumed worktree holds the agent's files
  # too, already its), and -h: a link is never followed to its target.
  chgrp -h "$TKA_GROUP" -- "$wt" 2>/dev/null \
    || die "couldn't give $wt to group $TKA_GROUP — are you in it? (devbox sync adds you; a Herdr started before that needs a restart)"
  find "$wt" -user "$me" ! -group "$TKA_GROUP" -exec chgrp -h "$TKA_GROUP" {} + \
    || die "couldn't give the files in $wt to group $TKA_GROUP"
  find "$wt" -path "$wt/.git" -prune -o -user "$me" -type d -exec chmod g+rwxs {} + \
    -o -user "$me" -type f -exec chmod g+rw {} + \
    || die "couldn't make the files in $wt writable by group $TKA_GROUP"
  [[ -L "$wt/.git" ]] || chmod g-w "$wt/.git" 2>/dev/null || true
  if command -v setfacl >/dev/null 2>&1; then
    find "$wt" -path "$wt/.git" -prune -o -user "$me" -type d -exec setfacl -d -m "g:$TKA_GROUP:rwX" {} + 2>/dev/null || true
  fi
  log "agent user: $wt is group $TKA_GROUP, its files writable by $TKA_USER, its git metadata not"
}

# agent_state_path <box path> — where agent_state_file puts it, making nothing.
# agent_state_file <box path> [initial content] — one file the agent writes outside its worktree
# (its report, phase or questions file), made in the box's shared state dir and
# linked from <box path>, where tk.sh and the tk daemon read it. Prints the
# shared path, which is the one the brief names (the agent can't enter the
# developer's home). The file is the developer's, group-writable; its directory
# is not, so the agent can rewrite the file but not swap it for a link.
agent_state_path() {
  local box="$1" rel
  rel="${box#"${XDG_STATE_HOME:-$HOME/.local/state}/ticket-skill/"}"
  [[ "$rel" != "$box" ]] || die "agent_state_path: $box is not under the ticket-skill state dir"
  echo "$TKA_STATE/$rel"
}
agent_state_file() {
  local box="$1" init="${2:-}" shared
  shared="$(agent_state_path "$box")"
  mkdir -p "$(dirname "$shared")"
  chgrp "$TKA_GROUP" "$(dirname "$shared")"; chmod 750 "$(dirname "$shared")"
  # Whatever an earlier run left as a plain file there is copied over once.
  if [[ -f "$box" && ! -L "$box" ]]; then cat "$box" >"$shared.tmp" && mv -f "$shared.tmp" "$shared"; fi
  [[ -L "$shared" ]] && rm -f "$shared"
  [[ -e "$shared" ]] || printf '%s' "$init" >"$shared"
  chgrp "$TKA_GROUP" "$shared"; chmod 660 "$shared"
  ln -sfn "$shared" "$box"
  echo "$shared"
}

# For the developer's git in a ticket's worktree, with the agent user on: no
# repo hooks. core.hooksPath may point into the tree (husky, pre-commit,
# devboxes' .githooks), and the agent writes the tree, so a hook there would
# run its code as the developer on the next commit, merge, rebase or push.
# Exported through git's own environment config, so it reaches every git a
# script runs. Off: nothing.
agent_git_guard() {
  agent_on || return 0
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
}

# What a launch summary says about it.
agent_summary() {
  if agent_on; then echo "$TKA_USER (sudo -n -u $TKA_USER $TKA_WRAPPER --account <account> --cwd <worktree> -- <claude args>)"
  else echo "off (claude runs as $(id -un))"; fi
}

# The paragraph the brief gets with the agent user on ({{AGENT_USER_NOTE}});
# nothing with it off. No MCP is named: per-project read-only MCPs don't exist
# yet, so a live fact is a question.
agent_brief_note() {
  agent_on || return 0
  cat <<NOTE
**You run as your own user on this box, \`$TKA_USER\`, not as the developer.** There are no cloud CLIs here (no az, aws or gcloud logins), no gh and no SSH keys: never try to sign in to one. Mock cloud and forge calls in tests. When the ticket needs a live fact only a cloud account holds (a resource's name, a setting's value), ask it as a question in the questions file. Your report, phase and questions files already exist: Read each one before you Write it. Git metadata is read-only to you (no \`git add\`, commit, stash, checkout or branch): leave the change in the worktree, as below. \`docker\` is rootless and yours.
NOTE
}

# The prefix that runs a command as the agent in worktree $1 (the merger's
# checks: the worktree's code is the agent's, never run as the developer).
agent_run_prefix() {
  agent_on || return 0
  echo "sudo -n -u $TKA_USER $TKA_RUNNER --cwd $1 --"
}
