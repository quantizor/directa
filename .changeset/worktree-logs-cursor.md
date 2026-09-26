---
"directa": patch
---

Commands run inside a git worktree now act on that worktree's own servers. Before, a worktree nested inside its main checkout (the layout Claude Code uses for isolated agents) could pick up the main checkout's `devservers.json` and act on the main checkout's servers without saying so. When a worktree has no config of its own, the not-found message says how to fix it: commit or copy `devservers.json` into the worktree, or pass `--project`. One setup changes: a bare repository with a worktree per branch and a single `devservers.json` in the parent folder now needs `--project` or a config in each worktree.

`directa logs --follow` now streams reliably through a pipe. Lines arrive as they are written instead of sitting in a buffer, lines written in the same millisecond are never dropped or repeated, and a follow that starts before the server has printed anything no longer re-reads the whole log on every poll. The new `--head N` option reads the oldest lines from a starting point, for catching up on a stretch of output in order. Log queries over large histories are also much faster and use far less memory.
