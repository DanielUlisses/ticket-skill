# board-view.jq — renders `tk.sh view` as a Trello-style board: one column per
# status, left to right in the order work flows, one rounded card per ticket
# with its checks and its model and effort as chips. Input: the rows tk.sh's
# board_rows builds. Arguments:
#   $W      the pane's width in columns
#   $mode   "true" (24-bit colour), "ansi" (16 colours) or "none"
#   $theme  tokyonight | catppuccin | gruvbox | nord   (truecolour palettes)
#   $board  the board's name;  $base  the ref it merges into;  $clock  HH:MM:SS
#   $dm $de the launcher's default model and effort, for a ticket that suggests none
#
# Layout: every column is shown — empty ones as "—" — when the whole board fits
# on one row; otherwise empty columns drop out and the rest wrap into further
# rows, NEEDS YOU first, so a narrow pane still leads with what wants the
# developer.
#
# Colour is by role, not by code: a theme is a palette of roles, and the 16-colour
# fallback maps the same roles onto plain ANSI. Text is built as segments,
# {t: text, k: code}: widths count the text alone and colour is added last, so a
# coloured chip never shifts a column.

def PALETTES: {
  tokyonight: {bg: "1a1b26", bar: "24283b", fg: "c0caf5", dim: "565f89", faint: "3b4261",
               red: "f7768e", orange: "ff9e64", yellow: "e0af68", green: "9ece6a",
               cyan: "7dcfff", blue: "7aa2f7", magenta: "bb9af7"},
  catppuccin: {bg: "1e1e2e", bar: "313244", fg: "cdd6f4", dim: "6c7086", faint: "45475a",
               red: "f38ba8", orange: "fab387", yellow: "f9e2af", green: "a6e3a1",
               cyan: "89dceb", blue: "89b4fa", magenta: "cba6f7"},
  gruvbox:    {bg: "282828", bar: "3c3836", fg: "ebdbb2", dim: "928374", faint: "504945",
               red: "fb4934", orange: "fe8019", yellow: "fabd2f", green: "b8bb26",
               cyan: "8ec07c", blue: "83a598", magenta: "d3869b"},
  nord:       {bg: "2e3440", bar: "3b4252", fg: "eceff4", dim: "616e88", faint: "434c5e",
               red: "bf616a", orange: "d08770", yellow: "ebcb8b", green: "a3be8c",
               cyan: "88c0d0", blue: "81a1c1", magenta: "b48ead"}
};
# The same roles on the 16 ANSI colours: [foreground, background].
def ANSI: {bg: ["30", "40"], bar: ["37", "100"], fg: ["37", "47"], dim: ["90", "100"],
           faint: ["90", "100"], red: ["31", "41"], orange: ["33", "43"], yellow: ["33", "43"],
           green: ["32", "42"], cyan: ["36", "46"], blue: ["34", "44"], magenta: ["35", "45"]};

def hex2: ascii_downcase | split("") as $c
  | ("0123456789abcdef" | index($c[0])) * 16 + ("0123456789abcdef" | index($c[1]));
def rgb: "\(.[0:2] | hex2);\(.[2:4] | hex2);\(.[4:6] | hex2)";
def pal: PALETTES[$theme] // PALETTES.tokyonight;
# Codes for a role as foreground, as background, and as a chip (dark text on it).
def fg($r):   if $mode == "true" then "38;2;" + (pal[$r] | rgb) elif $mode == "ansi" then ANSI[$r][0] else null end;
def bgc($r):  if $mode == "true" then "48;2;" + (pal[$r] | rgb) elif $mode == "ansi" then ANSI[$r][1] else null end;
def on($f; $b): if $mode == "none" then null else fg($f) + ";" + bgc($b) end;
def bold($r): if $mode == "none" then null else "1;" + fg($r) end;
def chipc($r): if $mode == "none" then null else fg("bg") + ";" + bgc($r) end;

