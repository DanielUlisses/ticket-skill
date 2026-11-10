#!/usr/bin/env bash
# Shared launcher mechanics for /ticket — Herdr worktree, workspace layout, and
# the Claude Code agent that gets the ticket.
#
# Sourced, never executed. The mechanics live here and the launcher is
# parameters, not a fork; it sets these before calling launcher_main:
#
#   SKILL_DIR         the skill's own directory. Two things hang off it: the
#                     exit-3 hint, which tells the developer to re-run that
#                     skill's scripts/launch.sh, and the default location of
#                     ticket-models.env, one level up from it.
#   TEMPLATE          the prompt template to render
#   RUN_NAME          subdirectory of ${XDG_RUNTIME_DIR:-/tmp} the rendered
#                     prompt is written to
#   PERMISSION_MODE   --permission-mode the agent starts with
#   DISALLOWED_TOOLS  array of --disallowedTools patterns
#   DOC_TEMPLATE      the template a `--doc` launch renders instead — a board
#                     ticket whose deliverable is a document (`**Kind:** doc`),
#                     not code. ADR 0007.
#                     `--doc-type <ead|tdd|other>` (with `--doc`) fills the
#                     template's {{DOC_GUIDANCE}}: for ead/tdd, a pointer to the
#                     installed skill and its validator; for `other`, or a skill
#                     that isn't installed, nothing — the generic doc brief.
#   HELPER_TEMPLATE   the template a `--helper` launch renders instead — a
#                     ticket that is the developer's (`**Owner:** me`), opened
#                     with a helper session the developer drives. With `--doc`
#                     too, its review is the doc reviewer's. ADR 0009.
#   HELPER_PERMISSION_MODE  --permission-mode a helper session starts with
#
# `--resume` (tk.sh resume) starts a new agent on a ticket whose agent died —
# an OOM, a container restart — in the worktree it left, as it stands: no pull,
# no new branch, nothing reset. `--session <id>` resumes that Claude Code
# conversation (`claude --resume`) and sends only `--resume-note`; without one,
# or when its transcript isn't under the account the worktree resolves to, the
# agent gets the full brief with the note on top. `--expect-account` refuses to
# start under any account other than the one the ticket ran on.
#
# The session coordinates on TICKET_COORD_MODEL/EFFORT; only the
# ticket-implementer subagent gets the ticket's model and effort, since the plan
# is already settled. See docs/adr/0002-model-tiers-and-agent-roster.md.
#
# The caller sets PERMISSION_MODE after calling load_ticket_models, so a value in
# ticket-models.env still reaches it.
#
# Requires ticket-git-repo.sh (die/log/need, resolve_repo_root,
# resolve_base_branch, run_git_net) and ticket-account.sh (the claude-acc
# helpers) to have been sourced first, and the caller to be running under
# `set -euo pipefail`.
#
# Installed as ~/.claude/skills/ticket-launcher.sh, one level up from the skill
# directories — see ticket-git-repo.sh for why it can't live inside one.

# The rendering below substitutes arbitrary prose (a ticket body, a hand-written
# memory file) into the template with `${tpl//}`, and bash 5.2+ reads a `&` in a
# replacement as "the whole match" unless this option is off. Turned off here
# rather than in each caller, so a third launcher can't forget it.
shopt -u patsub_replacement 2>/dev/null || true

# Checks whether a herdr subcommand accepts a flag (via --help, doesn't execute anything)
has_flag() { local flag="$1"; shift; herdr "$@" --help 2>&1 | grep -qE -- "(^|[[:space:],])${flag}([[:space:],=]|$)"; }

# Runs a herdr command and prints its JSON response. Keeps stderr out of that
# JSON: on success herdr writes only the response to stdout, and on failure only
# an {"error":{"message":...}} object to stderr — so a failure here reports
# Herdr's own message rather than a guess about what went wrong. Every caller
# reads the response with jq, so an unparseable one dies here too, as `die`
# (exit 1) rather than letting jq abort the script with its own status, which
# the skills' exit-code contract doesn't cover.
herdr_json() {
  local what="$1"; shift
  local err out rc msg
  err="$(mktemp "${TMPDIR:-/tmp}/ticket-herdr.XXXXXX")"
  set +e
  out="$(herdr "$@" 2>"$err")"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    msg="$(jq -r '.error.message // empty' <"$err" 2>/dev/null || true)"
    [[ -n "$msg" ]] || msg="$(cat "$err")"
    rm -f "$err"
    die "$what failed: ${msg:-exit $rc with no output}"
  fi
  rm -f "$err"
  jq -e . >/dev/null 2>&1 <<<"$out" || die "$what returned unparseable output: $out"
  printf '%s' "$out"
}

# Appends a tab to the worktree's workspace and sets CREATED_TAB to its id and
# CREATED_PANE to the pane that came with it.
# It sets globals instead of printing because a `die` inside a command
# substitution only exits that subshell: called as `t="$(create_tab x)"`, a
# failed `herdr tab create` would report Herdr's message and then carry on to
# report a second, empty-JSON error on top of it.
#
# CREATED_PANE may come back empty — only the account-override path needs it, and
# that caller says so itself rather than failing the two tabs that don't.
create_tab() {
  local label="$1" cmd json
  cmd=(tab create --workspace "$WORKSPACE_ID" --cwd "$WT" --label "$label")
  has_flag --no-focus tab create && cmd+=(--no-focus)
  json="$(herdr_json "herdr tab create ($label)" "${cmd[@]}")"
  CREATED_TAB="$(jq -r '.result.tab.tab_id // .result.tab.id // empty' <<<"$json")"
  [[ -n "$CREATED_TAB" ]] || die "couldn't read the '$label' tab from the response: $json"
  CREATED_PANE="$(jq -r '
    .result.root_pane.pane_id // .result.root_pane.id
    // .result.pane.pane_id // .result.pane.id
    // .result.tab.root_pane.pane_id // .result.tab.root_pane.id
    // (.result.tab.panes[0] | (.pane_id // .id))
    // empty' <<<"$json" 2>/dev/null || true)"
}

# Splits the agent's pane to the right with a shell in the worktree, and sets
# SHELL_PANE. A global, not printed, for create_tab's reason. The pane is made
# after the account link, so its shell resolves the ticket's account either way.
split_shell_pane() {
  local cmd json
  log "splitting a 'shell' pane to the right of the agent"
  cmd=(pane split --pane "$AGENT_PANE" --direction right --cwd "$WT")
  has_flag --no-focus pane split && cmd+=(--no-focus)
  json="$(herdr_json "herdr pane split (shell)" "${cmd[@]}")"
  SHELL_PANE="$(jq -r '.result.pane.pane_id // .result.pane.id // empty' <<<"$json")"
  [[ -n "$SHELL_PANE" ]] || die "couldn't read the shell pane from the response: $json"
  herdr pane rename "$SHELL_PANE" shell >/dev/null 2>&1 || true
}

# Waits up to REVIEWR_WAIT seconds for the reviewr plugin's auto-opened pane and
# closes it, setting REVIEW_SOURCE to what happened. Both Herdr events open it
# (`worktree.created` on a launch, `worktree.opened` on a resume), so both paths
# call this before they split the shell off the agent.
close_reviewr_pane() {
  local pane="" deadline
  if [[ "$REVIEWR_WAIT" -gt 0 ]] && should_wait_for_reviewr; then
    log "waiting up to ${REVIEWR_WAIT}s for the reviewr plugin's pane, to close it"
    # A wall-clock deadline, not an iteration count: each probe costs a `pane
    # list` plus a `process-info` per pane, so counting iterations would overrun
    # the seconds the variable promises.
    deadline=$((SECONDS + REVIEWR_WAIT))
    while :; do
      pane="$(reviewr_pane)"
      [[ -n "$pane" ]] && break
      (( SECONDS < deadline )) || break
      sleep 0.1
    done
  fi
  if [[ -z "$pane" ]]; then
    REVIEW_SOURCE="none (no reviewr pane appeared; run 'review' or 'herdr-reviewr' in the shell pane for one)"
  elif herdr pane close "$pane" >/dev/null 2>&1; then
    log "closed the reviewr pane $pane (run 'review' or 'herdr-reviewr' in the shell pane to bring it back)"
    REVIEW_SOURCE="closed reviewr pane $pane (run 'review' or 'herdr-reviewr' in the shell pane to reopen)"
  else
    log "warning: couldn't close the reviewr pane $pane; it stays beside the agent"
    REVIEW_SOURCE="reviewr pane $pane (left open: herdr pane close refused)"
  fi
}

# Whether to wait for the reviewr plugin's pane at all — only to skip a wait
# that could not pay off, when no enabled reviewr is there to open one (or its
# config turns auto_open off). A listing that can't be read or parsed (older
# herdr without `--json`, say) waits anyway: missing reviewr's pane costs more than the wait does.
should_wait_for_reviewr() {
  local list conf="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/persiyanov.reviewr/config.toml"
  # `auto_open = false` in the plugin's own config: it opens nothing to wait for.
  grep -qE '^[[:space:]]*auto_open[[:space:]]*=[[:space:]]*false' "$conf" 2>/dev/null && return 1
  list="$(herdr plugin list --json 2>/dev/null)" || return 0
  jq -e '.result.plugins[]? | select(.plugin_id == "persiyanov.reviewr" and .enabled)' \
    >/dev/null 2>&1 <<<"$list" && return 0
  jq -e '.result.plugins' >/dev/null 2>&1 <<<"$list" && return 1
  return 0
}

