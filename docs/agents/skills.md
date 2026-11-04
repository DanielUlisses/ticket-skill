# Catalog skills: the policy's `skills`

A board can give its tickets skills that are not installed for every session: Terraform,
Helm, a cloud provider's conventions. They come from the private **skills-catalog** repo
(`DanielUlisses/skills-catalog`), which devboxes syncs, per client and off by default, to
`/opt/skills/<name>/` on the box, with `/opt/skills/index.json` listing what is there. That
directory is outside `~/.claude/skills` on purpose: a catalog skill is on only where a board
asks for it.

## Turning one on

The policy key `skills` is a list of names (`[a-z0-9][a-z0-9._-]*`), layered like every other
key (docs/agents/policy.md): the box, the repo (`.scratch/policy.json`) or one board.

```
tk.sh policy-set <board> 'skills=["terraform","helm"]'
tk.sh policy-set <board> skills=          # back to what the repo or the box says
```

tk-hub's project Skills tab writes the same key on every board of the project.

## At launch

- `tk.sh launch` resolves the board's list and passes it to the launcher as `--skills a,b`.
  A launch with no board (`/ticket`, `/small-ticket`) reads the box and repo layers itself.
- The launcher links each name that `${TICKET_SKILLS_CATALOG:-/opt/skills}/<name>/SKILL.md`
  exists for into `<worktree>/.claude/skills/<name>` (a symlink) and adds
  `/.claude/skills/<name>` to the repo's `info/exclude`, right after the worktree is made and
  before any pane starts. The agent sees it as a project skill; nothing is committed.
- A name the catalog doesn't hold is skipped, never fatal. A repo that ships its own
  `.claude/skills/<name>` keeps it.
- The summary's `SKILLS=` line names what was linked and why (`board`, `policy`, `none`), plus
  any name left out. `tk.sh launch` records the linked ones as the ticket's `**Skills:**`
  run-state line (`none` for none), so `tk.sh export` carries `skills` per ticket and tk-hub can
  compare tickets run with a skill against those run without.
