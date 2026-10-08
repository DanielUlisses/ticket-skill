# board-view.jq — renders `tk.sh view` as a Trello-style board: one column per
# status, left to right in the order work flows, one rounded card per ticket
# with its model and effort as chips. Input: the rows tk.sh's board_rows builds.
# Arguments:
#   $W      the pane's width in columns
#   $color  true to colour (false under NO_COLOR or when not a terminal)
#   $head   the header line (board, base, clock)
#   $dm $de the launcher's default model and effort, for a ticket that suggests none
#
# Layout: every column is shown — empty ones as "—" — when the whole board fits
# on one row; otherwise empty columns drop out and the rest wrap into further
# rows, NEEDS YOU first, so a narrow pane still leads with what wants the
# developer.
#
# Text is built as segments, {t: text, k: ANSI code or null}: widths are counted
# on the text alone and colour is added last, so a coloured chip never shifts a
# column.

def esc($code): if $color and $code != null then "\u001b[" + $code + "m" else "" end;
def reset: if $color then "\u001b[0m" else "" end;

def seg($t; $k): {t: $t, k: $k};
def width: map(.t | length) | add // 0;
def render: map(if .k != null then esc(.k) + .t + reset else .t end) | join("");
# Pad (or cut) a line of segments to exactly $w columns.
def fit($w):
  (if width > $w then
     reduce .[] as $s ([];
       (width) as $used
       | if $used >= $w then .
         elif $used + ($s.t | length) <= $w then . + [$s]
         else . + [seg($s.t[0:($w - $used - 1)] + "…"; $s.k)] end)
   else . end)
  | . + [seg(" " * ($w - width); null)];

def clip($w): if length > $w then .[0:($w - 1)] + "…" else . end;
# Word-wrap to at most $n lines of width $w; the last line ends in … if cut.
def wrap($w; $n):
  (reduce (split(" ")[] | select(. != "")) as $word ([""];
     .[-1] as $cur
     | if ($cur | length) == 0 then .[-1] = ($word | clip($w))
       elif ($cur | length) + 1 + ($word | length) <= $w then .[-1] = $cur + " " + $word
       else . + [$word | clip($w)] end)) as $lines
  | if ($lines | length) > $n
    then $lines[0:$n] | .[$n - 1] |= ((if length > $w - 2 then .[0:($w - 2)] else . end) + " …")
    else $lines end;

# Column: id, title, who acts there (the header's dim subtitle), accent colour.
def COLUMNS: [
  {c: "needs",   t: "Needs you",    who: "you",      k: "1;31"},
  {c: "backlog", t: "Backlog",      who: "ready",    k: "37"},
  {c: "blocked", t: "Blocked",      who: "waiting",  k: "90"},
  {c: "working", t: "In progress",  who: "agent",    k: "32"},
  {c: "review",  t: "Agent review", who: "reviewer", k: "33"},
  {c: "human",   t: "Human review", who: "you",      k: "35"},
  {c: "pr",      t: "PR",           who: "github",   k: "36"},
  {c: "done",    t: "Done",         who: "merged",   k: "90"}
];

def model_k($m): if ($m | test("opus")) then "30;45" elif ($m | test("sonnet")) then "30;44"
  elif ($m | test("haiku")) then "30;42" elif ($m | test("fable")) then "30;43" else "30;47" end;

# A chip: the label on a coloured background, padded by a space each side.
# Without colour, brackets stand in for the background.
def chip($label; $k): if $color then seg(" " + $label + " "; $k) else seg("[" + $label + "]"; null) end;

def slug: (.title | ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | sub("-+$"; "")) as $fromtitle
  | if .branch != "" and (.branch | test("^[a-z]+-[0-9]+-.")) then (.branch | sub("^[a-z]+-[0-9]+-"; ""))
    else $fromtitle end;

# A ticket's card, $cw wide: rounded border (accented in NEEDS YOU), then
#   NN · slug        the ticket and the branch's slug
#   Title            bold, up to two lines
#   note             where it stands, in the column's colour
#   branch           dim, once launched
#   [model] [effort] what implements it — `~` before the chips when it's the
#                    ticket's suggestion (or the default), not a launched run
def card($cw; $col):
  ($cw - 4) as $iw
  | (if $col.c == "needs" then $col.k else "90" end) as $bk
  | . as $t
  | [ [seg($t.nn; "1;" + $col.k), seg(" · " + ($t | slug); "2")] ]
    + [ $t.title | wrap($iw; 2)[] | [seg(.; "1")] ]
    + (if $t.note != "" then [[seg($t.note; $col.k)]] else [] end)
    + (if $t.branch != "" then [[seg($t.branch; "2")]] else [] end)
    + (if $t.model != "" then
         [[chip($t.model; model_k($t.model)), seg(" "; null),
           chip(if $t.effort != "" then $t.effort else "-" end; "30;47")]]
       elif $t.status == "resolved" then []
       else
         (if $t.smodel != "" then $t.smodel else $dm end) as $m
         | [[seg("~ "; "2"), chip($m; model_k($m)), seg(" "; null),
             chip(if $t.seffort != "" then $t.seffort else $de end; "30;47")]]
       end)
  | [ [seg("╭" + ("─" * ($cw - 2)) + "╮"; $bk)] ]
    + map([seg("│ "; $bk)] + fit($iw) + [seg(" │"; $bk)])
    + [ [seg("╰" + ("─" * ($cw - 2)) + "╯"; $bk)] ];

. as $rows
| 3 as $gap | 26 as $minw | 38 as $maxw
| ([COLUMNS[] | . as $col | $col + {cards: ($rows | map(select(.col == $col.c)))}]) as $all
| (if $W < $minw then 1 else ([1, (($W + $gap) / ($minw + $gap) | floor)] | max) end) as $per
| (if $per >= ($all | length) then $all else [$all[] | select(.cards | length > 0)] end) as $cols
| ($cols | length) as $n
| ([$per, ([$n, 1] | max)] | min) as $k
| ([$maxw, (($W - ($k - 1) * $gap) / $k | floor)] | min) as $cw
| [ $cols[] | . as $col
    | (.cards | length) as $count
    | ([seg("\($count) › "; "2"), seg($col.t; "1;" + $col.k)]) as $title
    # The subtitle only where it fits whole — a clipped one reads as noise.
    | [ ((if ($title + [seg("  " + $col.who; null)] | width) <= $cw
          then $title + [seg("  " + $col.who; "2")] else $title end) | fit($cw)),
        [seg("─" * $cw; if $count > 0 then $col.k else "90" end)],
        ([seg(""; null)] | fit($cw)) ]
      + (if $count == 0 then [ [seg("  —"; "2")] | fit($cw) ]
         else
           (if $col.c == "done" and $count > 3 then $col.cards[0:3] else $col.cards end) as $shown
           | [ $shown[] | (card($cw; $col) + [ [seg(""; null)] | fit($cw) ])[] ]
             + (if $col.c == "done" and $count > 3 then [ [seg("  + \($count - 3) more"; "2")] | fit($cw) ] else [] end)
         end) ] as $blocks
| [ range(0; $n; $k) as $i | $blocks[$i:($i + $k)] ] as $lanes
| ([ [seg($head; "2")] | fit($W) | render ] + [""]
   + [ $lanes[] | . as $lane
       | ([$lane[] | length] | max) as $h
       | (range(0; $h) as $r
          | [ $lane[] | (.[$r] // ([seg(""; null)] | fit($cw))) | render ] | join(" " * $gap)),
         "" ])
| join("\n")
