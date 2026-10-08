#!/usr/bin/env bash
# Installs the /ticket, /small-ticket, /implement-tickets and /sweep-tickets skills
# and their shared subagents
#
# Usage: ./install.sh [dest ...]   (default: ~/.claude)
# Each dest is a Claude config root, e.g. ~/.claude or ~/.claude-switch/accounts/<name>
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTS=("$@")
[[ ${#DESTS[@]} -gt 0 ]] || DESTS=("$HOME/.claude")

# lib/ticket-*.sh holds the worktree/tab/agent mechanics and the repo/base-branch
# resolution the skills' scripts share. Checked here, before the first file is
# copied: without them nothing installed below would run, and failing halfway
# through the loop would leave a config root half-installed.
LIBS=("$SRC"/lib/ticket-*.sh)
[[ -f "${LIBS[0]}" ]] || { echo "error: no shared libraries found in $SRC/lib — the launchers and /sweep-tickets could not run; nothing was installed" >&2; exit 1; }

for DEST in "${DESTS[@]}"; do
  DEST_SKILLS="$DEST/skills"
  DEST_AGENTS="$DEST/agents"
  mkdir -p "$DEST_SKILLS" "$DEST_AGENTS"

  # /implement-tickets ships the board session's scripts and prompt; its launches reuse /ticket's launcher
  for skill in small-ticket ticket implement-tickets sweep-tickets; do
    mkdir -p "$DEST_SKILLS/$skill"
    cp "$SRC/skills/$skill/SKILL.md" "$DEST_SKILLS/$skill/"
    for dir in scripts templates; do
      [[ -d "$SRC/skills/$skill/$dir" ]] || continue
      cp -r "$SRC/skills/$skill/$dir" "$DEST_SKILLS/$skill/"
    done
    for script in "$DEST_SKILLS/$skill"/scripts/*.sh; do
      [[ -f "$script" ]] && chmod +x "$script"
    done
  done
  cp "$SRC"/agents/*.md "$DEST_AGENTS/"

  # The shell aliases (tkb, tkv, tkhelp, …) — code, so overwritten like the libraries.
  cp "$SRC/shell/ticket-aliases.sh" "$DEST_SKILLS/ticket-aliases.sh"
  echo "installed: $DEST_SKILLS/ticket-aliases.sh"

  # A skill installs as a self-contained directory, so the shared libraries go one
  # level up — the same place config/models.env has always gone — where every
  # installed skill's scripts find them. Unlike that config, these are code:
  # they are overwritten on every install, never kept.
  for lib in "${LIBS[@]}"; do
    cp "$lib" "$DEST_SKILLS/"
    echo "installed: $DEST_SKILLS/$(basename "$lib")"
  done

  # config/models.env is shared by the launch.sh of the three launching skills
  # (small-ticket, ticket, implement-tickets), one level up from the individual
  # skill dirs. /sweep-tickets launches nothing, so it reads no model.
  # Never overwrite a destination copy the developer has hand-edited, since
  # that's the whole point of a per-machine override.
  MODELS_SRC="$SRC/config/models.env"
  MODELS_DEST="$DEST_SKILLS/ticket-models.env"
  if [[ ! -f "$MODELS_SRC" ]]; then
    echo "warning: $MODELS_SRC not found — skipping model config install (skills/agents were still installed)"
  elif [[ ! -f "$MODELS_DEST" ]]; then
    cp "$MODELS_SRC" "$MODELS_DEST"
    echo "installed: $MODELS_DEST"
  elif ! cmp -s "$MODELS_SRC" "$MODELS_DEST"; then
    echo "warning: $MODELS_DEST differs from $MODELS_SRC — keeping the destination copy (hand-edited config is never overwritten)"
  fi

  echo "installed: $DEST_SKILLS/{small-ticket,ticket,implement-tickets,sweep-tickets} and $DEST_AGENTS/ticket-*.md"
done

# Load the aliases from ~/.bashrc: one line, behind a marker, added once. It
# points at the first config root installed into. TICKET_NO_BASHRC=1 skips it,
# TICKET_BASHRC names another rc file (e.g. ~/.zshrc).
RC="${TICKET_BASHRC:-$HOME/.bashrc}"
ALIASES="${DESTS[0]}/skills/ticket-aliases.sh"
if [[ "${TICKET_NO_BASHRC:-0}" == 1 ]]; then
  echo "skipped $RC (TICKET_NO_BASHRC=1) — to load the aliases: . $ALIASES"
elif grep -qF '# ticket-skill aliases' "$RC" 2>/dev/null; then
  echo "aliases: already loaded from $RC"
else
  LINE="$(printf '[ -f %q ] && . %q' "$ALIASES" "$ALIASES")"
  # A managed rc (a symlink into a dotfiles repo or the Nix store, a root-owned
  # file) can't be appended to: say so and print the line, never fail the install
  # over it — the skills are already in place.
  # A managed rc usually loads a per-user hook for exactly this: a ~/.bashrc.d/
  # directory or a ~/.bashrc.local-style file. Use the one it names.
  hook=""
  if [[ -z "${TICKET_BASHRC:-}" && -f "$RC" && ! -w "$(readlink -f "$RC" 2>/dev/null || echo "$RC")" ]]; then
    if grep -qE 'bashrc\.d' "$RC" 2>/dev/null; then hook="$HOME/.bashrc.d/ticket-skill.sh"
    else
      for f in .bashrc.local .bashrc_local .bash_local .bashrc.user .bashrc.custom .bash_aliases .aliases; do
        grep -qF "$f" "$RC" 2>/dev/null && { hook="$HOME/$f"; break; }
      done
    fi
  fi
  if [[ -n "$hook" ]] && grep -qF '# ticket-skill aliases' "$hook" 2>/dev/null; then
    echo "aliases: already loaded from $hook (sourced by $RC)"
  elif [[ -n "$hook" ]] && { mkdir -p "$(dirname "$hook")" && printf '\n# ticket-skill aliases — tkhelp lists them\n%s\n' "$LINE" >>"$hook"; } 2>/dev/null; then
    echo "aliases: $RC isn't writable but loads $hook — added the line there; open a new shell or run: . $ALIASES"
  elif { printf '\n# ticket-skill aliases — tkhelp lists them\n%s\n' "$LINE" >>"$RC"; } 2>/dev/null; then
    echo "aliases: added a line to $RC — open a new shell or run: . $ALIASES"
  else
    target="$RC"; [[ -L "$RC" ]] && target="$RC -> $(readlink -f "$RC" 2>/dev/null || readlink "$RC")"
    echo "warning: can't write $target (not writable) — the aliases weren't added to it."
    echo "  Add this line wherever your shell config is managed (your dotfiles' bashrc, for one):"
    echo "    $LINE"
    echo "  or re-run with TICKET_BASHRC=<a writable rc file sourced by your shell>, or TICKET_NO_BASHRC=1 to skip."
  fi
fi

for cmd in herdr git jq; do
  command -v "$cmd" >/dev/null || echo "warning: '$cmd' not found in PATH"
done
# PRs need the forge's CLI: gh for GitHub, az (+ azure-devops extension) for Azure DevOps.
command -v gh >/dev/null || command -v az >/dev/null \
  || echo "warning: neither 'gh' nor 'az' found in PATH — the board can't open, gate or merge PRs"
# The launchers create worktrees with `herdr worktree create` rather than Omarchy's
# `ga`, and cleanup is /sweep-tickets rather than `gd` — so neither shell function
# is on any path these skills take, and nothing here warns about them. `gd` still
# works by hand on the `../<repo>--<branch>` worktrees, which is why the skills
# mention it; it just isn't a dependency.
