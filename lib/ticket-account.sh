#!/usr/bin/env bash
# Per-ticket Claude account selection, shared by the two launchers and by
# /sweep-tickets.
#
# Sourced, never executed. `claude-acc` picks an account by exporting
# CLAUDE_CONFIG_DIR — a native Claude Code variable pointing at a whole per-account
# config directory — and it picks *which* account from the directory the shell is
# standing in, via ~/.claude-switch/links. The scope is per process, so two
# tickets on two accounts run side by side without racing over a credential store,
# and rate limits meter per account, so spreading tickets multiplies throughput.
#
# The default here is inheritance: with no account requested a launch writes no
# link at all and the worktree resolves whatever the developer's own top-level
# link says, exactly as it did before any of this existed. A link is written only
# when a ticket overrides the account, and /sweep-tickets takes it away again.
#
# Requires ticket-git-repo.sh to have been sourced first (die/log/need) and the
# caller to be running under `set -euo pipefail`.
#
# Installed as ~/.claude/skills/ticket-account.sh, one level up from the skill
# directories — see ticket-git-repo.sh for why it can't live inside one.

CLAUDE_SWITCH_DIR="${CLAUDE_SWITCH_DIR:-$HOME/.claude-switch}"
ACCOUNT_LINKS_FILE="$CLAUDE_SWITCH_DIR/links"
ACCOUNT_LINKS_LOCK="$CLAUDE_SWITCH_DIR/links.lock"

# The two waits, each in one place so the message that quotes one can't drift
# from the value that governs it:
#
#   ACCOUNT_LOCK_WAIT    how long to wait for the links lock. Bounded, because an
#                        unbounded `flock` would hang a launch forever on a stale
#                        holder — the opposite of the "a launch that can't take
#                        the lock doesn't happen" this file promises.
#   ACCOUNT_VERIFY_WAIT  how long to wait for a started agent's process before
#                        giving up on reading the account it got.
#
# Resolved in a function, and called both here and from launcher_main, for the
# same reason PERMISSION_MODE is resolved late: ticket-models.env may set any
# TICKET_* variable and is sourced *after* these libraries are. Sourcing gives
# /sweep-tickets — which reads no config file — its defaults; the second call
# lets a launcher's config file win.
resolve_account_env() {
  ACCOUNT_LOCK_WAIT="${TICKET_ACCOUNT_LOCK_WAIT:-10}"
  ACCOUNT_VERIFY_WAIT="${TICKET_ACCOUNT_VERIFY_WAIT:-5}"
  # No leading zeros: `08` clears a bare ^[0-9]+$ and then blows up as octal in
  # the arithmetic these feed — the same trap TICKET_REVIEWR_WAIT documents.
  [[ "$ACCOUNT_LOCK_WAIT" =~ ^(0|[1-9][0-9]*)$ ]] \
    || die "invalid TICKET_ACCOUNT_LOCK_WAIT '$ACCOUNT_LOCK_WAIT' — whole seconds, no leading zeros"
  [[ "$ACCOUNT_VERIFY_WAIT" =~ ^(0|[1-9][0-9]*)$ ]] \
    || die "invalid TICKET_ACCOUNT_VERIFY_WAIT '$ACCOUNT_VERIFY_WAIT' — whole seconds, no leading zeros"
}
resolve_account_env

# with_links_lock's answer for "the lock could not be taken", as distinct from
# "the command ran and failed". The two lead to different places: the launcher
# refuses to launch, the sweep warns and removes the worktree anyway.
ACCOUNT_LOCK_UNAVAILABLE=111

# Whether the switcher is installed at all. A machine without it has no accounts
# to choose between, and the default path must still launch exactly as it did
# before this file existed — so every caller asks this first rather than `need`ing
# the binary unconditionally.
have_claude_acc() { command -v claude-acc >/dev/null 2>&1; }

# Runs a command while holding an exclusive lock on claude-acc's links file.
#
# `claude-acc link` and `unlink` are read-modify-write on one small file, and
# what two unserialised writers lose is not only the entry one of them was
# writing. Measured here with twelve concurrent links: two survived, and the
# developer's own top-level entries — the ones every worktree inherits from —
# were among the ten that didn't. So this refuses to write at all rather than
# write unlocked; an account override that can't take the lock is a launch that
# doesn't happen, which costs one ticket, where the race costs the machine's
# whole account layout.
#
# The lock is a file of its own, never `links` itself: claude-acc may replace
# that file by rename, and a lock taken on the inode it replaced would guard
# nothing.
#
# The command runs in a subshell, so it must not set globals, and a `die` inside
# it would exit only that subshell — callers check the status returned here.
#
# It returns rather than dying on a lock it can't take, including for a missing
# flock: the two callers want different things from that. A launch refuses to go
# on; /sweep-tickets warns and removes the worktree anyway, because a `die` there
# would abort a removal that has already passed all four of its guards and leave
# the developer worse off than the stale link does.
with_links_lock() {
  command -v flock >/dev/null 2>&1 || return "$ACCOUNT_LOCK_UNAVAILABLE"
  : 2>/dev/null >>"$ACCOUNT_LINKS_LOCK" || return "$ACCOUNT_LOCK_UNAVAILABLE"
  ( flock -w "$ACCOUNT_LOCK_WAIT" 9 || exit "$ACCOUNT_LOCK_UNAVAILABLE"; "$@" ) 9>>"$ACCOUNT_LINKS_LOCK"
}

