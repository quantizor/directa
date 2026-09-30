---
"directa": patch
---

Fixed the background daemon leaking two threads and their file descriptors every time it tried to read git information (for sibling-port rebind, or worktree detection) from a working directory that could not actually be used to run a process (a checkout mid-move, an invalid path). Repeated failures no longer accumulate; a normal git checkout is unaffected.
