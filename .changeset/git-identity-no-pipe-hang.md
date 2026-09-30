---
"directa": patch
---

Fixed sibling-port rebind and worktree detection hanging indefinitely against a git checkout that prints a long warning (a "detached HEAD" or "unsafe repository" notice, for example) before answering.