def seg($t; $k): {t: $t, k: $k};
def width: map(.t | length) | add // 0;
def render: map(if .k != null then "\u001b[" + .k + "m" + .t + "\u001b[0m" else .t end) | join("");
# Pad (or cut) a line of segments to exactly $w columns, the padding in $k.
def fitk($w; $k):
  (if width > $w then
     reduce .[] as $s ([];
       (width) as $used
       | if $used >= $w then .
         elif $used + ($s.t | length) <= $w then . + [$s]
         else . + [seg($s.t[0:($w - $used - 1)] + "…"; $s.k)] end)
   else . end)
  | . + [seg(" " * ($w - width); $k)];
def fit($w): fitk($w; null);

def clip($w): if length > $w then .[0:($w - 1)] + "…" else . end;
# Word-wrap to at most $n lines of width $w; the last line ends in … if cut.
def wrap($w; $n):
  (reduce (split(" ")[] | select(. != "")) as $word ([""];
     .[-1] as $cur
     | if ($cur | length) == 0 then .[-1] = ($word | clip($w))
       elif ($cur | length) + 1 + ($word | length) <= $w then .[-1] = $cur + " " + $word
       elif ($cur | length) <= 3 then .[-1] = ($cur + " " + $word | clip($w))
       else . + [$word | clip($w)] end)) as $lines
  | if ($lines | length) > $n
    then $lines[0:$n] | .[$n - 1] |= ((if length > $w - 2 then .[0:($w - 2)] else . end) + " …")
    else $lines end;

# Column: id, title, icon, who acts there, accent role.
def COLUMNS: [
  {c: "needs",   t: "Needs you",    i: "!", who: "you",      r: "red"},
  {c: "backlog", t: "Backlog",      i: "○", who: "ready",    r: "fg"},
  {c: "blocked", t: "Blocked",      i: "⊘", who: "waiting",  r: "dim"},
  {c: "working", t: "In progress",  i: "◐", who: "agent",    r: "green"},
  {c: "review",  t: "Agent review", i: "◑", who: "reviewer", r: "yellow"},
  {c: "human",   t: "Human review", i: "◉", who: "you",      r: "magenta"},
  {c: "pr",      t: "PR",           i: "⇡", who: "github",   r: "cyan"},
  {c: "done",    t: "Done",         i: "✓", who: "merged",   r: "dim"}
];

def model_role($m): if ($m | test("opus")) then "magenta" elif ($m | test("sonnet")) then "blue"
  elif ($m | test("haiku")) then "green" elif ($m | test("fable")) then "orange" else "fg" end;

# A chip: the label on its role's colour. Without colour, brackets stand in.
def chip($label; $r): if $mode != "none" then seg(" " + $label + " "; chipc($r)) else seg("[" + $label + "]"; null) end;

def slug: (.title | ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | sub("-+$"; "")) as $fromtitle
  | if .branch != "" and (.branch | test("^[a-z]+-[0-9]+-.")) then (.branch | sub("^[a-z]+-[0-9]+-"; ""))
    else $fromtitle end;

