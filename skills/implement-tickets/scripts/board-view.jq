# board-view.jq — renders `tk.sh view` as a Trello-style board: one column per
# status, left to right in the order work flows, one card per ticket with its
# model and effort. Input: the rows tk.sh's board_rows builds. Arguments:
#   $W      the pane's width in columns
#   $color  true to colour columns (false under NO_COLOR or when not a terminal)
#   $head   the header line (board, base, clock)
#   $dm $de the launcher's default model and effort, for a ticket that suggests none
# NEEDS YOU comes first: it's the column that wants the developer, and in a
# narrow pane the last columns wrap out of sight.
# Columns with no cards are left out; columns that don't fit side by side wrap
# into further rows of columns, so a half-width pane beside the board session
# still reads.

def pad($w): if length >= $w then .[0:$w] else . + (" " * ($w - length)) end;
def clip($w): if length > $w then .[0:($w - 1)] + "…" else . end;

# Word-wrap to at most $n lines of width $w; the last line ends in … if cut.
def wrap($w; $n):
  (reduce (split(" ")[] | select(. != "")) as $word ([""];
     .[-1] as $cur
     | if ($cur | length) == 0 then .[-1] = ($word | clip($w))
       elif ($cur | length) + 1 + ($word | length) <= $w then .[-1] = $cur + " " + $word
       elif ($cur | length) <= 3 then .[-1] = ($cur + " " + $word | clip($w))   # keep "12" with its word
       else . + [$word | clip($w)] end)) as $lines
  | if ($lines | length) > $n
    then $lines[0:$n] | .[$n - 1] |= ((if length > $w - 2 then .[0:($w - 2)] else . end) + " …")
    else $lines end;

def esc($code): if $color then "\u001b[" + $code + "m" else "" end;

def COLUMNS: [
  {c: "needs",   t: "NEEDS YOU",    k: "1;31"},
  {c: "backlog", t: "BACKLOG",      k: "0"},
  {c: "blocked", t: "BLOCKED",      k: "2"},
  {c: "working", t: "IN PROGRESS",  k: "32"},
  {c: "review",  t: "AGENT REVIEW", k: "33"},
  {c: "human",   t: "HUMAN REVIEW", k: "35"},
  {c: "pr",      t: "PR",           k: "36"},
  {c: "done",    t: "DONE",         k: "2"}
];

# A ticket's card, $cw wide. The last line is what implements it: the run's
# model and effort once launched, or `~` and the ticket's suggestion before.
def card($cw):
  ($cw - 4) as $iw
  | ("\(.nn) \(.title)" | wrap($iw; 2))
    + (if .note != "" then [.note | clip($iw)] else [] end)
    + (if .model != "" then ["\(.model) · \(if .effort != "" then .effort else "-" end)"]
       elif .status == "resolved" then []
       else ["~ \(if .smodel != "" then .smodel else $dm end) · \(if .seffort != "" then .seffort else $de end)"]
       end | map(clip($iw)))
  | ["┌" + ("─" * ($cw - 2)) + "┐"]
    + map("│ " + pad($iw) + " │")
    + ["└" + ("─" * ($cw - 2)) + "┘"];

. as $rows
| [COLUMNS[] | . as $col | ($rows | map(select(.col == $col.c))) as $cards
   | select($cards | length > 0) | $col + {cards: $cards}] as $cols
| ($cols | length) as $n
| (if $W < 24 then 1 else ([1, (($W + 1) / 25 | floor)] | max) end) as $per
| ([$per, $n] | min) as $k
| ([34, (if $k > 0 then (($W - ($k - 1)) / $k | floor) else $W end)] | min) as $cw
| [ $cols[] |
    (if .c == "done" and (.cards | length) > 3
     then .cards[0:3] as $shown | ((.cards | length) - 3) as $more
          | [$shown[] | card($cw)[]] + ["  + \($more) more" | pad($cw)]
     else [.cards[] | card($cw)[]] end) as $body
    | {k, lines: ([(" \(.t)  \(.cards | length)" | pad($cw)), ("━" * $cw)] + $body)} ] as $blocks
| [ range(0; $n; $k) as $i | $blocks[$i:($i + $k)] ] as $lanes
| ([$head | clip($W)] + [""]
   + (if $n == 0 then ["  (no tickets)"] else
       [ $lanes[] | . as $lane
         | ([$lane[].lines | length] | max) as $h
         | (range(0; $h) as $r
            | [ $lane[] | esc(.k) + ((.lines[$r] // "") | pad($cw)) + esc("0") ] | join(" ")),
           "" ]
     end))
| join("\n")
