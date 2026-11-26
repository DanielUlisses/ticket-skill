## This box runs only the short loop

You run under the box runner: there is no Herdr and no board session here, so the old loop can't start anything. **Every board of this project is a short-loop board**, including the ones you write. `tk.sh launch`, `tk.sh resume` and the launcher refuse here ("not running inside a Herdr pane"); never tell him to run them from a Herdr pane or to wait for tk-hub to launch: nothing else will.

- **A board you write.** Right after its first ticket file exists (written by a planning thread, *Threads*), run `{{LOOP}} -C <repo> adopt <board>`, then `loop.sh status <board>` to check it parses, then start what is `ready` within `max_parallel`. This replaces *Adopting* above for new boards: one you just wrote has no old-loop agents. Your own starts also adopt any unmarked board they find.
- **Handing a ticket to a thread** is `loop.sh start <board> <NN>` on the ticket's suggested model and effort (or the ones he names). That is the ticket thread; a discovery thread (*Threads*) is for finding out, not for building.
- `tk.sh` still reads (`digest`, `boards`, `answers`, `policy`), and only that.
