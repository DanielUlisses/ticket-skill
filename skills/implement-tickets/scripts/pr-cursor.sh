#!/usr/bin/env bash
# pr-cursor.sh — open a ticket's PR with the Cursor CLI writing the words.
#
# Opening a PR is writing a commit message and a PR body; it needs no Claude
# subscription. Cursor's agent (cursor-agent, headless: -p) gets everything in
# one prompt — the ticket, its report, the diff, the repo's PR template and the
# pr skill — and answers with JSON only: title, commit message, body, the paths
# to commit. It runs no command and writes no file; this script then hands its
# answer to pr-open.sh, the one guarded way a ticket's work is committed, pushed
# and opened as a PR (exactly the named paths, no force, attribution stripped).
# See docs/adr/0005-scratch-boards-retro-and-presales.md §9.
#
# Usage: pr-cursor.sh <board> <NN> [--push]
#   --push  commit and push only, no PR (tk.sh push, for TICKET_FORGE=none): Cursor
#           writes the commit message and picks the paths; pr-open.sh push does the
#           rest. Always the Cursor CLI — TICKET_PR_RUNNER doesn't apply.
#
# Optional variables (also read from ticket-models.env):
#   TICKET_PR_RUNNER        cursor (default) | claude — claude makes tk.sh pr exit 5, and the
#                           board dispatches the ticket-pr-creator agent instead
#   TICKET_CURSOR_BIN       the Cursor CLI (default: cursor-agent, else agent)
#   TICKET_PR_CURSOR_MODEL  passed as --model (default: Cursor's own default)
#   TICKET_CURSOR_ARGS      extra arguments for the Cursor CLI, word-split
#   TICKET_CURSOR_TIMEOUT   seconds (default 300)
#
# Exit codes: 0 opened (or pushed) | 1 error or refused
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${TICKET_LIB_DIR:-}" ]]; then LIB_DIR="$TICKET_LIB_DIR"; else
  for d in "$(dirname "$SKILL_DIR")" "$(dirname "$(dirname "$SKILL_DIR")")/lib"; do
    [[ -f "$d/ticket-git-repo.sh" ]] && { LIB_DIR="$d"; break; }
  done
fi
[[ -f "${LIB_DIR:-}/ticket-git-repo.sh" ]] || { echo "ERROR: ticket-git-repo.sh not found — re-run install.sh, or set TICKET_LIB_DIR" >&2; exit 1; }
# shellcheck source=/dev/null
source "$LIB_DIR/ticket-git-repo.sh"
# shellcheck source=/dev/null
source "$SKILL_DIR/scripts/board-lib.sh"

load_models_env
board="${1:-}"; nn="${2:-}"; PUSH=0
[[ "${3:-}" == --push ]] && PUSH=1
[[ -n "$nn" && ( -z "${3:-}" || "$PUSH" == 1 ) ]] || { sed -n '2,27p' "$0"; exit 1; }
PR_OPEN="$SKILL_DIR/scripts/pr-open.sh"

# Refusals (agent working, PR already open, nothing changed, wrong repo) end here.
if (( PUSH )); then check="$("$PR_OPEN" check "$board" "$nn" --push)" || exit 1
else check="$("$PR_OPEN" check "$board" "$nn")" || exit 1; fi

# A push retried after a failed one has nothing left to commit: no words to write,
# so Cursor isn't asked — pr-open.sh push only pushes.
if (( PUSH )) && grep -qE '^[[:space:]]+\(none — only the commits above\)$' <<<"$check"; then
  echo "STEP checked — nothing uncommitted; pushing the commits already on the branch" >&2
  empty="$(mktemp)"; trap 'rm -f "$empty"' EXIT
  "$PR_OPEN" push "$board" "$nn" --paths-file "$empty"
  exit 0
fi

# The Cursor CLI: cursor-agent, or `agent` where it installed under that name.
CURSOR="${TICKET_CURSOR_BIN:-}"
if [[ -z "$CURSOR" ]]; then
  if command -v cursor-agent >/dev/null 2>&1; then CURSOR=cursor-agent
  elif command -v agent >/dev/null 2>&1 && agent --help 2>&1 | grep -i cursor >/dev/null; then CURSOR=agent
  elif (( PUSH )); then die "the Cursor CLI isn't installed — curl https://cursor.com/install -fsS | bash, then cursor-agent login (or set CURSOR_API_KEY). tk.sh push has no Claude fallback"
  else die "the Cursor CLI isn't installed — curl https://cursor.com/install -fsS | bash, then cursor-agent login (or set CURSOR_API_KEY). Or TICKET_PR_RUNNER=claude to open PRs with the Claude agent"; fi
fi

