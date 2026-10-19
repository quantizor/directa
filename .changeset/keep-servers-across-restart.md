---
"directa": minor
---

`directa daemon restart` and `directa daemon install` (an upgrade) no longer stop your running servers. The old daemon steps aside, leaving every server running, and the new daemon picks them up where they are, so open browser tabs, long builds, and in-memory state survive the swap. Any server the new daemon cannot pick up is started again by name, as before. `directa daemon stop`, `directa uninstall` in every form (including the Homebrew upgrade step), a logout, and a machine shutdown still stop every server first, because nothing would be watching them afterward. A daemon started by hand with `--foreground` also still stops its servers when it exits, since only servers run under the background agent can be picked up.
