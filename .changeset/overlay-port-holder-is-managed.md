---
"directa": patch
---

A dev server running on the port its checkout's `directa.local.json` gives it is now recognized as directa's own when another project asks for that port, even right after a daemon restart. Before, `directa ensure` and `directa status` could call it an unknown process holding the port, and a sibling worktree could not rebind around it.