echo "STEP checked — asking Cursor ($CURSOR) for the commit message$( ((PUSH)) || echo " and PR body")" >&2

field() { sed -n "s/^$1 //p" <<<"$check" | head -1; }
WT="$(sed -n 's/^READY ticket [0-9]* on [^ ]* (base [^)]*) in //p' <<<"$check")"
BASE="$(sed -n 's/^READY ticket [0-9]* on [^ ]* (base \([^)]*\)).*/\1/p' <<<"$check")"
[[ -d "$WT" ]] || die "couldn't read the worktree from pr-open.sh check"
REMOTE="${TICKET_REMOTE:-origin}"

# Capped pieces, so the prompt stays one argument (Linux allows 128 KiB per argument).
# cap drains what it doesn't keep: head alone exits at the cap, the writer then dies
# of SIGPIPE, and under pipefail + set -e that 141 ends this script on any diff over
# the cap — before Cursor is ever asked.
cap() { local n="$1"; head -c "$n"; cat >/dev/null; echo; }
section() { printf '\n=== %s ===\n' "$1"; }
{
  if (( PUSH )); then
    cat <<'EOF'
You write the commit message for one finished ticket; its branch is pushed, with no pull request.
Run no command and change no file: answer with ONE JSON object and nothing else —
no prose, no code fence:

{"commit_message": "<subject line>\n\n<short body: what and why>",
 "paths": ["<every changed path that belongs to the ticket>"],
 "left_out": [{"path": "<changed path not committed>", "why": "<reason>"}]}

Rules:
- paths: only from CHANGED below; leave out build output, logs, editor files and anything under RISKY.
  If nothing in CHANGED belongs to the ticket (the work is already committed: see UNPUSHED), paths is [].
- commit_message: the repo's convention as RECENT COMMITS show it (conventional commits, a ticket
  prefix), else "<type>: <ticket title>". Name the PARENT id where there is one.
- Never add a Co-authored-by trailer, a "Generated with" line, or any tool or AI attribution.
EOF
  else
  cat <<'EOF'
You write the commit message and pull-request description for one finished ticket.
Run no command and change no file: answer with ONE JSON object and nothing else —
no prose, no code fence:

{"title": "<PR title, under 72 characters>",
 "commit_message": "<subject line>\n\n<short body: what and why>",
 "body": "<the PR description, Markdown>",
 "paths": ["<every changed path that belongs to the ticket>"],
 "left_out": [{"path": "<changed path not committed>", "why": "<reason>"}]}

Rules:
- paths: only from CHANGED below; leave out build output, logs, editor files and anything under RISKY.
  If CHANGED is empty (the work is already committed), paths is [].
- commit_message: the repo's convention as RECENT COMMITS show it (conventional commits, a ticket
  prefix), else "<type>: <ticket title>".
- body: follow the PR SKILL below where there is one; fit it into the PR TEMPLATE's headings where
  there is one; otherwise: summary, how it was verified, merge risk. Take verification only from
  the REPORT — never claim a check it doesn't show. Name the PARENT id and the ticket number.
- Never add a Co-authored-by trailer, a "Generated with" line, or any tool or AI attribution.
- On Azure DevOps (FORGE line): plain Markdown under 4000 characters, no "Closes #N".
EOF
  fi
  section "CHECK (pr-open.sh)"; cat <<<"$check"
  section "RECENT COMMITS"; git -C "$WT" log --oneline -10 2>/dev/null | cap 2000
  tf="$(field TICKET)"; [[ -f "$tf" ]] && { section "TICKET"; cap 12000 <"$tf"; }
  rf="$(field REPORT)"; [[ -f "$rf" ]] && { section "REPORT"; cap 16000 <"$rf"; }
  pt="$(field PR_TEMPLATE)"; [[ -f "$pt" ]] && { section "PR TEMPLATE"; cap 6000 <"$pt"; }
  # The pr skill: Cursor's own install first, else the one check found under ~/.claude.
  # A push opens no PR: check prints no PR_TEMPLATE, and the skill isn't looked for.
  if (( ! PUSH )); then
    ps="$(find "$HOME/.cursor" -path '*/pr/SKILL.md' 2>/dev/null | head -1 || true)"
    [[ -n "$ps" ]] || ps="$(field PR_SKILL)"
    [[ -f "$ps" ]] && { section "PR SKILL"; cap 12000 <"$ps"; }
  fi
  section "DIFF (committed on the branch, then uncommitted)"
  { git -C "$WT" diff "$REMOTE/$BASE...HEAD" 2>/dev/null; git -C "$WT" diff HEAD 2>/dev/null
    (cd "$WT" && git ls-files --others --exclude-standard -z 2>/dev/null \
      | xargs -0 -r -I{} sh -c 'printf "\n--- new file: %s\n" "$1"; head -c 4000 "$1"' _ {})
  } | cap 50000
} >"${PROMPT:=$(mktemp)}"
trap 'rm -f "$PROMPT"' EXIT

