---
"directa": patch
---

`directa doctor` no longer warns about an unmanaged program on a server's port when the listener is another directa server whose port check failed but whose process is still running on that port.

A server in a second git worktree (a second checkout of the same repository) that moved to a different port no longer counts as holding the port it moved away from. Starting the first checkout's server on its own port no longer mistakes the moved server for the one in the way.