# Whether claude-acc has an account by this name. Asked before a worktree exists,
# so a typo costs nothing; `claude-acc link` is the authority and validates the
# name itself, but by then there is a worktree, a workspace and a branch to sweep.
#
# `default` is claude-acc's name for the standard ~/.claude, which has no
# directory of its own; every other account is one under accounts/. That layout
# is known here rather than in the launcher because account_name_for already maps
# it the other way — one file owns it, or two files drift.
account_exists() {
  local name="$1"
  [[ "$name" == default ]] && return 0
  [[ -d "$CLAUDE_SWITCH_DIR/accounts/$name" ]]
}

# The Claude config root an account name resolves to. An account is not just a
# credential: it is a whole config root, and Claude Code reads *its* skills/ and
# agents/, which is what install.sh takes a dest argument for.
account_root_for() {
  local name="$1"
  [[ "$name" == default ]] && { printf '%s' "$HOME/.claude"; return 0; }
  printf '%s' "$CLAUDE_SWITCH_DIR/accounts/$name"
}

# The CLAUDE_CONFIG_DIR a shell started in <dir> resolves to, or empty when
# claude-acc resolves no account there — which is the standard ~/.claude.
#
# `claude-acc activate` is the resolver itself: it is what `claude-acc init bash`
# evals, both on shell startup and from the PROMPT_COMMAND hook it installs. So
# this asks the same question the pane will answer, rather than guessing at the
# layout of ~/.claude-switch/accounts. Its output is evaluated for the same
# reason — it is `export CLAUDE_CONFIG_DIR='...'` or `unset CLAUDE_CONFIG_DIR`,
# and evaluating it is how the tool is meant to be read.
account_config_dir() {
  local dir="$1" out
  out="$(cd "$dir" 2>/dev/null && claude-acc activate --shell posix 2>/dev/null)" || return 1
  # Cleared first, so an `unset` really reads as unset rather than leaving this
  # shell's own value standing.
  ( unset CLAUDE_CONFIG_DIR; eval "$out"; printf '%s' "${CLAUDE_CONFIG_DIR:-}" )
}