# A ticket's card, $cw wide: a rounded border (faint; in NEEDS YOU the accent), then
#   NN · slug              the ticket and the branch's slug
#   Title                  bold, up to two lines
#   note · R2              where it stands, in the column's accent, with the review round
#   [tests] [3/4] [rev 2!] the coordinator's last checks — green pass, yellow partial, red failing
#   branch                 dim, once launched
#   [model] [effort]       what implements it; `~` first when it's the ticket's
#                          suggestion (or the default), not a launched run
#   → hint                 what to type into the board session to move the card on
def card($cw; $col):
  ($cw - 4) as $iw
  | (if $col.c == "needs" then fg("red") else fg("faint") end) as $bk
  | . as $t
  | [ [seg($t.nn; bold($col.r)), seg(" · " + ($t | slug); fg("dim"))] ]
    + [ $t.title | wrap($iw; 2)[] | [seg(.; bold("fg"))] ]
    + (if $t.note != "" then
         [[seg($t.note; fg($col.r))] + (if ($t.round // "") != "" then [seg(" · " + ($t.round | ascii_upcase); fg("dim"))] else [] end)]
       else [] end)
    + (($t.checks // {}) as $c
       | if ($c | length) == 0 then [] else
         [ (if $c.tests then [chip("tests"; if $c.tests == "pass" then "green" elif $c.tests == "fail" then "red" else "faint" end), seg(" "; null)] else [] end)
           + (if $c.criteria then ($c.criteria | split("/")) as $m
                | [chip($c.criteria; if ($m | length) == 2 and $m[0] == $m[1] then "green" else "yellow" end), seg(" "; null)] else [] end)
           + (if $c.review then [chip(if $c.review == "ok" then "rev ✓" else "rev " + ($c.review | sub("-blocking"; "!")) end;
                                     if $c.review == "ok" then "green" else "red" end)] else [] end) ]
         end)
    + (if $t.branch != "" then [[seg($t.branch; fg("dim"))]] else [] end)
    + (if $t.model != "" then
         [[chip($t.model; model_role($t.model)), seg(" "; null), chip(if $t.effort != "" then $t.effort else "-" end; "faint")]]
       elif $t.status == "resolved" then []
       else
         (if $t.smodel != "" then $t.smodel else $dm end) as $m
         | [[seg("~ "; fg("dim")), chip($m; model_role($m)), seg(" "; null),
             chip(if $t.seffort != "" then $t.seffort else $de end; "faint")]]
       end)
    + (if ($t.hint // "") != "" then [[seg("→ " + $t.hint; bold($col.r))]] else [] end)
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
    | ([seg($col.i + " "; bold($col.r)), seg($col.t; bold($col.r)), seg("  \($count)"; fg("dim"))]) as $title
    # The subtitle only where it fits whole — a clipped one reads as noise.
    | [ ((if ($title + [seg("  " + $col.who; null)] | width) <= $cw
          then $title + [seg("  " + $col.who; fg("faint"))] else $title end) | fit($cw)),
        [if $count > 0 then seg("━" * $cw; fg($col.r)) else seg("─" * $cw; fg("faint")) end],
        ([seg(""; null)] | fit($cw)) ]
      + (if $count == 0 then [ [seg(" " * (($cw - 1) / 2 | floor) + "—"; fg("faint"))] | fit($cw) ]
         else
           (if $col.c == "done" and $count > 3 then $col.cards[0:3] else $col.cards end) as $shown
           | [ $shown[] | (card($cw; $col) + [ [seg(""; null)] | fit($cw) ])[] ]
             + (if $col.c == "done" and $count > 3 then [ [seg("  + \($count - 3) more"; fg("dim"))] | fit($cw) ] else [] end)
         end) ] as $blocks
| [ range(0; $n; $k) as $i | $blocks[$i:($i + $k)] ] as $lanes
| ($rows | map(select(.col | IN("working", "review"))) | length) as $active
| ($rows | map(select(.col == "needs")) | length) as $needs
| ($rows | map(select(.col == "done")) | length) as $done
# The header bar: a status dot, the board, and the counts that matter, on a band of colour.
| ([ seg(" ● "; on(if $needs > 0 then "red" elif $active > 0 then "green" else "dim" end; "bar")),
     seg($board; if $mode == "none" then null else "1;" + on("fg"; "bar") end),
     seg("  " + $base; on("dim"; "bar")),
     seg("   \($active) active"; on("green"; "bar")),
     (if $needs > 0 then seg("  ·  \($needs) need you"; if $mode == "none" then null else "1;" + on("red"; "bar") end) else seg(""; null) end),
     seg("  ·  \($done)/\($rows | length) done"; on("dim"; "bar")) ]
   | fitk($W - 9; bgc("bar")) + [seg($clock + " "; on("dim"; "bar"))]) as $bar
| ([ $bar | render ] + [""]
   + [ $lanes[] | . as $lane
       | ([$lane[] | length] | max) as $h
       | (range(0; $h) as $r
          | [ $lane[] | (.[$r] // ([seg(""; null)] | fit($cw))) | render ] | join(" " * $gap)),
         "" ])
| join("\n")
