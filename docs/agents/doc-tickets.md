# Document tickets: types and where they are built

A board ticket with `**Kind:** doc` launches `/ticket`'s unattended doc brief
(`skills/ticket/templates/ticket-doc-prompt.md`, ADR 0007). Its `**Doc type:**`
line picks what fills the brief's `{{DOC_GUIDANCE}}` (`resolve_doc_guidance`,
`lib/ticket-launcher.sh`):

| Doc type | Built with | Validator | Artifact |
| --- | --- | --- | --- |
| `tdd`, `hlr` | pythian-docs: Markdown chapters + `document.yaml` | `pdocs check <folder>` | `pdocs pdf <folder>` → `<folder>/out/*.pdf` |
| `ead` | the installed `ead` skill | its `check_ead.py` | the skill's output (unchanged) |
| `other` (or no line) | the generic brief | whatever the seams line names | whatever the outline names |

An unknown type is refused at launch. `TICKET_DRY_RUN=1` shows which guidance a
ticket gets on the summary's `KIND=` line.

## pythian-docs types (`tdd`, `hlr`)

pythian-docs (`DanielUlisses/pythian-docs`) turns a folder of numbered Markdown
chapters and one `document.yaml` into a Pythian-format PDF. Its `AGENTS.md` and
`README.md` are the rules; the brief sends the drafter there. The paste-ready
HTML flow of tdd-skill is not used for board tickets any more: tdd-skill's
ADR-0002 is superseded by its ADR-0003, which lives in the tdd-skill repo (see
tdd-skill below).

**Where the checkout is.** `TICKET_PDOCS_DIR`, default `~/work/pythian-docs`,
read by the launcher at launch. Usable means `<dir>/pdocs` is executable and
`<dir>/types/<type>/document.yaml` exists; otherwise one `WARN` and the generic
brief, never a refusal (the same rule `ead` follows). The checkout must be
current — `git -C <pdocs-dir> pull` before a board's first pythian-docs ticket:
the brief sends the drafter to its `AGENTS.md`, and a checkout without one gets a
`WARN` and a brief that starts at `README.md`. The types pythian-docs has
are the folders of its `types/`; `PDOCS_DOC_TYPES` in the launcher lists the
ones the board accepts.

**Where the document lives.** `pdocs` builds only a folder inside its own
checkout (it mounts nothing else into Docker). So the ticket's repo is the
client's own repo, `clients/<client>/` in pythian-docs, made once by the
developer with:

```bash
cd ~/work/pythian-docs
./pdocs new <client> <type> --git     # clients/<client>/ becomes a git repo, out/ ignored
git -C clients/<client> add . && git -C clients/<client> commit -m "<type> skeleton"
```

and the board runs in that repo. A ticket's worktree is `../<repo>--<branch>`,
which puts it in `clients/` as well, so `pdocs` can reach it; `clients/` is
ignored by pythian-docs, so nothing lands in pythian-docs' own history. A
worktree outside the checkout's `clients/` launches with a `WARN`, and its `pdocs check`
fails: the checks gate then refuses the merge.

**The client and the folder.** The client is the repo (its directory name is
the client slug `pdocs new` was given). The document folder is
`<worktree>/<type>/` — `tdd/` or `hlr/`, the layout `pdocs new` makes — unless
the ticket's `## Outline` names another folder in the repo. When the folder
isn't there yet the drafter copies `types/<type>/` into the worktree itself,
as `pdocs new` would; `pdocs new` writes to the main checkout, not the worktree.

**What the ticket says.** The `## Outline`'s sections become the chapters
(`NN-slug.md`, appendices `A-slug.md`), starting from the type's stub chapters.
The seams line is
`None — verify with <pdocs-dir>/pdocs check <type>/`. `pdocs check` exits 0
only when nothing is unfinished or broken, so `tests=pass` — the checks gate's
condition for a local merge — means a clean document. The drafter builds the
PDF with `pdocs pdf` and reads it before calling the document done; the PDF is
never committed (`out/` is ignored). `pdocs pdf` writes `built_with` into
`document.yaml` itself, so that line changes in the diff; nobody edits it by
hand.

**Review.** `ticket-doc-reviewer` reads the chapters and the built PDF (the
cover, the order, anything cut off or wider than the page), with the
`pdocs check` output. The cover's status matches `document.yaml`'s `status`;
a Draft footer forced onto it means the check was not clean.

**Docker.** Both commands run in Docker, and the first builds an image (a few
minutes), so the brief asks for a 10-minute timeout on the first `pdocs`
command. The session that runs them needs Docker access. With the agent user
on (ADR 0011), that is `<user>-agent`: whether it can reach the Docker daemon
is the box's setup, not this repo's — an assumption to check before the first
pythian-docs ticket runs as the agent user.

## Provider terminology

tdd-skill keeps per-provider material under
`/home/daniel/work/tdd-skill/references/<provider>/` (`TICKET_TDD_SKILL_DIR`,
default `~/work/tdd-skill`, read by the launcher), one folder each for `aws`,
`azure` and `gcp`:

- `terminology.md`: a table of the provider's standard terms (accounts,
  subscriptions or projects, networking, identity, firewall) with the TDD
  section each usually appears in;
- `references.md`: the provider's own primary sources (Well-Architected,
  landing zones, network and connectivity docs), to start from before
  researching a design decision.

It is reference material for a drafter naming a provider's services, not a
rule any tool enforces, and pythian-docs has no checker for it. Where the
folder is on the machine, the brief names it and tells the drafter to read the
provider's files before naming its services; where it isn't, the brief says
so. Nothing is copied into this repo. When tdd-skill is archived the files need
a new home a drafter can read, such as pythian-docs' `docs/` (an assumption
about where they fit best, not a decision made here).

## tdd-skill

tdd-skill stays installed as the fallback for a TDD written outside the board.
It is not archived until a client TDD (Gusto's) has been issued from
pythian-docs; archiving is the developer's call. On the board a missing
pythian-docs checkout means the generic brief, never tdd-skill. tdd-skill's
ADR-0002 (HTML-only TDDs) is superseded by its ADR-0003 (TDDs built in
pythian-docs, tdd-skill the fallback until Gusto's TDD is issued from there),
which lives in the tdd-skill repo.

## Contracts

`tk.sh validate`'s `docs[]` reads the Contracts rows of HTML files through
`check_ead.py` / `check_tdd.py --contracts`. A pythian-docs document is Markdown,
so its `docs[]` is empty; an older `tdd` ticket that wrote HTML is still read
while tdd-skill's checker is installed (`docs/agents/contracts.md`).