# The workspace's reviewr pane, or nothing. Identified by its foreground
# process, the way the plugin identifies its own panes: the `reviewr` pane label
# is a display-only, rewritable title and never what decides. The agent's own
# pane is excluded, so this can only ever name a pane the plugin opened.
reviewr_pane() {
  local panes p
  panes="$(herdr pane list --workspace "$WORKSPACE_ID" 2>/dev/null \
    | jq -r '.result.panes[].pane_id // empty' 2>/dev/null)" || return 0
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "$AGENT_PANE" ]] || continue
    herdr pane process-info --pane "$p" 2>/dev/null | jq -e '
        def base: split("/") | last;
        any(.result.process_info.foreground_processes[];
            ((((.argv0 // "") | base) == "herdr-reviewr")
              or ((((.argv // [])[0] // "") | base) == "herdr-reviewr"))
            and (((.argv // []) | index("--resolve-plugin-config")) == null))' >/dev/null 2>&1 \
      && { printf '%s' "$p"; return 0; }
  done <<<"$panes"
  return 0
}

send_prompt() {
  local agent="$1" file="$2"
  [[ -s "$file" ]] || die "empty prompt file: $file"
  herdr agent prompt "$agent" "$(cat "$file")" >/dev/null \
    || die "failed to send the prompt to '$agent' (check with: herdr agent read $agent --source recent-unwrapped --lines 60)"
  log "prompt sent to '$agent'"
}

# Takes the placeholder and its value as arguments, but reads and mutates the
# global `tpl` — the template being rendered — which must already be set.
#
# Substitutes EVERY occurrence of a placeholder in $tpl (which it mutates), the
# same as a `${tpl//}` — but without ever rescanning what it just put there. The
# two payloads it is used for are arbitrary prose: a ticket body, and a memory
# file the developer wrote by hand. Either may legitimately contain a `{{...}}`
# token — this very repo's tickets do — and a plain `${tpl//}` would then chew on
# it, or substitute one payload into the other. Walking the template instead
# means each payload lands exactly once, verbatim.
#
# An empty value also takes the blank line that follows its placeholder, so a
# repo with no project memory renders byte-for-byte the prompt it rendered before
# any of this existed.
fill_prose() {
  local ph="$1" val="$2" out="" rest="$tpl" blank=$'\n\n'
  while [[ "$rest" == *"$ph"* ]]; do
    out+="${rest%%"$ph"*}$val"
    rest="${rest#*"$ph"}"
    [[ -n "$val" ]] || rest="${rest#"$blank"}"
  done
  tpl="$out$rest"
}

# ---- Remote Control -----------------------------------------------------------------
# Whether the agent starts with `claude --remote-control <name>`, so its
# session opens in the Claude app (tk-hub's Sessions page links it, read from the pane).
# TICKET_REMOTE_CONTROL=1|0 wins; else the box policy's `remote_control_tickets`
# (true|false, ${TICKET_BOX_POLICY:-~/.config/tk-daemon/policy.json}, which devboxes writes
# per client; its `remote_control` is for the daemon's grills and coworkers, since a ticket
# agent's chat is tk-hub's Sessions page); else off.
# Sets REMOTE_CONTROL (0|1), RC_ORIGIN (env|box|default) and RC_ARGS. Needs AGENT.
resolve_remote_control() {
  local v="${TICKET_REMOTE_CONTROL:-}" f
  RC_ORIGIN="env"
  if [[ -z "$v" ]]; then
    f="${TICKET_BOX_POLICY:-$HOME/.config/tk-daemon/policy.json}"
    RC_ORIGIN="box"
    [[ -s "$f" ]] && v="$(jq -r 'if type == "object" and (.remote_control_tickets | type) == "boolean"
                                 then (if .remote_control_tickets then 1 else 0 end) else empty end' "$f" 2>/dev/null || true)"
  fi
  [[ -n "$v" ]] || { v=0; RC_ORIGIN=default; }
  case "$v" in
    1|true|on|yes) REMOTE_CONTROL=1 ;;
    0|false|off|no) REMOTE_CONTROL=0 ;;
    *) die "TICKET_REMOTE_CONTROL is '$v' — 1 or 0" ;;
  esac
  RC_ARGS=()
  (( REMOTE_CONTROL )) && RC_ARGS=(--remote-control "$(hostname -s 2>/dev/null || hostname)/$AGENT")
  return 0
}

# ---- catalog skills ---------------------------------------------------------------
# The skills-catalog skills this ticket gets (docs/agents/skills.md): devboxes syncs
# the catalog to ${TICKET_SKILLS_CATALOG:-/opt/skills}/<name>/ (never into
# ~/.claude/skills, so nothing is on by default), and a board enables some with its
# policy's `skills` list. `tk.sh launch` passes the board's resolved list as
# --skills; a launch with no board (/ticket, /small-ticket) reads the box and repo
# policy layers itself. Each name is linked into the worktree's .claude/skills/
# and excluded from git, so the agent sees it as a project skill and nothing is
# committed. A name the catalog doesn't hold is skipped and said, never fatal: the
# ticket runs without it.
# Sets SKILLS_WANTED (array), SKILLS_ORIGIN (board|policy|none) and CATALOG_DIR.
resolve_catalog_skills() {
  local raw="" f layer
  CATALOG_DIR="${TICKET_SKILLS_CATALOG:-/opt/skills}"
  SKILLS_WANTED=()
  if [[ -n "${SKILLS_REQUESTED+x}" ]]; then
    raw="$SKILLS_REQUESTED"; SKILLS_ORIGIN="board"
  else
    SKILLS_ORIGIN="policy"
    for f in "${TICKET_BOX_POLICY:-$HOME/.config/tk-daemon/policy.json}" "$ROOT/.scratch/policy.json"; do
      [[ -s "$f" ]] || continue
      # Later layer wins, an empty list included (the repo turning the box's off).
      layer="$(jq -er 'if type == "object" and (.skills | type) == "array"
                       then .skills | map(tostring) | join(",") else error("no skills") end' "$f" 2>/dev/null)" \
        && raw="$layer"
    done
  fi
  local name names=()
  IFS=',' read -r -a names <<<"$raw"
  for name in ${names[@]+"${names[@]}"}; do
    name="${name//[[:space:]]/}"
    [[ -n "$name" ]] || continue
    [[ "$name" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ && "$name" != *..* ]] \
      || die "invalid skill name '$name' in the policy's skills — lowercase letters, digits, . _ -"
    [[ " ${SKILLS_WANTED[*]-} " == *" $name "* ]] || SKILLS_WANTED+=("$name")
  done
  (( ${#SKILLS_WANTED[@]} )) || SKILLS_ORIGIN="none"
  SKILLS_LINKED=(); SKILLS_MISSING=()
  for name in ${SKILLS_WANTED[@]+"${SKILLS_WANTED[@]}"}; do
    if [[ -f "$CATALOG_DIR/$name/SKILL.md" ]]; then SKILLS_LINKED+=("$name"); else SKILLS_MISSING+=("$name"); fi
  done
  return 0
}

# Links SKILLS_LINKED into $WT/.claude/skills/<name> (a symlink to the catalog's
# copy) and adds each to the repo's info/exclude, shared by every worktree. A path
# the repo already has there (a skill it ships itself) is left alone: the repo's
# own wins. Rewrites SKILLS_LINKED to what was actually linked.
link_catalog_skills() {
  (( ${#SKILLS_LINKED[@]} )) || return 0
  local name dest exclude kept=()
  exclude="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "$WT/.claude/skills" "$(dirname "$exclude")"
  for name in "${SKILLS_LINKED[@]}"; do
    dest="$WT/.claude/skills/$name"
    if [[ -e "$dest" || -L "$dest" ]]; then
      log "skill '$name': the repo has its own .claude/skills/$name — keeping it, not the catalog's"
      SKILLS_MISSING+=("$name(repo's own)")
      continue
    fi
    ln -s "$CATALOG_DIR/$name" "$dest"
    grep -qxF "/.claude/skills/$name" "$exclude" 2>/dev/null || printf '/.claude/skills/%s\n' "$name" >>"$exclude"
    kept+=("$name")
  done
  SKILLS_LINKED=(${kept[@]+"${kept[@]}"})
  log "catalog skills linked: ${SKILLS_LINKED[*]:-none}"
}

# The summary's SKILLS= line: the linked names (comma-separated, `none`), then why.
skills_summary() {
  local linked="none"
  (( ${#SKILLS_LINKED[@]} )) && linked="$(IFS=,; echo "${SKILLS_LINKED[*]}")"
  printf '%s (%s' "$linked" "$SKILLS_ORIGIN"
  (( ${#SKILLS_MISSING[@]} )) && printf '; not in %s: %s' "$CATALOG_DIR" "${SKILLS_MISSING[*]}"
  printf ')'
}

# ---- per-repo project memory ------------------------------------------------
# Sets MEMORY_BLOCK (what the prompt's {{PROJECT_MEMORY}} becomes) and
# MEMORY_STATUS (the summary's PROJECT_MEMORY= line).
#
# Read from $ROOT, the MAIN checkout, never from the worktree. The file is
# .scratch/project-memory.md: gitignored, never committed, so memory is never written
# inside tracked code (ADR 0006). There is no merge gate any more; the developer gate
# is the approval in `tk.sh retro-apply` / the hub's memory ticket. It sits where
# /sweep-tickets can never take it, since that skill removes worktrees and branches
# and leaves the main checkout's .scratch alone.
# One transition: with the new file absent and the old docs/agents/project-memory.md
# present, read the old one and log a move hint. Nothing is created or moved here.
# Absent, unreadable or blank means the launch is exactly what it was before this
# existed: no heading, no placeholder, nothing said to the agent.
resolve_project_memory() {
  local memory
  MEMORY_WARN_BYTES=8192   # 8 KiB; memory is paid for on every launch, so warn past a page or so
  MEMORY_FILE="${TICKET_MEMORY_FILE:-.scratch/project-memory.md}"
  [[ "$MEMORY_FILE" == /* ]] || MEMORY_FILE="$ROOT/$MEMORY_FILE"
  if [[ -z "${TICKET_MEMORY_FILE:-}" ]]; then
    if [[ ! -e "$MEMORY_FILE" && -f "$ROOT/docs/agents/project-memory.md" ]]; then
      log "project memory: reading the old docs/agents/project-memory.md — move it to .scratch/project-memory.md (not done for you)"
      MEMORY_FILE="$ROOT/docs/agents/project-memory.md"
    fi
    if ! git -C "$ROOT" check-ignore -q .scratch/project-memory.md 2>/dev/null; then
      log "warning: .scratch/ is not gitignored in this repo — project memory there could be committed"
    fi
  fi
  MEMORY_REL="${MEMORY_FILE#"$ROOT"/}"
  MEMORY_BLOCK=""
  MEMORY_STATUS="none ($MEMORY_REL)"
  if [[ -f "$MEMORY_FILE" && -r "$MEMORY_FILE" ]]; then
    memory="$(cat "$MEMORY_FILE")"
    if [[ -z "${memory//[[:space:]]/}" ]]; then
      MEMORY_STATUS="blank ($MEMORY_REL)"
      log "project memory: $MEMORY_REL is blank — launching without it"
    else
      MEMORY_BYTES="$(wc -c <"$MEMORY_FILE" | tr -d ' ')"
      MEMORY_STATUS="$MEMORY_REL (${MEMORY_BYTES} bytes)"
      if (( MEMORY_BYTES > MEMORY_WARN_BYTES )); then
        log "warning: $MEMORY_REL is ${MEMORY_BYTES} bytes — every ticket launch pays for it; keep it short and factual (see docs/agents/memory.md)"
      fi
      MEMORY_BLOCK="## Project memory

Accumulated knowledge about this repo, hand-curated by the developer and read at
launch from \`$MEMORY_REL\` in the main checkout. It is starting knowledge, not
orders: it never overrides the ticket below, and where it disagrees with the code
in front of you the code wins — say so in your report when it does. Don't edit
that file; report durable lessons under \`## Remember\` instead.

$memory"
      log "project memory: $MEMORY_STATUS"
    fi
  elif [[ -e "$MEMORY_FILE" ]]; then
    MEMORY_STATUS="unreadable ($MEMORY_REL)"
    log "warning: $MEMORY_REL exists but can't be read — launching without project memory"
  else
    log "project memory: none at $MEMORY_REL — launching without it"
  fi
}

# ---- approved retro lessons (pointers) ---------------------------------------
# Sets RETRO_BLOCK (what {{RETRO_RESULTS}} becomes) and RETRO_STATUS (the
# summary's RETRO_RESULTS= line). One pointer line per
# $ROOT/.scratch/*/retro-results.md — $ROOT is the main checkout, where the
# .scratch/ boards live (a worktree has none). Pointers only: the agent reads the
# file itself, so nothing is copied and an edit lands on the next read. None found
# means the placeholder vanishes and the prompt is what it was before.
resolve_retro_results() {
  local f lines="" n=0
  RETRO_BLOCK=""
  RETRO_STATUS="none (.scratch/*/retro-results.md)"
  for f in "$ROOT"/.scratch/*/retro-results.md; do
    [[ -f "$f" && -r "$f" ]] || continue
    lines+="- \`$f\`"$'\n'
    n=$((n + 1))
  done
  if (( n == 0 )); then
    log "retro results: none under $ROOT/.scratch/*/ — launching without them"
    return 0
  fi
  RETRO_STATUS="$n file(s)"
  RETRO_BLOCK="## Retro results

Lessons the developer approved from past retros live in the file(s) below. Read
each one if it exists; follow approved items that bear on your work; never edit
them.

${lines%$'\n'}"
  log "retro results: $RETRO_STATUS"
}

# ---- a document ticket's type ------------------------------------------------
# The doc types a `--doc-type` may name. One list, so the check and the message
# that names the valid values can't drift apart.
DOC_TYPES="ead tdd other"

# Sets DOC_GUIDANCE_BLOCK (what {{DOC_GUIDANCE}} becomes) and KIND_STATUS (the
# summary's KIND= line). `ead` and `tdd` are skills of their own, installed
# beside this one: the brief points the drafter at the skill and its validator.
# A skill counts as installed only with both its SKILL.md and its
# scripts/check_<type>.py — a directory of the same name holding some other
# skill (mattpocock's `tdd` is test-driven development, not a design document)
# would otherwise send the drafter to the wrong rules. Missing means one WARN
# line and the generic brief, never a refusal: the generic brief still writes
# the document. TICKET_SKILLS_DIR overrides where to look.
resolve_doc_guidance() {
  DOC_GUIDANCE_BLOCK=""
  if (( ! ${DOC:-0} )); then KIND_STATUS="code"; return 0; fi
  if [[ -z "$DOC_TYPE" ]]; then KIND_STATUS="doc"; return 0; fi
  KIND_STATUS="doc $DOC_TYPE"
  [[ "$DOC_TYPE" == other ]] && return 0
  local dir="${TICKET_SKILLS_DIR:-$HOME/.claude/skills}/$DOC_TYPE"
  local check="$dir/scripts/check_${DOC_TYPE}.py"
  if [[ ! -f "$dir/SKILL.md" || ! -f "$check" ]]; then
    echo "WARN doc type '$DOC_TYPE': the $DOC_TYPE skill isn't installed (no SKILL.md and scripts/check_${DOC_TYPE}.py under $dir) — launching with the generic doc brief" >&2
    KIND_STATUS="doc $DOC_TYPE (skill missing — generic brief)"
    return 0
  fi
  DOC_GUIDANCE_BLOCK="## Document type: \`$DOC_TYPE\`

The ticket's doc type is **$DOC_TYPE**, and the \`$DOC_TYPE\` skill is installed at
\`$dir\`. Its rules are the house rules for this document:

- Tell \`ticket-implementer\` to call the Skill tool with \`$DOC_TYPE\` before it
  writes a line, and to follow it for structure, sections, wording rules and
  estimates. The ticket's \`## Outline\` still decides what is in scope; where the
  skill and the outline disagree, the outline wins and the hand-off says so.
  Where the skill would stop to ask the user something, the unattended rule
  above applies instead: a marked assumption, listed in the hand-off.
- Its validator is \`$check\` — the skill's SKILL.md says how to call it. The
  implementer runs it before handing back; the Phase 4 tester runs it again,
  alongside whatever the ticket's **Seams under test** line names; the reviewer
  gets its output.
- Pass the reviewer the skill's path too, so it can check the document against
  the skill's own section rules."
}

# ---- mise trust ---------------------------------------------------------------
# A ticket's worktree is a brand-new directory, and a path mise has never seen is
# an untrusted one — so in a repo with a mise config the pane's `mise` either
# asks to trust it or refuses to read it outright, and the agent starts against a
# shell with none of the repo's toolchain on PATH. Best-effort by design: a
# failure logs and the launch carries on. `launcher.md` has the history, the
# trade-offs, and what this deliberately does not reach; three things need saying
# here because they are what the code below is shaped by.
#
# `mise trust --show` is the detector, not a list of config filenames this repo
# would have to keep in step by hand. It changes nothing, prints one
# `<dir>: trusted|untrusted` line per config directory in the chain to stdout,
# and sees exactly what the agent's pane will see.
#
# It walks parents too, so the worktree's *own* line is what is matched — every
# worktree here is cut as a sibling of the main checkout, and one mise config
# above `<parent>/` would otherwise make every repo on the machine look like a
# mise repo. The match is against the resolved path, because mise canonicalises
# what `-C` gives it and a `$WT` with a symlinked component prints as its real
# path.
#
# `-C <dir>` and never a config-file argument: mise resolves a trust argument to
# a trust root lexically, and a path that isn't there acts on its parent
# directory instead — here, the directory holding every worktree and the main
# checkout. That is also why this runs after the worktree has been verified onto
# disk and not a line before it.
trust_worktree_mise() {
  # With the agent user on, the developer never trusts a worktree's mise config:
  # the agent writes it, and a trusted one runs as whoever's shell loads it. The
  # wrapper trusts it in the agent's own trust store instead.
  if agent_on; then log "agent user: mise trust left to $TKA_USER's own store (the wrapper)"; return 0; fi
  local wt_real shown out rc
  command -v mise >/dev/null 2>&1 || return 0

  wt_real="$(readlink -f "$WT" 2>/dev/null || true)"
  [[ -n "$wt_real" ]] || wt_real="$WT"

  # Read whole, then match — the rule account_pane_config_dir states, for the
  # same reason. A `grep -q` on the far end of a pipeline can exit before mise
  # has finished writing, and the SIGPIPE that follows reaches the caller's
  # `pipefail` as 141, which a `|| return 0` would swallow as "nothing to do".
  # Silently skipping the trust is the one failure this function must not have.
  #
  # </dev/null on both calls: a mise that decides to ask something must not be
  # able to park the launcher at a prompt, which is the failure being fixed.
  set +e
  shown="$(mise trust --show -C "$WT" 2>/dev/null </dev/null)"
  rc=$?
  set -e
  # An empty listing is a real answer (no mise config here) and rc is still 0, so
  # only a non-zero rc is a failure — and it is reported rather than read as
  # "doesn't apply", which would be this function going quiet in exactly the repo
  # that needed it.
  if [[ $rc -ne 0 ]]; then
    log "warning: 'mise trust --show' failed in $WT (exit $rc) — can't tell whether this repo has a mise config to trust, so the agent's pane may stop at a trust prompt or run without the repo's toolchain on PATH. Check by hand with: mise trust --show -C $WT"
    return 0
  fi
  grep -qxF "$wt_real: untrusted" <<<"$shown" || return 0

  log "trusting the worktree's mise config (mise trust -C $WT)"
  set +e
  out="$(mise trust --yes -C "$WT" 2>&1 </dev/null)"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] \
    || log "warning: 'mise trust' failed in $WT (exit $rc) — the agent's pane may stop at a trust prompt or run without the repo's toolchain on PATH; trust it by hand with 'mise trust -C $WT'. mise said: ${out:-nothing}"
}

# ---- the account this ticket runs on ----------------------------------------
# Three steps, in this order: check the requested account before anything is
# created, write the link once the worktree exists, and read back what the agent
# actually started under. Sets ACCOUNT_NAME, ACCOUNT_CONFIG_DIR, ACCOUNT_ORIGIN
# (`linked` or `inherited`) and ACCOUNT_STATUS, which together are the summary's
# ACCOUNT= line. See docs/agents/accounts.md.

# Called before the worktree exists, so a name nobody can link to costs nothing.
# `claude-acc link` validates the name too, but by then there is a worktree and a
# workspace to clean up after.
check_ticket_account() {
  [[ -n "$ACCOUNT_REQUESTED" ]] || return 0
  account_name_valid "$ACCOUNT_REQUESTED" \
    || die "invalid account '$ACCOUNT_REQUESTED' — an account name as 'claude-acc list' prints it, or 'default' for the standard ~/.claude"
  need claude-acc
  account_exists "$ACCOUNT_REQUESTED" \
    || die "no Claude account named '$ACCOUNT_REQUESTED' — see: claude-acc list"

  # An account is a whole Claude config root, and Claude Code reads *that* root's
  # skills/ and agents/, not ~/.claude's. A ticket launched on an account this
  # repo was never installed into starts an agent whose ticket-implementer,
  # ticket-reviewer and ticket-tester subagents simply aren't there unless this
  # launch's --agents definition supplies them. A warning rather than a refusal;
  # install.sh takes the root as its argument, so name it.
  ACCOUNT_ROOT="$(account_root_for "$ACCOUNT_REQUESTED")"
  [[ -f "$ACCOUNT_ROOT/agents/ticket-implementer.md" ]] \
    || log "warning: '$ACCOUNT_REQUESTED' has no agents/ticket-implementer.md under $ACCOUNT_ROOT — this repo was never installed into that account's config root, so a ticket launched there finds none of its skills or agents installed. Fix with: ./install.sh $ACCOUNT_ROOT"
}

# Writes the link (only when one was asked for) and resolves what the worktree
# now points at. Runs after the worktree exists and before the agent's pane is
# created, because a pane resolves its account once, when its shell starts.
link_ticket_account() {
  ACCOUNT_ORIGIN="inherited"
  ACCOUNT_CONFIG_DIR=""
  ACCOUNT_NAME="unknown"
  ACCOUNT_STATUS="unverified (claude-acc not installed)"

  if ! have_claude_acc; then
    # No switcher, no accounts, nothing to say — and nothing changed about the
    # launch. A request for one was already refused by check_ticket_account.
    log "account: claude-acc not installed — launching as before"
    return 0
  fi

  local rc=0 swept="the worktree and its workspace were created; remove them with /sweep-tickets"
  if [[ -n "$ACCOUNT_REQUESTED" ]]; then
    log "linking $WT to the '$ACCOUNT_REQUESTED' account"
    with_links_lock account_link "$WT" "$ACCOUNT_REQUESTED" || rc=$?
    if [[ $rc -eq $ACCOUNT_LOCK_UNAVAILABLE ]]; then
      die "couldn't take the lock on $ACCOUNT_LINKS_LOCK within ${ACCOUNT_LOCK_WAIT}s (or flock is missing) — refusing to write $ACCOUNT_LINKS_FILE unserialised, because concurrent writers lose entries, the developer's own among them. $swept"
    elif [[ $rc -ne 0 ]]; then
      die "claude-acc link '$ACCOUNT_REQUESTED' failed in $WT — $swept"
    fi
    ACCOUNT_ORIGIN="linked"
  fi

  ACCOUNT_CONFIG_DIR="$(account_config_dir "$WT")" \
    || die "couldn't resolve the Claude account for $WT (claude-acc activate failed there)"
  ACCOUNT_NAME="$(account_name_for "$ACCOUNT_CONFIG_DIR")"

  # The link is written and read back through two different claude-acc commands,
  # so this is the one place the answer can be checked against the question. The
  # verification after start compares the pane against ACCOUNT_CONFIG_DIR, and
  # both sides of that comparison come from here — so a link that landed
  # somewhere other than where it was aimed would agree with itself all the way
  # through and still be the wrong account.
  [[ "$ACCOUNT_ORIGIN" != "linked" || "$ACCOUNT_NAME" == "$ACCOUNT_REQUESTED" ]] \
    || die "asked for the '$ACCOUNT_REQUESTED' account, but $WT resolves to '$ACCOUNT_NAME' (${ACCOUNT_CONFIG_DIR:-the standard ~/.claude}) — the link didn't land where it was aimed. Check 'claude-acc links'. $swept"

  ACCOUNT_STATUS="unverified"
  log "account: $ACCOUNT_NAME ($ACCOUNT_ORIGIN, ${ACCOUNT_CONFIG_DIR:-~/.claude})"
}

# Reads back what the agent's process actually got, and refuses to hand it the
# ticket unless that is the account the worktree resolves to.
#
# A mismatch is the dangerous failure this whole feature exists to prevent: the
# agent runs, bills a subscription nobody chose, and nothing says so. It dies
# here, before the prompt is sent, so the wrong account pays for a startup and
# not for a ticket.
#
# Being unable to read the environment at all is treated differently on the two
# paths, and deliberately: an overriding launch asked for a specific account, and
# an unconfirmed answer is exactly the silence this guards against, so it dies.
# An inheriting launch asked for nothing and wrote nothing — it is the launch
# this repo has always done — so it says UNVERIFIED loudly in the summary and
# carries on.
verify_ticket_account() {
  local actual rc
  if agent_on; then verify_agent_user; return 0; fi
  have_claude_acc || return 0

  set +e
  actual="$(account_pane_config_dir "$AGENT_PANE")"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    local why
    case $rc in
      1) why="no started process appeared in pane $AGENT_PANE within ${ACCOUNT_VERIFY_WAIT}s" ;;
      *) why="can't read /proc/<pid>/environ for the process in pane $AGENT_PANE" ;;
    esac
    [[ "$ACCOUNT_ORIGIN" != "linked" ]] \
      || die "started '$AGENT' but couldn't confirm it is on the '$ACCOUNT_REQUESTED' account — $why. Not sending the ticket: an unconfirmed override is what this check exists to catch. Remove the workspace with /sweep-tickets and try again."
    ACCOUNT_STATUS="UNVERIFIED ($why)"
    log "warning: account UNVERIFIED — $why. The agent may be on an account other than '$ACCOUNT_NAME'."
    return 0
  fi

  if [[ "$actual" != "$ACCOUNT_CONFIG_DIR" ]]; then
    die "account mismatch: $WT resolves to ${ACCOUNT_CONFIG_DIR:-<unset, the standard ~/.claude>} but '$AGENT' started under ${actual:-<unset, the standard ~/.claude>}. Not sending the ticket. The pane's shell didn't pick up the directory link (check 'claude-acc links' and that ~/.bashrc still evals 'claude-acc init bash'); remove the workspace with /sweep-tickets and try again."
  fi
  ACCOUNT_STATUS="verified in pane $AGENT_PANE"
  log "account verified: '$AGENT' is running under ${actual:-the standard ~/.claude}"
}

# With the agent user on, the pane's foreground job is sudo (root's, so its
# environment can't be read) and the agent's claude runs under it as TKA_USER.
# What is checked is that: a process of TKA_USER's in the pane's process tree.
# Its config root follows from the account by the wrapper's own rule
# (agent_config_dir_for), so that is what ACCOUNT= reports. Nothing found dies
# whatever the account: a `claude` that started as the developer (the shim not
# on the pane's PATH) is the fallback this switch exists to prevent.
verify_agent_user() {
  local deadline info pids p found="" tree
  deadline=$((SECONDS + ${ACCOUNT_VERIFY_WAIT:-5}))
  while :; do
    info="$(herdr pane process-info --pane "$AGENT_PANE" 2>/dev/null || true)"
    pids="$(jq -r '.result.process_info.foreground_processes[]?.pid // empty' <<<"$info" 2>/dev/null || true)"
    tree="$(ps -e -o pid=,ppid=,user= 2>/dev/null || true)"
    for p in $pids; do
      found="$(awk -v root="$p" -v u="$TKA_USER" '
        { parent[$1] = $2; owner[$1] = $3 }
        END { for (q in parent) { x = q; for (i = 0; i < 20 && x != ""; i++) { if (x == root) { if (owner[q] == u) { print q; exit } break } x = parent[x] } } }' <<<"$tree")"
      [[ -n "$found" ]] && break
    done
    [[ -n "$found" ]] && break
    (( SECONDS < deadline )) || break
    sleep 0.2
  done
  [[ -n "$found" ]] \
    || die "started '$AGENT' but no process of $TKA_USER's runs in pane $AGENT_PANE — with the agent user on, claude must run through $TKA_WRAPPER (the claude shim on the pane's PATH, from devboxes' .bashrc hook). Not sending the ticket: it may be running as $(id -un). Remove the workspace with /sweep-tickets and try again."
  ACCOUNT_CONFIG_DIR="$(agent_config_dir_for "$ACCOUNT_NAME")"
  ACCOUNT_STATUS="verified: pid $found runs as $TKA_USER; config root by the wrapper's rule"
  log "agent user verified: '$AGENT' runs as $TKA_USER (pid $found), config root $ACCOUNT_CONFIG_DIR"
}

# ---- shared model config (config/models.env, installed as ticket-models.env) ----

# The effort levels Claude Code knows, as `claude --effort` itself lists them.
# One list, so the check below and every message that names the valid values
# can't drift apart.
EFFORT_LEVELS="low medium high xhigh max"
# Word by word rather than a substring match on the list: `--effort=` hands this
# an empty string, which a `*" $1 "*` pattern would match against any of the
# single spaces in the list and wave through — and `claude --effort ''` warns and
# runs at its default exactly like a typo does.
effort_valid() {
  local level
  for level in $EFFORT_LEVELS; do [[ "$1" == "$level" ]] && return 0; done
  return 1
}

# The refusal, in one place for the reason EFFORT_LEVELS is: two copies of a
# message that names the valid values are two things to keep in step. Called
# from the two points where nothing can override the resolved level any more —
# see load_ticket_models for why it is neither of them.
require_valid_effort() {
  effort_valid "$IMPL_EFFORT" \
    || die "invalid effort '$IMPL_EFFORT' from $IMPL_EFFORT_SOURCE — one of: $EFFORT_LEVELS"
  # The fixed roles have no flag to outrank them, so whatever the config or the
  # environment says is final — checked here with the implementer's for the same
  # reason: an unknown level in an --agents definition is as silent as one on
  # the command line.
  local role var
  for role in COORD BOARD REVIEW TEST SCOUT RESEARCH CHECK MERGE RETRO PR DOCREVIEW; do
    var="${role}_EFFORT"
    effort_valid "${!var}" \
      || die "invalid effort '${!var}' for TICKET_${role/DOCREVIEW/DOC_REVIEW}_EFFORT (from $MODELS_CONF or the environment) — one of: $EFFORT_LEVELS"
  done
  effort_valid "$REVIEW_EFFORT_UNTESTED" \
    || die "invalid effort '$REVIEW_EFFORT_UNTESTED' for TICKET_REVIEW_EFFORT_UNTESTED — one of: $EFFORT_LEVELS"
}

# Says where a resolved value came from, for `launch.sh defaults` to quote.
# Takes the variable's name and what the environment held under it *before* the
# config file was sourced — the file sets its values with `:=`, so an exported
# variable wins silently and afterwards the two are indistinguishable, and only
# the caller can have kept the earlier reading. What the name holds *now* is
# read here rather than passed, so the two can't be handed in disagreeing.
# A question that states its default has to be able to say where it came from.
config_source() {
  local var="$1" exported="$2" after="${!1:-}"
  if [[ -n "$exported" ]]; then
    echo "exported $var"
  elif [[ -n "$after" ]]; then
    echo "$MODELS_CONF"
  elif [[ -f "$MODELS_CONF" ]]; then
    echo "the launcher's built-in fallback — nothing set it in $MODELS_CONF"
  else
    # Said apart from the case above, because the skills quote this line to the
    # developer: "nothing set it in <path>" about a file that isn't there sends
    # them to edit a file they'd have to create.
    echo "the launcher's built-in fallback — no $MODELS_CONF"
  fi
}

# Called by the caller before it sets its own parameters, never from
# launcher_main: the config file may set any TICKET_* variable, so anything
# resolved from the environment — PERMISSION_MODE among them — has to be
# resolved after this has run.
load_ticket_models() {
  MODELS_CONF="${TICKET_MODELS_CONF:-$(dirname "$SKILL_DIR")/ticket-models.env}"
  local exported_model="${TICKET_IMPL_MODEL:-}" exported_effort="${TICKET_IMPL_EFFORT:-}"
  if [[ -f "$MODELS_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$MODELS_CONF" || die "failed to load model config: $MODELS_CONF"
  fi
  IMPL_MODEL="${TICKET_IMPL_MODEL:-opus}"
  REVIEW_MODEL="${TICKET_REVIEW_MODEL:-opus}"
  TEST_MODEL="${TICKET_TEST_MODEL:-haiku}"
  # The roster beyond the three original roles, and every fixed role's effort.
  # Fallbacks match config/models.env, for a ticket-models.env installed before
  # these knobs existed — the same cover IMPL_EFFORT's fallback gives.
  COORD_MODEL="${TICKET_COORD_MODEL:-opus}";       COORD_EFFORT="${TICKET_COORD_EFFORT:-low}"
  SCOUT_MODEL="${TICKET_SCOUT_MODEL:-haiku}";      SCOUT_EFFORT="${TICKET_SCOUT_EFFORT:-low}"
  RESEARCH_MODEL="${TICKET_RESEARCH_MODEL:-haiku}"; RESEARCH_EFFORT="${TICKET_RESEARCH_EFFORT:-medium}"
  CHECK_MODEL="${TICKET_CHECK_MODEL:-haiku}";      CHECK_EFFORT="${TICKET_CHECK_EFFORT:-low}"
  REVIEW_EFFORT="${TICKET_REVIEW_EFFORT:-medium}"
  REVIEW_EFFORT_UNTESTED="${TICKET_REVIEW_EFFORT_UNTESTED:-high}"
  BOARD_MODEL="${TICKET_BOARD_MODEL:-haiku}";      BOARD_EFFORT="${TICKET_BOARD_EFFORT:-low}"
  MERGE_MODEL="${TICKET_MERGE_MODEL:-sonnet}";     MERGE_EFFORT="${TICKET_MERGE_EFFORT:-medium}"
  RETRO_MODEL="${TICKET_RETRO_MODEL:-sonnet}";     RETRO_EFFORT="${TICKET_RETRO_EFFORT:-medium}"
  PR_MODEL="${TICKET_PR_MODEL:-sonnet}";           PR_EFFORT="${TICKET_PR_EFFORT:-low}"
  DOCREVIEW_MODEL="${TICKET_DOC_REVIEW_MODEL:-opus}"; DOCREVIEW_EFFORT="${TICKET_DOC_REVIEW_EFFORT:-medium}"
  TEST_EFFORT="${TICKET_TEST_EFFORT:-low}"
  IMPL_MODEL_SOURCE="$(config_source TICKET_IMPL_MODEL "$exported_model")"

  # The in-script fallback is what covers a ticket-models.env installed before
  # this knob existed: that file simply sets nothing, so the effort resolves to
  # `medium` and the launch is unchanged. install.sh never overwrites a
  # destination copy, so those files stay as they are until the developer
  # deletes one — see docs/agents/models.md.
  IMPL_EFFORT="${TICKET_IMPL_EFFORT:-medium}"
  IMPL_EFFORT_SOURCE="$(config_source TICKET_IMPL_EFFORT "$exported_effort")"
  # Deliberately *not* validated here. This runs at source time, before
  # launcher_main has parsed `--effort`, and the flag is the top of the
  # precedence order — dying on the environment here would let a bad exported
  # TICKET_IMPL_EFFORT veto a launch that explicitly named a good level. The two
  # places that can validate are the ones where nothing can override any more:
  # after the flag loop, and inside print_launch_defaults.
}

# ---- what a launch would do if it were told nothing --------------------------
# The values the skills' once-a-session launch question has to state before it
# asks: the model an unnamed launch would use, the effort it would run at, and
# the account an unnamed launch would inherit. Prints them, changes nothing, and
# needs neither Herdr nor a ticket — it runs before the developer has settled
# what to launch, sometimes before they have settled whether to.
#
# All are read rather than assumed, because each is easy to state wrongly from
# inside a session. The model and the effort may come from a hand-edited
# ticket-models.env or an exported variable, not from this repo's config — and a
# ticket-models.env installed before the effort knob existed sets no effort at
# all, which is the built-in fallback's case and says so. And the account a *new* worktree
# inherits is not the account the asking session runs under: a ticket is cut as a
# sibling of the main checkout, so what it inherits is whatever the directory
# holding the checkout resolves to — which is the question asked here, and the
# same one an unnamed launch answers by writing no link at all. A session running
# in a worktree that overrode its own account would otherwise offer that account
# as "the default", which is the invisibility this whole knob exists to end.
#
# ACCOUNTS= is the option list the question offers. No skill has claude-acc in its
# allowed-tools, and none should need it.
print_launch_defaults() {
  need git
  resolve_repo_root
  # `defaults` takes no flags, so what load_ticket_models resolved is final here
  # and this is where a bad environment or config file has to be caught: the
  # whole point of the line below is to be quoted into a question, and quoting a
  # level Claude Code would silently ignore is worse than refusing to answer.
  require_valid_effort
  local parent cfg
  parent="$(dirname "$ROOT")"

  echo "MODEL=$IMPL_MODEL (from $IMPL_MODEL_SOURCE)"
  echo "EFFORT=$IMPL_EFFORT (from $IMPL_EFFORT_SOURCE)"
  echo "EFFORTS=$EFFORT_LEVELS"
  # The session coordinates on its own setting: MODEL= and EFFORT= reach the
  # implementer alone, and the question should know it.
  echo "COORDINATOR=$COORD_MODEL @ $COORD_EFFORT (from config — the launched session; the answer above goes to its implementer)"
  # What board.sh starts the board session on.
  echo "BOARD=$BOARD_MODEL @ $BOARD_EFFORT (from config — the board session board.sh starts)"

  # Without the switcher there is nothing to choose between: no link can be
  # written, so every ticket runs on the standard ~/.claude whatever
  # ~/.claude-switch/accounts happens to hold.
  if ! have_claude_acc; then
    echo "ACCOUNT=default (claude-acc isn't installed — every ticket runs on the standard ~/.claude)"
    echo "ACCOUNTS=default"
    return 0
  fi

  if cfg="$(account_config_dir "$parent")"; then
    # `${cfg:-~/.claude}` reads the same for a named account as for the standard
    # root, and is the form the launch summary's own ACCOUNT= line uses.
    echo "ACCOUNT=$(account_name_for "$cfg") (inherited by a new worktree in $parent — config root ${cfg:-~/.claude})"
  else
    # Neither a guess nor a `die`: the question can still be asked, it just has
    # to ask rather than offer a default nothing could resolve.
    echo "ACCOUNT=unknown (claude-acc activate failed in $parent — ask the developer, don't guess)"
  fi
  echo "ACCOUNTS=$(account_names | tr '\n' ' ' | sed 's/ $//')"
}

# ---- the subagent roster, defined per launch -----------------------------------
# Claude Code reads a subagent's model and effort from its frontmatter, which
# can't read config/models.env and can't vary per ticket. `claude --agents
# '<json>'` can do both: a definition passed there outranks ~/.claude/agents/
# for that session only. So every installed agents/ticket-*.md is re-issued here
# with its prompt unchanged and the model and effort this launch resolved — the
# ticket's own for ticket-implementer, config/models.env's for the rest. The
# frontmatter copies stay as the fallback for an agent invoked any other way.
#
# TICKET_SESSION_AGENTS=0 skips it and launches exactly as before this existed:
# the frontmatter's model and effort apply, and only an explicit `model` on the
# Agent tool call varies them.
role_of_agent() {
  case "$1" in
    ticket-implementer)      echo IMPL ;;
    ticket-reviewer)         echo REVIEW ;;
    ticket-tester)           echo TEST ;;
    ticket-scout)            echo SCOUT ;;
    ticket-researcher)       echo RESEARCH ;;
    ticket-criteria-checker) echo CHECK ;;
    ticket-merger)           echo MERGE ;;
    ticket-retro)            echo RETRO ;;
    ticket-pr-creator)       echo PR ;;
    ticket-doc-reviewer)     echo DOCREVIEW ;;
    *)                       return 1 ;;
  esac
}

# Sets SESSION_AGENTS_JSON (empty when skipped) and SESSION_AGENTS_STATUS.
# With names, only those agents are defined — every definition is prompt the
# session pays for, so a session gets the roster it uses and no more.
build_session_agents() {
  local only=" $* "
  SESSION_AGENTS_JSON=""
  if [[ "${TICKET_SESSION_AGENTS:-1}" == 0 ]]; then
    SESSION_AGENTS_STATUS="off (TICKET_SESSION_AGENTS=0 — subagents run on their frontmatter)"
    return 0
  fi
  # Installed: ~/.claude/skills/<skill> -> ~/.claude/agents. Source tree:
  # <repo>/skills/<skill> -> <repo>/agents. The same two-up hop finds both.
  local dir="${TICKET_AGENTS_DIR:-$(dirname "$(dirname "$SKILL_DIR")")/agents}"
  local json='{}' file name desc tools body role model_var effort_var names=()
  for file in "$dir"/ticket-*.md; do
    [[ -f "$file" ]] || continue
    # Frontmatter is the block between the first two `---` lines; the body is
    # everything after the second, verbatim.
    name="$(awk '/^---$/{n++; next} n==1 && /^name:/{sub(/^name:[ ]*/,""); print; exit}' "$file")"
    role="$(role_of_agent "$name")" || continue
    [[ "$only" == "  " || "$only" == *" $name "* ]] || continue
    desc="$(awk '/^---$/{n++; next} n==1 && /^description:/{sub(/^description:[ ]*/,""); print; exit}' "$file")"
    tools="$(awk '/^---$/{n++; next} n==1 && /^tools:/{sub(/^tools:[ ]*/,""); print; exit}' "$file")"
    body="$(awk 'n>=2{print; next} /^---$/{n++}' "$file")"
    model_var="${role}_MODEL"; effort_var="${role}_EFFORT"
    json="$(jq -c --arg n "$name" --arg d "$desc" --arg t "$tools" --arg p "$body" \
              --arg m "${!model_var}" --arg e "${!effort_var}" \
      '. + {($n): {description: $d, prompt: $p, model: $m, effort: $e,
                   tools: ($t | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}}' \
      <<<"$json")" || die "couldn't build the --agents definition for $name from $file"
    names+=("$name=${!model_var}/${!effort_var}")
  done
  if [[ ${#names[@]} -eq 0 ]]; then
    SESSION_AGENTS_STATUS="none found in $dir (subagents run on their frontmatter — re-run install.sh)"
    return 0
  fi
  SESSION_AGENTS_JSON="$json"
  SESSION_AGENTS_STATUS="${names[*]}"
}

# ---- the launch ---------------------------------------------------------------
# ---- the phase file, as a new agent starts -------------------------------------
# A launch writes `launching`, a resume `resuming`, over line 1 of the ticket's
# phase file; line 2 (tests=… criteria=… review=…, what the merge gates read) is
# kept. Then `<phase file>.started`, the epoch this agent started: tk.sh's board
# rows read a `done` as this agent's only when the phase file is not older than
# the mark, so an earlier agent's `done` can't make a dead one look finished.
reset_phase() {
  local word=launching line2=""
  (( RESUME )) && word=resuming
  [[ -s "$PHASE_FILE" ]] && line2="$(sed -n 2p "$PHASE_FILE")"
  date +%s >"$PHASE_FILE.started"
  printf '%s\n%s\n' "$word" "$line2" >"$PHASE_FILE"
  log "phase file reset to '$word' (an earlier agent's phase is not this one's)"
}

# `herdr agent start` for $AGENT in $AGENT_PANE, setting START_OUT and START_RC.
# A pane just made can refuse an agent while its shell is still starting: the
# start is retried every TICKET_AGENT_START_RETRY_EVERY_S (1) seconds for up to
# TICKET_AGENT_START_RETRY_S (10), as tk-daemon does for grills. A dialog
# (agent_not_ready) is a started agent, never retried. Reads agents_arg,
# RESUME_ARGS, RC_ARGS and DISALLOWED_TOOLS from the caller.
start_agent_retrying() {
  local tries=0 deadline=$(( SECONDS + ${TICKET_AGENT_START_RETRY_S:-10} ))
  set +e
  while :; do
    # --agents goes before --disallowedTools: that one is variadic and would
    # swallow anything after it.
    START_OUT="$(herdr agent start "$AGENT" --kind "$AGENT_KIND" --pane "$AGENT_PANE" -- \
      --model "$SESSION_MODEL" --effort "$SESSION_EFFORT" --permission-mode "$SESSION_PERMISSION_MODE" \
      ${agents_arg[@]+"${agents_arg[@]}"} \
      ${RESUME_ARGS[@]+"${RESUME_ARGS[@]}"} \
      ${RC_ARGS[@]+"${RC_ARGS[@]}"} \
      --disallowedTools "${DISALLOWED_TOOLS[@]}" 2>&1)"
    START_RC=$?
    tries=$(( tries + 1 ))
    [[ $START_RC -eq 0 ]] && break
    grep -q 'agent_not_ready' <<<"$START_OUT" && break
    (( SECONDS < deadline )) || break
    log "herdr agent start $AGENT failed (try $tries), retrying: $(tail -1 <<<"$START_OUT")"
    sleep "${TICKET_AGENT_START_RETRY_EVERY_S:-1}"
  done
  set -e
  if (( START_RC != 0 && tries > 1 )); then START_OUT+=" ($tries tries)"; fi
  return 0
}

# ---- --resume: a new agent in the worktree a dead one left ---------------------
# Instead of section 1-2 of launcher_main: the worktree, its branch, its account
# link and its catalog skills are all there already, so only a workspace, its
# tabs and the account check are made. The workspace is new: after a container
# restart the old one is gone, and after an OOM it holds a dead pane.
resume_workspace() {
  # With the agent user on, the worktree is made the agent's again (files a
  # merge or rebase added since), before any pane of this workspace starts.
  agent_on && agent_prepare_worktree "$WT"
  # The link already exists (or never did): resolve it, write nothing.
  link_ticket_account
  if [[ -n "$RESUME_EXPECT_ACCOUNT" && "$RESUME_EXPECT_ACCOUNT" != unknown && "$RESUME_EXPECT_ACCOUNT" != "$ACCOUNT_NAME" ]]; then
    die "the ticket ran on the '$RESUME_EXPECT_ACCOUNT' account, but $WT now resolves to '$ACCOUNT_NAME' — check 'claude-acc links'; not resuming on another subscription"
  fi

  # The conversation to resume, if Claude Code can: its transcript must be under
  # the config root this worktree resolves to (the pane's), and its last line
  # whole — a kill mid-write can leave half a JSON line, and a resume that
  # fails to load starts nothing. Otherwise the full brief, note on top.
  RESUME_WHY=""
  if [[ -n "$RESUME_SESSION" ]]; then
    local transcript
    local troot="${ACCOUNT_CONFIG_DIR:-$HOME/.claude}"
    # The agent's own config root for this account, with the agent user on.
    agent_on && troot="$(agent_config_dir_for "$ACCOUNT_NAME")"
    transcript="$troot/projects/${WT//[^A-Za-z0-9]/-}/$RESUME_SESSION.jsonl"
    if [[ ! -s "$transcript" ]]; then
      RESUME_WHY="no transcript $RESUME_SESSION under $troot"
    elif ! tail -n 1 "$transcript" | jq -e . >/dev/null 2>&1; then
      RESUME_WHY="transcript $RESUME_SESSION ends in a cut-off line"
    fi
    if [[ -n "$RESUME_WHY" ]]; then
      log "not resuming the conversation: $RESUME_WHY — sending the full brief with the resume note"
      RESUME_SESSION=""
    else
      cp "$RESUME_NOTE" "$PROMPT_FILE"
      log "resuming conversation $RESUME_SESSION"
    fi
  fi

  log "creating a workspace for the existing worktree $WT"
  local -a create=(workspace create --cwd "$WT" --label "$LABEL")
  has_flag --no-focus workspace create && create+=(--no-focus)
  local json
  json="$(herdr_json "herdr workspace create" "${create[@]}")"
  WORKSPACE_ID="$(jq -r '.result.workspace.workspace_id // .result.workspace.id // empty' <<<"$json")"
  ROOT_TAB="$(jq -r '.result.tab.tab_id // .result.tab.id // empty' <<<"$json")"
  ROOT_PANE="$(jq -r '.result.root_pane.pane_id // .result.root_pane.id // empty' <<<"$json")"
  [[ -n "$WORKSPACE_ID" ]] || die "couldn't read the workspace from the response: $json"
  [[ -n "$ROOT_PANE" ]] || die "couldn't read the workspace's root pane from the response: $json"
  AGENT_TAB="${ROOT_TAB:-?}"; AGENT_PANE="$ROOT_PANE"
  [[ -n "$ROOT_TAB" ]] && herdr_json "herdr tab rename" tab rename "$ROOT_TAB" agent >/dev/null
  # The same one tab as a launch: agent | shell. A workspace on an existing
  # worktree fires `worktree.opened`, which auto-opens reviewr too.
  close_reviewr_pane
  split_shell_pane
}

launcher_main() {
  # ---- subcommand: defaults -----------------------------------------------------
  # Ahead of everything below, and deliberately: it reads two values and starts
  # nothing, so a question asked before the first launch must not depend on a
  # Herdr pane, on jq, or on this repo being ready to launch anything.
  if [[ "${1:-}" == "defaults" ]]; then
    [[ $# -eq 1 ]] || die "usage: launch.sh defaults"
    print_launch_defaults
    exit 0
  fi

  AGENT_KIND="${TICKET_AGENT_KIND:-claude}"
  REMOTE="${TICKET_REMOTE:-origin}"
  REVIEWR_WAIT="${TICKET_REVIEWR_WAIT:-5}"
  # No leading zeros: `08` clears a bare ^[0-9]+$ and then blows up as octal in
  # the arithmetic below.
  [[ "$REVIEWR_WAIT" =~ ^(0|[1-9][0-9]*)$ ]] \
    || die "invalid TICKET_REVIEWR_WAIT '$REVIEWR_WAIT' — whole seconds, no leading zeros (0 skips the wait)"
  # Again here, not only where ticket-account.sh is sourced: the config file is
  # read between the two, and it may set either of these.
  resolve_account_env
  # The agent user (ticket-agent.sh): off unless the box policy or
  # TICKET_AGENT_USER names one. Read here, so a dry run shows it too.
  resolve_agent_user

  # TICKET_DRY_RUN=1 does every check and renders the prompt, then prints the
  # summary and stops: no pull, no worktree, no tabs, no agent — so it needs
  # no Herdr pane. For checking what a ticket would launch as.
  DRY_RUN=0; [[ "${TICKET_DRY_RUN:-0}" == 1 ]] && DRY_RUN=1
  if (( ! DRY_RUN )); then
    [[ "${HERDR_ENV:-}" == 1 ]] || die "not running inside a Herdr pane (HERDR_ENV != 1)"
    need herdr
  fi
  need git; need jq

  # ---- flags, ahead of the positionals -----------------------------------------
  # --account is a flag rather than a fifth positional because it is the rare
  # case: a ticket that names no account inherits the developer's own, and the
  # call site stays the three or four words it has always been. An exported
  # TICKET_ACCOUNT does the same job for a whole session, and the flag wins over
  # it — the same order the model knob uses, and for the same reason: the skills'
  # allowed-tools entries are prefix patterns, which a `TICKET_ACCOUNT=x ...`
  # prefix would no longer match.
  #
  # --effort is a flag for the same reason and one more: the model's positional
  # slot is only bearable because the model is the one thing that varies every
  # run, and a fifth positional would make the call site a row of bare words
  # nobody can read back. --account had already established the shape.
  ACCOUNT_REQUESTED="${TICKET_ACCOUNT:-}"
  DOC=0   # only the --doc flag sets it; never inherited from the environment
  HELPER=0   # only the --helper flag sets it, the same way
  DOC_TYPE=""
  RESUME=0 RESUME_SESSION="" RESUME_NOTE="" RESUME_EXPECT_ACCOUNT=""
  local -a ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --account)   [[ $# -ge 2 ]] || die "--account needs an account name"
                   ACCOUNT_REQUESTED="$2"; shift 2 ;;
      --account=*) ACCOUNT_REQUESTED="${1#--account=}"; shift ;;
      --effort)    [[ $# -ge 2 ]] || die "--effort needs a level — one of: $EFFORT_LEVELS"
                   IMPL_EFFORT="$2"; IMPL_EFFORT_SOURCE="the --effort flag"; shift 2 ;;
      --effort=*)  IMPL_EFFORT="${1#--effort=}"; IMPL_EFFORT_SOURCE="the --effort flag"; shift ;;
      --skills)    [[ $# -ge 2 ]] || die "--skills needs a comma-separated list (empty for none)"
                   SKILLS_REQUESTED="$2"; shift 2 ;;
      --skills=*)  SKILLS_REQUESTED="${1#--skills=}"; shift ;;
      --doc)       DOC=1; shift ;;
      --helper)    HELPER=1; shift ;;
      --resume)    RESUME=1; shift ;;
      --session)   [[ $# -ge 2 ]] || die "--session needs a Claude Code session id (empty for none)"
                   RESUME_SESSION="$2"; shift 2 ;;
      --resume-note) [[ $# -ge 2 ]] || die "--resume-note needs a file"
                   RESUME_NOTE="$2"; shift 2 ;;
      --expect-account) [[ $# -ge 2 ]] || die "--expect-account needs an account name"
                   RESUME_EXPECT_ACCOUNT="$2"; shift 2 ;;
      --doc-type)  [[ $# -ge 2 ]] || die "--doc-type needs a type — one of: $DOC_TYPES"
                   DOC_TYPE="$2"; shift 2 ;;
      --doc-type=*) DOC_TYPE="${1#--doc-type=}"; shift ;;
      -*)          die "unknown flag: $1" ;;
      *)           ARGS+=("$1"); shift ;;
    esac
  done
  set -- ${ARGS[@]+"${ARGS[@]}"}

  # Refused here rather than passed through: `claude --effort bogus` only prints
  # "Warning: Unknown --effort value 'bogus' — ignoring it and using the default
  # effort" and then runs, so a typo would launch a whole ticket at an effort
  # nobody chose and nothing in the summary would say so.
  require_valid_effort

  # ---- subcommand: prompt -------------------------------------------------------
  if [[ "${1:-}" == "prompt" ]]; then
    [[ $# -eq 3 ]] || die "usage: launch.sh prompt <agent> <prompt-file>"
    send_prompt "$2" "$3"
    exit 0
  fi

  # ---- arguments ---------------------------------------------------------------
  [[ $# -eq 3 || $# -eq 4 ]] || die "usage: launch.sh [--account <name>] [--effort <level>] [--skills <a,b>] [--doc [--doc-type <$(tr ' ' '|' <<<"$DOC_TYPES")>]] [--helper] [--resume --resume-note <file> [--session <id>] [--expect-account <a>]] <tab-label> <branch> <ticket-file> [model]  |  launch.sh defaults"
  (( ! ${DOC:-0} )) || TEMPLATE="$DOC_TEMPLATE"
  # A helper session: the developer's own ticket, and the developer drives it.
  # One session on the ticket's model and effort, no coordinator and no
  # implementer; it waits for the developer instead of starting on its own.
  if (( HELPER )); then
    [[ -n "${HELPER_TEMPLATE:-}" ]] || die "--helper: this launcher has no helper template"
    TEMPLATE="$HELPER_TEMPLATE"
  fi
  if [[ -n "$DOC_TYPE" ]]; then
    (( ${DOC:-0} )) || die "--doc-type is only for a --doc launch"
    [[ " $DOC_TYPES " == *" $DOC_TYPE "* ]] || die "unknown doc type '$DOC_TYPE' — one of: $DOC_TYPES"
  fi
  if (( RESUME )); then
    [[ -s "$RESUME_NOTE" ]] || die "--resume needs --resume-note <file>: what the new agent is told about the worktree it finds"
    [[ -z "$RESUME_SESSION" || "$RESUME_SESSION" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "invalid session id '$RESUME_SESSION'"
    [[ -z "$ACCOUNT_REQUESTED" ]] || die "--resume keeps the worktree's account link as it is — use --expect-account, not --account"
  else
    [[ -z "$RESUME_SESSION$RESUME_NOTE$RESUME_EXPECT_ACCOUNT" ]] || die "--session, --resume-note and --expect-account are only for --resume"
  fi
  LABEL="$1"; BRANCH="$2"; TICKET_FILE="$3"
  [[ -n "${4:-}" ]] && IMPL_MODEL="$4"
  [[ -s "$TICKET_FILE" ]] || die "ticket file is empty or missing: $TICKET_FILE"
  # How hard the reviewer thinks. A ticket nothing can test — its Seams line says
  # None: no suite, or infra that only runs live — is reviewed at
  # TICKET_REVIEW_EFFORT_UNTESTED, since that review is the last check before a
  # real environment. A document has no code to test, so its `None` says nothing
  # about risk: its review stays at TICKET_DOC_REVIEW_*.
  REVIEW_EFFORT_WHY="config"
  if (( ! ${DOC:-0} )) && grep -qiE '^\*\*Seams under test:\*\*[[:space:]]*None' "$TICKET_FILE"; then
    REVIEW_EFFORT="$REVIEW_EFFORT_UNTESTED"; REVIEW_EFFORT_WHY="untested: the ticket's Seams line says None"
  fi
  [[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"

  [[ "$BRANCH" =~ ^[a-z][a-z0-9-]{2,39}$ && "$BRANCH" != *--* && "$BRANCH" != *- ]] \
    || die "invalid branch '$BRANCH' — use kebab-case without '/' or '--', up to 40 chars (e.g. fix-webhook-retry)"
  git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "branch name rejected by git: $BRANCH"
  [[ "$IMPL_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid model '$IMPL_MODEL'"
  # The coordinator only dispatches a settled plan, so it runs on its own (cheap)
  # setting from config/models.env, not the ticket's.
  [[ "$COORD_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid coordinator model '$COORD_MODEL'"
  check_ticket_account

  # ---- main repo (--path keeps the worktree at ../<repo>--<branch>, so `gd` still works) ----
  resolve_repo_root
  WT="$(dirname "$ROOT")/${REPO_NAME}--${BRANCH}"

  if (( RESUME )); then
    # The worktree as the dead agent left it: never pulled, rebased or reset here.
    git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" || die "branch '$BRANCH' doesn't exist — nothing to resume; launch the ticket instead"
    [[ -d "$WT" ]] || die "worktree $WT is gone — nothing to resume"
    WT_BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [[ "$WT_BRANCH" == "$BRANCH" ]] || die "worktree at $WT is on '${WT_BRANCH:-?}', not '$BRANCH'"
    HAS_REMOTE=0
    git -C "$ROOT" remote get-url "$REMOTE" >/dev/null 2>&1 && HAS_REMOTE=1
    resolve_base_branch
    BASE_COMMIT="$(git -C "$WT" merge-base HEAD "$BASE_BRANCH" 2>/dev/null || git -C "$WT" rev-parse HEAD)"
    BASE_SHORT="$(git -C "$WT" rev-parse --short "$BASE_COMMIT")"
    BASE_SOURCE="resumed: the worktree as it was left"
  else
    git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" && die "branch '$BRANCH' already exists"
    [[ -e "$WT" ]] && die "worktree path already exists: $WT"

    # ---- update the base branch before creating the worktree -------------------------
    # `herdr worktree create --base` branches from the root's ref, so the root
    # needs to be on the base branch and up to date with the remote. A repo with
    # no remote at all — a presales repo whose output is a PDF, say — has nothing
    # to update from: it branches from the local base as it stands.
    HAS_REMOTE=0
    git -C "$ROOT" remote get-url "$REMOTE" >/dev/null 2>&1 && HAS_REMOTE=1
    resolve_base_branch

    CURRENT="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
    [[ "$CURRENT" == "$BASE_BRANCH" ]] \
      || die "root $ROOT is on branch '$CURRENT', not '$BASE_BRANCH'. The worktree branches off the root's '$BASE_BRANCH'; check out '$BASE_BRANCH' there and run again."

    if (( HAS_REMOTE && DRY_RUN )); then
      log "dry run — not pulling '$BASE_BRANCH'; branching point is the local '$BASE_BRANCH' as it stands"
      BASE_SOURCE="dry run, not pulled"
    elif (( HAS_REMOTE )); then
      log "updating '$BASE_BRANCH' in $ROOT (git pull --ff-only $REMOTE $BASE_BRANCH)"
      run_git_net pull --ff-only "$REMOTE" "$BASE_BRANCH" >&2 \
        || die "pull of '$BASE_BRANCH' failed (no fast-forward, conflict with local changes, network, or credentials). Fix it in $ROOT and run again."
      BASE_SOURCE="updated via pull"
    else
      log "no '$REMOTE' remote in $ROOT — branching from the local '$BASE_BRANCH' as it stands"
      BASE_SOURCE="local, no remote"
    fi

    BASE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
    REMOTE_COMMIT=""
    (( HAS_REMOTE && ! DRY_RUN )) && REMOTE_COMMIT="$(git -C "$ROOT" rev-parse "refs/remotes/$REMOTE/$BASE_BRANCH" 2>/dev/null || true)"
    if [[ -n "$REMOTE_COMMIT" && "$BASE_COMMIT" != "$REMOTE_COMMIT" ]]; then
      if git -C "$ROOT" merge-base --is-ancestor "$REMOTE_COMMIT" "$BASE_COMMIT"; then
        log "warning: local '$BASE_BRANCH' has commits not yet pushed to $REMOTE"
      else
        die "local '$BASE_BRANCH' ($BASE_COMMIT) doesn't match $REMOTE/$BASE_BRANCH ($REMOTE_COMMIT) after the pull"
      fi
    fi
    BASE_SHORT="$(git -C "$ROOT" rev-parse --short HEAD)"
  fi

  # ---- agent name -----------------------------------------------------------
  AGENT="tk-${BRANCH}"; AGENT="${AGENT:0:32}"; AGENT="${AGENT%-}"
  if (( ! DRY_RUN )) && herdr agent list 2>/dev/null | grep -q "\"${AGENT}\""; then
    AGENT="${AGENT:0:28}-$((RANDOM % 900 + 100))"
  fi

  resolve_remote_control
  resolve_project_memory
  resolve_retro_results
  resolve_doc_guidance
  resolve_catalog_skills

  # ---- render the prompt (outside the worktree, so it doesn't dirty git status) -------
  RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/$RUN_NAME"; mkdir -p "$RUN_DIR"
  PROMPT_FILE="$RUN_DIR/${AGENT}.md"
  tpl="$(cat "$TEMPLATE")"
  ticket="$(cat "$TICKET_FILE")"
  tpl="${tpl//'{{BRANCH}}'/"$BRANCH"}"
  tpl="${tpl//'{{BASE_BRANCH}}'/"$BASE_BRANCH"}"
  tpl="${tpl//'{{BASE_COMMIT}}'/"$BASE_SHORT"}"
  tpl="${tpl//'{{WORKTREE}}'/"$WT"}"
  tpl="${tpl//'{{IMPL_MODEL}}'/"$IMPL_MODEL"}"
  tpl="${tpl//'{{REVIEW_MODEL}}'/"$REVIEW_MODEL"}"
  tpl="${tpl//'{{TEST_MODEL}}'/"$TEST_MODEL"}"
  tpl="${tpl//'{{SCOUT_MODEL}}'/"$SCOUT_MODEL"}"
  tpl="${tpl//'{{RESEARCH_MODEL}}'/"$RESEARCH_MODEL"}"
  tpl="${tpl//'{{CHECK_MODEL}}'/"$CHECK_MODEL"}"
  tpl="${tpl//'{{DOC_REVIEW_MODEL}}'/"$DOCREVIEW_MODEL"}"
  # The one file outside the worktree a ticket writes: its final report, kept
  # where it outlives the worktree for ticket-retro to read.
  REPORT_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/ticket-skill/$REPO_NAME/reports/$BRANCH.md"
  mkdir -p "$(dirname "$REPORT_FILE")"
  # With the agent user on, the brief names the shared copies (agent_state_file:
  # made in the box's shared state dir, linked from these paths, which are the
  # ones the board reads); a dry run only says where they would be.
  BRIEF_REPORT="$REPORT_FILE"
  if agent_on; then
    if (( DRY_RUN )); then BRIEF_REPORT="$(agent_state_path "$REPORT_FILE")"
    else BRIEF_REPORT="$(agent_state_file "$REPORT_FILE")"; fi
  fi
  tpl="${tpl//'{{REPORT_FILE}}'/"$BRIEF_REPORT"}"
  # One word, rewritten at each phase of the brief, for `tk.sh view`: Herdr shows
  # an agent as "working" whether it's implementing or reviewing.
  PHASE_FILE="$(dirname "$(dirname "$REPORT_FILE")")/phase/$BRANCH"
  mkdir -p "$(dirname "$PHASE_FILE")"
  BRIEF_PHASE="$PHASE_FILE"
  if agent_on; then
    if (( DRY_RUN )); then BRIEF_PHASE="$(agent_state_path "$PHASE_FILE")"
    else BRIEF_PHASE="$(agent_state_file "$PHASE_FILE")"; fi
  fi
  tpl="${tpl//'{{PHASE_FILE}}'/"$BRIEF_PHASE"}"
  # What the agent asks the developer when only they can answer (tk.sh answer,
  # docs/agents/questions.md): read by tk.sh's board rows and by tk-hub.
  QUESTIONS_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/ticket-skill/$REPO_NAME/questions/$BRANCH.json"
  mkdir -p "$(dirname "$QUESTIONS_FILE")"
  BRIEF_QUESTIONS="$QUESTIONS_FILE"
  if agent_on; then
    if (( DRY_RUN )); then BRIEF_QUESTIONS="$(agent_state_path "$QUESTIONS_FILE")"
    else BRIEF_QUESTIONS="$(agent_state_file "$QUESTIONS_FILE" '[]')"; fi
  fi
  tpl="${tpl//'{{QUESTIONS_FILE}}'/"$BRIEF_QUESTIONS"}"
  # The prose payloads go last, so the replacements above can't reach inside
  # them. RETRO_RESULTS goes first of them: its content is built by the launcher
  # (paths only), so it is safe to fill early, and filling it before TICKET keeps
  # a literal `{{RETRO_RESULTS}}` inside a ticket body (a ticket about this very
  # placeholder) from being rewritten. TICKET goes before PROJECT_MEMORY, because
  # the memory placeholder sits above the ticket in the template, so filling it
  # first would let a `{{TICKET}}` written inside the memory file win over the
  # template's own. DOC_GUIDANCE is launcher-built too (paths only), so it goes
  # with RETRO_RESULTS, ahead of the ticket.
  fill_prose '{{RETRO_RESULTS}}' "$RETRO_BLOCK"
  fill_prose '{{AGENT_USER_NOTE}}' "$(agent_brief_note)"
  fill_prose '{{DOC_GUIDANCE}}' "$DOC_GUIDANCE_BLOCK"
  fill_prose '{{TICKET}}' "$ticket"
  fill_prose '{{PROJECT_MEMORY}}' "$MEMORY_BLOCK"
  printf '%s\n' "$tpl" > "$PROMPT_FILE"
  # A resume sends the note on top of the brief; resume_session (after the
  # account is known) cuts it to the note alone when the conversation resumes.
  if (( RESUME )); then
    { cat "$RESUME_NOTE"; echo; echo "---"; echo; printf '%s\n' "$tpl"; } >"$PROMPT_FILE"
  fi

  # The roster this session gets, settled before anything is created so a bad
  # agent definition costs no worktree. A ticket's session uses the ticket-side
  # roster; the merger, the retro and the PR creator belong to the board session
  # (scripts/board.sh). A document swaps the code reviewer for the doc reviewer.
  # A helper session has no implementer: the developer and the session itself do
  # the work, and the rest of the roster checks it when the developer asks.
  local impl_agent=ticket-implementer
  (( HELPER )) && impl_agent=""
  if (( ${DOC:-0} )); then
    build_session_agents ${impl_agent:+"$impl_agent"} ticket-doc-reviewer ticket-tester ticket-scout ticket-researcher ticket-criteria-checker
  else
    build_session_agents ${impl_agent:+"$impl_agent"} ticket-reviewer ticket-tester ticket-scout ticket-researcher ticket-criteria-checker
  fi

  # What the session itself runs on: the coordinator's setting for an agent, the
  # ticket's own model and effort for a helper (it does the work with the developer).
  if (( HELPER )); then
    SESSION_MODEL="$IMPL_MODEL"; SESSION_EFFORT="$IMPL_EFFORT"
    SESSION_PERMISSION_MODE="${HELPER_PERMISSION_MODE:-acceptEdits}"
  else
    SESSION_MODEL="$COORD_MODEL"; SESSION_EFFORT="$COORD_EFFORT"; SESSION_PERMISSION_MODE="$PERMISSION_MODE"
  fi

  summary() {
    cat <<SUMMARY
WORKSPACE=${WORKSPACE_ID:-?} (labelled '$LABEL')
BRANCH=$BRANCH (base: $BASE_BRANCH @ $BASE_SHORT, ${BASE_SOURCE:-updated via pull})
KIND=$KIND_STATUS
RESUME=$( (( RESUME )) && { [[ -n "$RESUME_SESSION" ]] && echo "conversation $RESUME_SESSION" || echo "fresh brief (${RESUME_WHY:-no conversation to resume})"; } || echo "no" )
MODE=$( (( HELPER )) && echo "helper (the developer drives; session on $IMPL_MODEL @ $IMPL_EFFORT, $SESSION_PERMISSION_MODE)" || echo "agent" )
WORKTREE=$WT
TABS=agent:${AGENT_TAB:-?} (panes: agent ${AGENT_PANE:-?} | shell ${SHELL_PANE:-?})
REVIEW=${REVIEW_SOURCE:-?}
AGENT=$AGENT (pane ${AGENT_PANE:-?})
MODEL=$IMPL_MODEL
EFFORT=$IMPL_EFFORT
COORDINATOR=$( (( HELPER )) && echo "none (helper session)" || echo "$COORD_MODEL @ $COORD_EFFORT" )
REVIEWER=$( (( ${DOC:-0} )) && echo "$DOCREVIEW_MODEL @ $DOCREVIEW_EFFORT (document)" || echo "$REVIEW_MODEL @ $REVIEW_EFFORT ($REVIEW_EFFORT_WHY)" )
SUBAGENTS=${SESSION_AGENTS_STATUS:-?}
SKILLS=$(skills_summary)
REMOTE_CONTROL=$( (( REMOTE_CONTROL )) && echo "on (${RC_ORIGIN}: ${RC_ARGS[1]})" || echo "off (${RC_ORIGIN})" )
ACCOUNT=${ACCOUNT_NAME:-?} (${ACCOUNT_ORIGIN:-?}, ${ACCOUNT_CONFIG_DIR:-~/.claude}, ${ACCOUNT_STATUS:-?})
AGENT_USER=$(agent_summary)
START=$( agent_on && echo "herdr agent start … -- <args> → claude shim → sudo -n -u $TKA_USER $TKA_WRAPPER --account ${ACCOUNT_NAME:-default} --cwd $WT -- <args>" || echo "herdr agent start … -- <args> → claude as $(id -un)" )
PROJECT_MEMORY=$MEMORY_STATUS
RETRO_RESULTS=$RETRO_STATUS
REPORT_FILE=${REPORT_FILE:-?}
PROMPT_FILE=$PROMPT_FILE
SUMMARY
  }

  if (( DRY_RUN )); then
    log "dry run (TICKET_DRY_RUN=1) — prompt rendered; nothing created, no agent started"
    summary
    echo "DRY_RUN=1"
    exit 0
  fi

  # ---- 0. the phase file says a new agent is starting -------------------------
  # Whatever an earlier agent left there (a `done`, say) is not this one's: line
  # 1 becomes `launching` or `resuming`, line 2 (the gates' tests/criteria/review)
  # stays. The `.started` mark beside it is when this agent started; tk.sh's
  # board rows trust a `done` only when the phase file is not older than it
  # (docs/agents/resume.md, Finished or orphaned). First, so a start that fails
  # half-way leaves no earlier `done` to read as this agent's.
  reset_phase

  if (( RESUME )); then
    resume_workspace
  else
    # ---- 1. worktree + its workspace, tab and root pane, in one synchronous call --------
    # One call either returns the worktree or fails with Herdr's own error. `--path`
    # pins it to ../<repo>--<branch>, the convention /sweep-tickets reports against
    # (and that `gd <repo>--<branch>` still removes by hand).
    log "creating the worktree $WT (branch '$BRANCH' off '$BASE_BRANCH')"
    create=(worktree create --cwd "$ROOT" --branch "$BRANCH" --base "$BASE_BRANCH" --path "$WT" --label "$LABEL")
    has_flag --no-focus worktree create && create+=(--no-focus)
    WT_JSON="$(herdr_json "herdr worktree create" "${create[@]}")"
    # The worktree and its branch exist from here on, whatever fails next. tk.sh
    # launch reads this line to record the ticket in progress even when the
    # launch then fails, so the ticket isn't left open with a branch a relaunch
    # refuses: tk.sh resume finishes it in this worktree instead.
    [[ -d "$WT" ]] && echo "WORKTREE_MADE=$WT"

    # `--label` above labels the WORKSPACE; the tab that comes with it is labelled
    # by number ("1"), and section 2 either renames it or replaces it. All three
    # ids are load-bearing from here on, so read each one and say which was missing.
    WORKSPACE_ID="$(jq -r '.result.workspace.workspace_id // .result.workspace.id // empty' <<<"$WT_JSON")"
    ROOT_TAB="$(jq -r '.result.tab.tab_id // .result.tab.id // empty' <<<"$WT_JSON")"
    ROOT_PANE="$(jq -r '.result.root_pane.pane_id // .result.root_pane.id // empty' <<<"$WT_JSON")"
    [[ -n "$WORKSPACE_ID" ]] || die "couldn't read the worktree's workspace from the response: $WT_JSON"
    [[ -n "$ROOT_TAB" ]] || die "couldn't read the worktree's tab from the response: $WT_JSON"
    [[ -n "$ROOT_PANE" ]] || die "couldn't read the worktree's root pane from the response: $WT_JSON"
    WT_PATH="$(jq -r '.result.worktree.path // empty' <<<"$WT_JSON")"
    [[ "$WT_PATH" == "$WT" ]] \
      || die "herdr created the worktree at '${WT_PATH:-?}', not at the expected $WT"

    # The branch matters as much as the path: a detached HEAD or a plain checkout of
    # the base branch would also sit at $BASE_COMMIT.
    WT_BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [[ "$WT_BRANCH" == "$BRANCH" ]] \
      || die "worktree at $WT is on '${WT_BRANCH:-?}', not '$BRANCH'"
    WT_COMMIT="$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)"
    [[ "$WT_COMMIT" == "$BASE_COMMIT" ]] \
      || die "worktree was created at $WT_COMMIT, but the updated '$BASE_BRANCH' is at $BASE_COMMIT"

    # ---- 1a. trust the new directory's mise config, where there is one ----------
    # Immediately after the worktree is proved onto disk and before anything else
    # touches it: mise resolves a trust path lexically, so this must not run a line
    # earlier, and every pane created from here on wants the toolchain already
    # trusted. See trust_worktree_mise for the rest, including what it deliberately
    # does not do.
    # ---- 1a. with the agent user on: its files the agent's to write, git not ---------
    agent_on && agent_prepare_worktree "$WT"

    trust_worktree_mise

    # ---- 1a'. the catalog skills this ticket gets, before any pane starts ----------
    link_catalog_skills

    # ---- 1b. the account this ticket runs on ------------------------------------
    # Between the worktree and the agent's pane, because the link is keyed by
    # directory (so the worktree must exist) and a pane resolves its account once,
    # when its shell starts (so no pane the agent will use may exist yet).
    link_ticket_account

    # ---- 2. the workspace's one tab: agent | shell, side by side ----------------
    # tk-hub is where tickets are followed and reviewed now, so a ticket's
    # workspace holds only what the developer reaches for in it: the agent, and a
    # shell in the worktree split to its right. No review tab.
    #
    # Inheriting the account — the default, and every launch before this existed —
    # the worktree's own tab is renamed rather than replaced: that keeps the agent
    # on the root pane, which already has the worktree as its cwd, and nothing was
    # written for its shell to have missed.
    #
    # Overriding it, that root pane's shell resolved the *inherited* account before
    # the link was written, and the PROMPT_COMMAND hook claude-acc installs only
    # re-resolves when $PWD changes — so it will carry the wrong account for as
    # long as it lives. The agent gets a tab of its own, created after the link,
    # and the stale tab is closed below once the reviewr pane is out of it.
    #
    # With the agent user on, the same fresh tab, whatever the account: the root
    # pane's shell started before agent_prepare_worktree gave the worktree to
    # tkwork, so its prompt hook may not have the claude shim on PATH yet.
    if [[ "$ACCOUNT_ORIGIN" == "linked" ]] || agent_on; then
      log "creating a fresh 'agent' tab (the worktree's root pane predates the account link or the agent user's worktree)"
      create_tab agent; AGENT_TAB="$CREATED_TAB"; AGENT_PANE="$CREATED_PANE"
      [[ -n "$AGENT_PANE" ]] \
        || die "couldn't read the new 'agent' tab's pane from Herdr's response — the account override needs a pane created after the link"
    else
      AGENT_TAB="$ROOT_TAB"; AGENT_PANE="$ROOT_PANE"
      log "renaming the worktree's tab to 'agent'"
      herdr_json "herdr tab rename" tab rename "$AGENT_TAB" agent >/dev/null
    fi

    # The persiyanov.reviewr plugin auto-opens a pane on Herdr's `worktree.created`
    # event, as a split on the workspace's *first* pane (its config file,
    # ~/.config/herdr/plugins/config/persiyanov.reviewr/config.toml, decides; no
    # launcher flag reaches it). Left alone it would sit between the agent and the
    # shell, so wait briefly for it and close it: `review` (the devboxes alias) or
    # `herdr-reviewr` in the shell opens it again on demand. Waited for before the
    # shell split, so the split lands beside the agent and not beside reviewr.
    close_reviewr_pane

    # Closing the worktree's original tab, override path only. It holds one shell
    # resolved to the account this ticket is overriding, and leaving it is the
    # invisible wrong-account state this feature exists to end — so it goes. Only
    # when it holds nothing but the pane Herdr created with it, though: a reviewr
    # pane that turned up after the wait gave up, or anything the developer split
    # off in the seconds this takes, is worth more than a tidy bar.
    if [[ "$ACCOUNT_ORIGIN" == "linked" ]] || agent_on; then
      # herdr_json, not a swallowed listing: if this call fails quietly the answer
      # is an empty list, which reads as "other panes are in there" and leaves the
      # wrong-account shell standing — the one thing closing the tab is for.
      ROOT_TAB_PANES="$(herdr_json "herdr pane list" pane list --workspace "$WORKSPACE_ID" \
        | jq -r --arg t "$ROOT_TAB" '[.result.panes[]? | select(.tab_id == $t) | .pane_id] | @tsv')"
      if [[ "$ROOT_TAB_PANES" == "$ROOT_PANE" ]]; then
        log "closing the worktree's original tab $ROOT_TAB (its shell predates the account link)"
        herdr_json "herdr tab close" tab close "$ROOT_TAB" >/dev/null
      else
        log "warning: leaving the worktree's original tab $ROOT_TAB open — it holds panes this launch didn't create (${ROOT_TAB_PANES:-none listed}). Its shell is on the inherited account, not '$ACCOUNT_NAME'."
      fi
    fi

    split_shell_pane
  fi

  # ---- 3. start Claude Code in the 'agent' tab -------------------------------
  # The agent starts unattended (PERMISSION_MODE), so the guardrail is entirely
  # the tool blocks in DISALLOWED_TOOLS.
  # The roster (SESSION_AGENTS_JSON) was settled before the worktree was made.
  local -a agents_arg=() RESUME_ARGS=()
  [[ -n "$SESSION_AGENTS_JSON" ]] && agents_arg=(--agents "$SESSION_AGENTS_JSON")
  [[ -n "$RESUME_SESSION" ]] && RESUME_ARGS=(--resume "$RESUME_SESSION")
  sleep 1
  if (( HELPER )); then
    log "starting '$AGENT' ($AGENT_KIND, helper on $SESSION_MODEL, effort $SESSION_EFFORT, $SESSION_PERMISSION_MODE) in pane $AGENT_PANE — the developer drives"
  else
    log "starting '$AGENT' ($AGENT_KIND, $COORD_MODEL, effort $COORD_EFFORT, $PERMISSION_MODE) in pane $AGENT_PANE — implementer $IMPL_MODEL, effort $IMPL_EFFORT"
  fi
  log "subagents: $SESSION_AGENTS_STATUS"
  start_agent_retrying

  # Before the exit-3 branch as well as the happy path: an agent stopped at the
  # folder-trust dialog is a started process with an environment to read, and the
  # account it will run under once the dialog is answered is decided already.
  if [[ $START_RC -eq 0 ]] || grep -q 'agent_not_ready' <<<"$START_OUT"; then
    verify_ticket_account
  fi

  if [[ $START_RC -ne 0 ]]; then
    if grep -q 'agent_not_ready' <<<"$START_OUT"; then
      summary
      echo "PENDING: agent '$AGENT' is stopped at a dialog (probably folder trust)." >&2
      echo "Once the user answers it, run:" >&2
      echo "  $SKILL_DIR/scripts/launch.sh prompt $AGENT $PROMPT_FILE" >&2
      exit 3
    fi
    die "failed to start the agent: $START_OUT"
  fi

  # ---- 4. send the ticket ----------------------------------------------------------
  send_prompt "$AGENT" "$PROMPT_FILE"
  summary
}