# --trust: headless, the CLI otherwise stops at its "trust this workspace?" prompt on
# a fresh ticket worktree, which no one is there to answer — the run hangs until the
# timeout. Cursor runs no command and writes no file here, so trusting it is safe.
args=(-p "$(cat "$PROMPT")" --output-format json --trust)
[[ -n "${TICKET_PR_CURSOR_MODEL:-}" ]] && args+=(--model "$TICKET_PR_CURSOR_MODEL")
# shellcheck disable=SC2206
[[ -n "${TICKET_CURSOR_ARGS:-}" ]] && args+=(${TICKET_CURSOR_ARGS})
rc=0
out="$(cd "$WT" && TICKET_NET_TIMEOUT="${TICKET_CURSOR_TIMEOUT:-300}" quiet_net "$CURSOR" "${args[@]}" 2>"$PROMPT.err")" || rc=$?
if (( rc != 0 )); then
  cat "$PROMPT.err" >&2; rm -f "$PROMPT.err"
  (( rc == 124 )) && die "the Cursor CLI timed out after ${TICKET_CURSOR_TIMEOUT:-300}s — run '$CURSOR -p hello' in a shell: it may need 'cursor-agent login'"
  die "the Cursor CLI failed (exit $rc) — nothing was committed"
fi
rm -f "$PROMPT.err"

# --output-format json wraps the reply as {"result": "<text>", ...}; the text is the JSON asked for,
# sometimes fenced. Take the first {...} that parses.
text="$(jq -r '.result // empty' <<<"$out" 2>/dev/null || true)"; [[ -n "$text" ]] || text="$out"
ans=""
if (( PUSH )); then want='type == "object" and (.commit_message | type == "string")'
else want='type == "object" and (.title | type == "string") and (.body | type == "string") and (.commit_message | type == "string")'; fi
for cand in "$text" "$(sed -e '/^```/d' <<<"$text")" "$(awk 'BEGIN{p=0} /\{/{p=1} p' <<<"$text" | sed -n '1,/^}[[:space:]]*$/p')"; do
  if jq -e "$want" <<<"$cand" >/dev/null 2>&1; then ans="$cand"; break; fi
done
[[ -n "$ans" ]] || { echo "$text" | head -40 >&2; die "Cursor didn't answer with the JSON asked for — nothing was committed"; }

d="$(mktemp -d)"; trap 'rm -rf "$d" "$PROMPT"' EXIT
jq -r .commit_message <<<"$ans" >"$d/msg"
jq -r '.paths // [] | .[]' <<<"$ans" >"$d/paths"
if (( PUSH )); then
  # No paths is fine when commits wait to be pushed (a push that failed, files rightly
  # left out beside them); with none waiting there is nothing to ship.
  if [[ -s "$d/paths" ]]; then
    echo "STEP Cursor answered — committing $(grep -c . "$d/paths" || true) path(s), pushing, no PR" >&2
    "$PR_OPEN" push "$board" "$nn" --message-file "$d/msg" --paths-file "$d/paths"
  else
    [[ "$(field UNPUSHED)" =~ ^[1-9][0-9]*$ ]] || { jq -r '(.left_out // [])[] | "LEFT OUT \(.path) — \(.why)"' <<<"$ans"; die "Cursor named no paths to commit and $REMOTE has every commit on the branch — nothing was committed"; }
    echo "STEP Cursor answered — nothing more to commit; pushing the $(field UNPUSHED) commit(s) already made, no PR" >&2
    "$PR_OPEN" push "$board" "$nn" --paths-file "$d/paths"
  fi
  jq -r '(.left_out // [])[] | "LEFT OUT \(.path) — \(.why)"' <<<"$ans"
  echo "WRITTEN BY Cursor ($CURSOR${TICKET_PR_CURSOR_MODEL:+, $TICKET_PR_CURSOR_MODEL})"
  exit 0
fi
jq -r .body <<<"$ans" >"$d/body"
echo "STEP Cursor answered — committing $(grep -c . "$d/paths" || true) path(s), pushing, opening the PR" >&2
"$PR_OPEN" open "$board" "$nn" --title "$(jq -r .title <<<"$ans")" \
  --message-file "$d/msg" --body-file "$d/body" --paths-file "$d/paths"
jq -r '(.left_out // [])[] | "LEFT OUT \(.path) — \(.why)"' <<<"$ans"
echo "WRITTEN BY Cursor ($CURSOR${TICKET_PR_CURSOR_MODEL:+, $TICKET_PR_CURSOR_MODEL})"