# A config directory as the name `claude-acc link` would take for it: the
# directory under ~/.claude-switch/accounts, or `default` for the standard
# ~/.claude that an unset CLAUDE_CONFIG_DIR means. Anything else is printed
# whole — an account directory somewhere this doesn't know about is still worth
# naming in the summary.
account_name_for() {
  local cfg="$1" rest
  [[ -n "$cfg" ]] || { printf 'default'; return 0; }
  case "$cfg" in
    "$CLAUDE_SWITCH_DIR"/accounts/*)
      rest="${cfg#"$CLAUDE_SWITCH_DIR"/accounts/}"; printf '%s' "${rest%%/*}" ;;
    *) printf '%s' "$cfg" ;;
  esac
}

# Whether <dir> has a link entry of its very own. Inherited links belong to the
# developer and are never a ticket's to remove; this is the same exact-match
# question `claude-acc unlink` asks, asked while the directory still exists.
account_linked_exactly() {
  local dir="$1"
  [[ -f "$ACCOUNT_LINKS_FILE" ]] || return 1
  # Entries are `<path>=<account>`; the path is compared as a string, never as a
  # pattern, because a worktree path may contain regex metacharacters.
  awk -v d="$dir" '{ p = $0; sub(/=[^=]*$/, "", p); if (p == d) { found = 1 } }
                   END { exit found ? 0 : 1 }' "$ACCOUNT_LINKS_FILE"
}

# Links <dir> to <account>. Call through with_links_lock.
account_link() {
  local dir="$1" name="$2"
  ( cd "$dir" && claude-acc link "$name" >/dev/null )
}

# Drops <dir>'s own link entry, if it has one. Call through with_links_lock.
#
# The directory may already be gone — /sweep-tickets removes worktrees, and a
# `gh pr merge --delete-branch` removes them without asking this code anything —
# and claude-acc has no way to unlink a path it cannot cd into. So a live directory
# goes through `claude-acc unlink` and a missing one has its single
# `<path>=<account>` line dropped in place, matching the path exactly and copying
# every other line through byte for byte.
account_unlink() {
  local dir="$1" tmp
  if [[ -d "$dir" ]]; then
    ( cd "$dir" && claude-acc unlink >/dev/null )
    return
  fi
  [[ -f "$ACCOUNT_LINKS_FILE" ]] || return 0
  tmp="$(mktemp "${ACCOUNT_LINKS_FILE}.XXXXXX")" || return 1
  awk -v d="$dir" '{ p = $0; sub(/=[^=]*$/, "", p); if (p != d) print }' \
    "$ACCOUNT_LINKS_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  # Same mode as the file it replaces, so the switcher's own permissions survive.
  chmod --reference="$ACCOUNT_LINKS_FILE" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$ACCOUNT_LINKS_FILE"
}

# Every entry in the links file, as `<path><TAB><account>` lines, in the file's
# own order.
#
# Read from the file rather than asked of `claude-acc links`, which prints for
# people; and the entries this exists to find are exactly the ones claude-acc can
# no longer reach, whose directory is gone. A line carrying no `=` is skipped
# rather than guessed at, so a file that grows a header or a comment some day
# reads as having no entry on that line instead of one with an empty account.
account_link_entries() {
  [[ -f "$ACCOUNT_LINKS_FILE" ]] || return 0
  awk '{ p = $0; if (!sub(/=[^=]*$/, "", p)) next; if (p == "") next
         print p "\t" substr($0, length(p) + 2) }' "$ACCOUNT_LINKS_FILE"
}

# Drops <dir>'s entry, says so, and returns what happened: 0 removed,
# ACCOUNT_LOCK_UNAVAILABLE when the lock couldn't be taken, 1 for anything else.
#
# Split out from account_release because the two callers want opposite things
# from a failure. A sweep that is about to remove the worktree anyway must not
# die on the link (see below). A developer who asked for exactly this one entry
# to go must not be told it went when it didn't.
account_prune_link() {
  local dir="$1" rc=0
  with_links_lock account_unlink "$dir" || rc=$?
  [[ $rc -eq 0 ]] && echo "REMOVED account link for $dir"
  return "$rc"
}

# Removes <dir>'s link if it has one of its own, and says what it did. Safe to
# call for any worktree: a ticket that never overrode its account has no entry,
# and an inherited one is somebody else's.
#
# Never fatal, and returns 0 whatever happened. It is called from /sweep-tickets
# after every guard has passed, so the worktree is going with or without its
# link — and a stale line in `links` is a smaller problem than a removal that
# aborts halfway. Both failures name the hand fix instead. `remove --link` is the
# other way round — it is the write the developer asked for — and calls
# account_prune_link itself.
account_release() {
  local dir="$1" rc=0
  have_claude_acc || return 0
  account_linked_exactly "$dir" || return 0
  account_prune_link "$dir" || rc=$?
  if [[ $rc -eq $ACCOUNT_LOCK_UNAVAILABLE ]]; then
    log "warning: couldn't take the lock on $ACCOUNT_LINKS_LOCK within ${ACCOUNT_LOCK_WAIT}s (or flock is missing) — leaving the claude-acc link for $dir in place; take it back with 'sweep.sh remove --link $dir' once the lock is free"
  elif [[ $rc -ne 0 ]]; then
    log "warning: couldn't remove the claude-acc link for $dir — take it back with 'sweep.sh remove --link $dir', or edit $ACCOUNT_LINKS_FILE by hand"
  fi
  return 0
}

# The CLAUDE_CONFIG_DIR the process running in <pane> actually got.
#
# Read from the process's own environment, not from `claude-acc status`, which
# would only re-answer the question from the links file. The failure this guards
# against is the pane's shell never applying that answer — and only the started
# process can say whether it did. /proc holds the environment as of the exec,
# which is exactly the one Claude Code is running under.
#
# Prints the value (empty is a real answer: the standard ~/.claude) and returns
# 0; returns 1 when no started process appeared, 2 when its environment can't be
# read — a machine with no readable /proc, say.
account_pane_config_dir() {
  local pane="$1" deadline info pid shell_pid e
  local -a envv
  deadline=$((SECONDS + ACCOUNT_VERIFY_WAIT))
  while :; do
    info="$(herdr pane process-info --pane "$pane" 2>/dev/null || true)"
    pid="$(jq -r '.result.process_info.foreground_processes[0].pid // empty' <<<"$info" 2>/dev/null || true)"
    shell_pid="$(jq -r '.result.process_info.shell_pid // empty' <<<"$info" 2>/dev/null || true)"
    [[ -n "$pid" && "$pid" != "$shell_pid" ]] && break
    (( SECONDS < deadline )) || return 1
    sleep 0.2
  done
  [[ -r "/proc/$pid/environ" ]] || return 2
  # Read whole, never piped through grep: the entries are NUL-separated, and a
  # pipeline that exits early trips the callers' `pipefail`.
  mapfile -d '' -t envv <"/proc/$pid/environ" 2>/dev/null || return 2
  # Nothing at all means the read failed, not that the variable is unset — a live
  # process always has an environment, and a process that exited between the test
  # above and this read yields an empty one. Saying `unset` here would match a
  # worktree that resolves to the standard ~/.claude and call it verified.
  [[ ${#envv[@]} -gt 0 ]] || return 2
  for e in ${envv[@]+"${envv[@]}"}; do
    [[ "$e" == CLAUDE_CONFIG_DIR=* ]] && { printf '%s' "${e#CLAUDE_CONFIG_DIR=}"; return 0; }
  done
  return 0
}
