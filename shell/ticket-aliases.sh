# ticket-aliases.sh — short shell commands for the ticket workflow.
#
# Installed by install.sh as ~/.claude/skills/ticket-aliases.sh and sourced from
# ~/.bashrc (one guarded line; TICKET_NO_BASHRC=1 at install time skips it).
# Works in bash and zsh. `tkhelp` lists everything.
#
# A board is a Jira id or slug under .scratch/ (itm-9909), or a path. Every
# command that takes one falls back to $TK_BOARD (set it with `tkuse`), and then
# to the only board in the repo when there is just one.

if [ -n "${BASH_SOURCE:-}" ]; then _tk_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else _tk_here="$(cd "$(dirname "${(%):-%x}")" 2>/dev/null && pwd)"; fi
TK_SCRIPTS="${TK_SCRIPTS:-$_tk_here/implement-tickets/scripts}"
unset _tk_here

tk()     { "$TK_SCRIPTS/tk.sh" "$@"; }
tkhelp() { "$TK_SCRIPTS/tk.sh" help; }
# The current board for this shell: `tkuse itm-9909`; `tkuse` alone shows it.
tkuse()  { if [ -n "${1:-}" ]; then export TK_BOARD="$1"; fi; echo "board: ${TK_BOARD:-<auto: the only board in .scratch/>}"; }

# Start the Haiku board session (and its tickets tab): tkb [board]
tkb()    { "$TK_SCRIPTS/board.sh" "${1:-${TK_BOARD:-}}"; }
# Print the board session's claude command without starting it: tkbp [board]
tkbp()   { "$TK_SCRIPTS/board.sh" --print "${1:-${TK_BOARD:-}}"; }
# The status board, full-screen and refreshing (q quits, r refreshes): tkv [board] [secs]
tkv()    { "$TK_SCRIPTS/tk.sh" view "${1:-${TK_BOARD:-}}" --watch "${2:-30}"; }
# The status board, printed once: tkvv [board]
tkvv()   { "$TK_SCRIPTS/tk.sh" view "${1:-${TK_BOARD:-}}"; }
# Board, agents and git in one read: tkd [board]
tkd()    { "$TK_SCRIPTS/tk.sh" digest "${1:-${TK_BOARD:-}}" --full; }
# Every in-progress ticket whose PR passes all five gates: tkr [board]
tkr()    { "$TK_SCRIPTS/tk.sh" ready "${1:-${TK_BOARD:-}}"; }

# Commands about one ticket take [board] NN — the board may be left out when
# TK_BOARD is set or the repo has one board: tkg 05, or tkg itm-9909 05.
_tk_one() { local verb="$1"; shift
  if [ "$#" -ge 2 ]; then "$TK_SCRIPTS/tk.sh" "$verb" "$@"
  else "$TK_SCRIPTS/tk.sh" "$verb" "${TK_BOARD:-}" "$@"; fi; }
tkg()    { _tk_one gates "$@"; }      # the five merge gates for one ticket
tks()    { _tk_one show "$@"; }       # what one ticket's agent is doing
tkw()    { _tk_one why "$@"; }        # why a ticket does or doesn't count as landed
