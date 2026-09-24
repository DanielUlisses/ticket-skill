#!/usr/bin/env bash
# /small-ticket launcher — Herdr worktree + Claude Code
#
# The worktree/tab/agent mechanics are the shared ticket-launcher.sh, the same
# ones /ticket runs; this file is only what differs. The agent starts in plan
# mode, with just `git commit`/`git push` blocked, because a developer is there
# to approve the plan in the pane.
#
# Usage:
#   launch.sh [--account <name>] [--effort <level>] <tab-label> <branch> <ticket-file> [model]
#   launch.sh prompt <agent-name> <prompt-file>
#   launch.sh defaults
#
# `defaults` prints what a launch that named nothing would use — MODEL=, EFFORT=,
# ACCOUNT= (the account a *new* worktree inherits, which is not necessarily the
# one the asking session runs under), plus the option lists EFFORTS= and
# ACCOUNTS=. It reads, starts nothing, and needs no Herdr pane: the skills run it
# once a session to state the defaults in the question they ask before the first
# launch. See docs/agents/session-settings.md.
#
# Model resolution, highest wins: the optional 4th positional arg above →
# TICKET_IMPL_MODEL exported in the environment → config/models.env (installed
# as ticket-models.env next to this skill) → the fallback in the shared
# ticket-launcher.sh. This one model drives both the plan-mode orchestrator started here and the
# ticket-implementer subagent it delegates to. TICKET_PLAN_MODEL is retired —
# see docs/agents/models.md.
#
# Effort resolution, same shape and highest wins: the `--effort <level>` flag
# above → TICKET_IMPL_EFFORT exported in the environment → config/models.env →
# the fallback in the shared ticket-launcher.sh (`medium`). It is a flag rather
# than a 5th positional for the reason --account is: it is usually absent, and
# only the model earns a bare positional slot by varying every run. Any level
# other than low/medium/high/xhigh/max stops the launch — Claude Code itself
# merely warns and runs at its own default. See docs/agents/models.md.
#
# Optional variables:
#   TICKET_AGENT_KIND  (default: claude)  — Claude Code kind in Herdr (`herdr agent`)
#   TICKET_IMPL_MODEL   — orchestrator + implementer model; see resolution order above (fallback: opus)
#   TICKET_IMPL_EFFORT  — how hard the implementation model thinks (low|medium|high|xhigh|max); --effort beats it; see resolution order above (fallback: medium)
#   TICKET_REMOTE      (default: origin)
#   TICKET_BASE_BRANCH (default: remote's default branch, e.g. main)
#   TICKET_MODELS_CONF (default: <skills-dir>/ticket-models.env) — override the config file path
#   TICKET_LIB_DIR     — the directory holding the shared ticket-*.sh libraries (default: <skills-dir>)
#   TICKET_MEMORY_FILE (default: docs/agents/project-memory.md, relative to the main repo root) — per-repo project memory folded into the prompt; absent means the launch is unchanged
#   TICKET_REVIEWR_WAIT (default: 5) — seconds to wait for the reviewr plugin's pane before opening 'review' as a plain shell tab
#   TICKET_ACCOUNT     — the claude-acc account this ticket runs on; --account beats it. Unset means inherit whatever the worktree's parent directory is linked to, which writes no link at all. See docs/agents/accounts.md
#   TICKET_ACCOUNT_VERIFY_WAIT (default: 5) — seconds to wait for the started agent's process before giving up on reading the account it got
#   TICKET_ACCOUNT_LOCK_WAIT (default: 10) — seconds to wait for the lock on ~/.claude-switch/links before refusing to write it
#
# Exit codes: 0 = ok | 1 = error | 3 = agent stopped at a dialog (run the `prompt` subcommand afterward)

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- the shared libraries ----------------------------------------------------
# Installed one level up from the skill directories (~/.claude/skills/ticket-*.sh),
# where config/models.env also lands; in this repo's source tree they are in lib/.
# TICKET_LIB_DIR replaces that search outright rather than joining the front of
# it, so a typo in it is an error instead of a silent fall-through to another
# copy. `die` isn't defined until the libraries are sourced, so these errors are
# raw. Every script that sources them uses this block verbatim, bar the list.
if [[ -n "${TICKET_LIB_DIR:-}" ]]; then
  LIB_DIR="$TICKET_LIB_DIR"
else
  for d in "$(dirname "$SKILL_DIR")" "$(dirname "$(dirname "$SKILL_DIR")")/lib"; do
    [[ -f "$d/ticket-git-repo.sh" ]] && { LIB_DIR="$d"; break; }
  done
fi
for lib in ticket-git-repo.sh ticket-account.sh ticket-launcher.sh; do
  [[ -f "${LIB_DIR:-}/$lib" ]] \
    || { echo "ERROR: shared library $lib not found in ${LIB_DIR:-<no library directory found next to $SKILL_DIR>} — re-run install.sh, or set TICKET_LIB_DIR" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$LIB_DIR/$lib"
done

# The config file may set any TICKET_* variable, so it is loaded before the
# parameters below are resolved from the environment.
load_ticket_models

# ---- what makes this /small-ticket and not /ticket ---------------------------
TEMPLATE="$SKILL_DIR/templates/agent-prompt.md"
RUN_NAME="small-ticket"
PERMISSION_MODE="plan"
PERMISSION_LABEL="plan mode"
DISALLOWED_TOOLS=( "Bash(git commit:*)" "Bash(git push:*)" )

launcher_main "$@"
