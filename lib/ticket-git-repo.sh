#!/usr/bin/env bash
# Shared git/repo resolution for the ticket skills' scripts.
#
# Sourced, never executed. /ticket's and /small-ticket's launch.sh and
# /sweep-tickets' sweep.sh all resolve the same main checkout and the same base
# branch. /sweep-tickets' safety guards rest on that resolution being the same
# one the launchers used — the main checkout is refused even with --force, and a
# dirty worktree is refused that --force cannot override — which is why this is
# one definition rather than three copies kept in step by hand.
#
# Installed as ~/.claude/skills/ticket-git-repo.sh, one level up from the skill
# directories: a skill installs as a self-contained directory, so there is
# nowhere inside one to share a file from. That is where config/models.env
# already lands, as ticket-models.env.
#
# Defines functions and touches no shell options; each caller keeps its own
# `set -euo pipefail`.

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "command '$1' not found in PATH"; }

# Sets ROOT (the main checkout), REPO_NAME, and SELF (the worktree this was run
# from, which may be the same one). NR==1 of `worktree list` is always the main
# worktree, so a script run from a ticket's own worktree resolves the same root
# as one run from the checkout.
#
# Sets globals instead of printing, the convention these scripts follow wherever
# a `die` is reachable: a `die` inside a command substitution only exits that
# subshell, so the caller would carry on with an empty value and report a second,
# bogus error on top of the real one.
resolve_repo_root() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "the current directory is not a git repository"
  ROOT="$(git worktree list --porcelain | awk 'NR==1 && /^worktree /{ sub(/^worktree /, ""); print }')"
  [[ -n "$ROOT" && -d "$ROOT" ]] || die "couldn't determine the main repo root"
  REPO_NAME="$(basename "$ROOT")"
  SELF="$(git rev-parse --show-toplevel)"
}

# Sets BASE_BRANCH: TICKET_BASE_BRANCH, else the remote's default branch, else
# whichever of main/master exists locally. Needs ROOT and REMOTE.
resolve_base_branch() {
  local b
  BASE_BRANCH="${TICKET_BASE_BRANCH:-}"
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH="$(git -C "$ROOT" symbolic-ref --quiet --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null || true)"
    BASE_BRANCH="${BASE_BRANCH#"$REMOTE"/}"
  fi
  if [[ -z "$BASE_BRANCH" ]]; then
    for b in main master; do
      git -C "$ROOT" show-ref --verify --quiet "refs/heads/$b" && { BASE_BRANCH="$b"; break; }
    done
  fi
  [[ -n "$BASE_BRANCH" ]] || die "couldn't detect the base branch (set TICKET_BASE_BRANCH)"
}

# git over the network: no credential prompt, and a timeout where the system has
# one, so it can't hang. Always against ROOT.
run_git_net() {
  if command -v timeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 timeout 120 git -C "$ROOT" "$@"
  else
    GIT_TERMINAL_PROMPT=0 git -C "$ROOT" "$@"
  fi
}
