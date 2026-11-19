#!/usr/bin/env bash
# Shared git/repo resolution for the ticket skills' scripts.
#
# Sourced, never executed. /ticket's launch.sh, /implement-tickets' scripts and
# /sweep-tickets' sweep.sh all resolve the same main checkout and the same base
# branch. /sweep-tickets' safety guards rest on that resolution being the same
# one the launcher used — the main checkout is refused even with --force, and a
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

# Sets BASE_BRANCH: TICKET_BASE_BRANCH, else the repo policy's base_branch, else
# the remote's default branch, else whichever of main/master exists locally.
# Needs ROOT and REMOTE.
#
# Only the repo layer (<ROOT>/.scratch/policy.json) can name the base: the
# launchers and sweep.sh resolve it with no board in hand, and they must all
# agree, so a board or box base_branch is never read here.
resolve_base_branch() {
  local b f="$ROOT/.scratch/policy.json" layer
  BASE_BRANCH="${TICKET_BASE_BRANCH:-}"
  if [[ -z "$BASE_BRANCH" && -e "$f" ]]; then
    # Read the way board-lib.sh's policy_read_layer does, so a file is malformed
    # (or an empty layer) here exactly when it is there.
    need jq
    layer="$(jq -cs 'if length == 0 then {} elif length == 1 and (.[0] | type) == "object" then .[0]
                     else error("not one JSON object") end' "$f" 2>&1)" \
      || { layer="${layer#jq: error (at *): }"; die "policy file $f is malformed: ${layer#jq: }"; }
    BASE_BRANCH="$(jq -r 'if .base_branch == null then ""
                          elif (.base_branch | type) == "string" and .base_branch != "" then .base_branch
                          else error("base_branch is \(.base_branch | tojson) — want a branch name") end' <<<"$layer" 2>&1)" \
      || die "policy file $f: ${BASE_BRANCH#jq: error (at <stdin>:*): }"
    if [[ -n "$BASE_BRANCH" ]]; then
      if [[ "$BASE_BRANCH" == refs/* || "$BASE_BRANCH" == "$REMOTE"/* ]]; then
        b="${BASE_BRANCH#refs/heads/}"; b="${b#refs/remotes/}"; b="${b#"$REMOTE"/}"
        die "policy file $f: base_branch '$BASE_BRANCH' — name the branch alone (e.g. $b), not a ref or $REMOTE/<branch>"
      fi
      git check-ref-format --branch "$BASE_BRANCH" >/dev/null 2>&1 \
        || die "policy file $f: base_branch '$BASE_BRANCH' is not a valid branch name"
    fi
  fi
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH="$(git -C "$ROOT" symbolic-ref --quiet --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null || true)"
    BASE_BRANCH="${BASE_BRANCH#"$REMOTE"/}"
  fi
  if [[ -z "$BASE_BRANCH" ]]; then
    for b in main master; do
      git -C "$ROOT" show-ref --verify --quiet "refs/heads/$b" && { BASE_BRANCH="$b"; break; }
    done
  fi
  [[ -n "$BASE_BRANCH" ]] || die "couldn't detect the base branch (set TICKET_BASE_BRANCH, or base_branch in $f)"
}

# git over the network: no credential prompt, and a timeout where the system has
# one, so it can't hang. Always against ROOT.
# GIT_TERMINAL_PROMPT=0 alone doesn't stop Git Credential Manager waiting on a
# browser sign-in, or ssh on a passphrase, so those are switched off too.
run_git_net() {
  local -a t=()
  command -v timeout >/dev/null 2>&1 && t=(timeout "${TICKET_GIT_TIMEOUT:-120}")
  GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false \
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
    "${t[@]}" git -C "$ROOT" "$@" </dev/null
}

# The agent user's helpers (ticket-agent.sh, installed beside this file): every
# script that resolves a repo can tell whether tickets run as their own user.
# shellcheck source=lib/ticket-agent.sh
source "$(dirname "${BASH_SOURCE[0]}")/ticket-agent.sh"

# ---- the answers ledger ---------------------------------------------------------
# One file per repo, .scratch/answers.md in the MAIN checkout (beside project
# memory: gitignored, never committed, out of /sweep-tickets' reach): every answer
# the developer gave on any board of the repo, appended by `tk.sh answer` (and by
# record_answers, for one that arrived as a plain message). The launcher folds
# the entries that bear on a ticket into its brief, and `tk.sh resume` into its
# note, so a second agent doesn't ask what a first one was told.
# docs/agents/questions.md, The ledger.
#
# An entry is two lines, the format append_answer writes under ## Answers with
# the ticket and the scope added:
#   - **<board>#<NN> <id>** (<at>, <scope>) <question on one line>
#     Answer: <answer; later lines indented two spaces>
# scope is `project` (holds for every ticket of the repo) or `ticket`.
answers_ledger_file() {
  local f="${TICKET_ANSWERS_FILE:-.scratch/answers.md}"
  [[ "$f" == /* ]] || f="$ROOT/$f"
  echo "$f"
}

# answers_ledger_append <board> <nn> <id> <question> <answer> <at> [<scope>]
# Best effort: an unwritable ledger never fails the answer itself. The same
# question of the same ticket is written once.
answers_ledger_append() {
  local board="$1" nn="$2" id="${3:-note}" q="${4//$'\n'/ }" a="$5" at="$6" scope="${7:-ticket}" f
  [[ "$scope" == project ]] || scope=ticket
  f="$(answers_ledger_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  if [[ ! -s "$f" ]]; then
    printf '# Answers ledger\n\nEvery answer the developer gave to an agent'"'"'s question in this repo, oldest first. Written by `tk.sh answer`; read by every ticket launch and resume. Edit by hand to fix or drop an entry.\n' >"$f" 2>/dev/null || return 0
  fi
  grep -F -- "- **$board#$nn $id** (" "$f" 2>/dev/null | grep -qF -- "${q:0:80}" && return 0
  {
    printf '\n- **%s#%s %s** (%s, %s) %s\n' "$board" "$nn" "$id" "$at" "$scope" "$q"
    printf '  Answer: %s\n' "${a//$'\n'/$'\n'  }"
  } >>"$f" 2>/dev/null || true
}

# answers_ledger_entries <board> <nn> [all]
# The entries a ticket should know, newest first, cut at TICKET_ANSWERS_MAX_BYTES
# (default 4096): every project-scope entry, and its own board's ticket-scope
# ones. Its own ticket's entries are left out (they are under its ## Answers).
# `all` as the third argument prints the whole ledger's entries instead, uncut.
answers_ledger_entries() {
  local board="$1" nn="$2" all="${3:-}" f
  f="$(answers_ledger_file)"
  [[ -r "$f" ]] || return 0
  awk -v board="$board" -v nn="$nn" -v all="$all" -v max="${TICKET_ANSWERS_MAX_BYTES:-4096}" '
    /^- \*\*/ { n++; head[n] = $0; body[n] = $0; next }
    n && /^  / { body[n] = body[n] "\n" $0; next }
    n && /^[[:space:]]*$/ { next }
    END {
      for (i = n; i >= 1; i--) {
        h = head[i]
        own = (index(h, "- **" board "#" nn " ") == 1)
        same = (index(h, "- **" board "#") == 1)
        proj = (h ~ /^- \*\*[^*]*\*\* \([^)]*, project\)/)
        if (all == "all") keep = 1; else keep = (!own && (proj || same))
        if (!keep) continue
        size += length(body[i]) + 1
        if (all != "all" && size > max && shown) { cut = 1; break }
        print body[i]; shown++
      }
      if (cut) print "(older entries left out: the whole ledger is the file itself)"
    }' "$f"
}

# What the prompt's {{ANSWERS_LEDGER}} becomes, and what a resume note carries:
# empty when no entry bears on the ticket.
answers_ledger_block() {
  local entries f
  entries="$(answers_ledger_entries "$1" "$2")"
  [[ -n "$entries" ]] || return 0
  f="$(answers_ledger_file)"
  printf '## Answers already given\n\nWhat the developer answered to other agents in this repo, newest first, from `%s` in the main checkout. Before you ask a question, look here and in that file: one that is answered is not asked again. Use an answer that fits your ticket and say in your report that you did; where one plainly does not fit, ask, and say why the earlier answer does not apply.\n\n%s\n' "${f#"$ROOT"/}" "$entries"
}
