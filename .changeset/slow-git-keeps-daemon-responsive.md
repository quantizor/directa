---
"directa": patch
---

The background daemon stays responsive while `git`, `launchctl`, or a port lookup is slow. A checkout on a slow network drive or a stuck repository could tie up the threads the daemon uses for everything else, so `directa status`, starts, and health checks all stalled together, and a burst of those calls could push the daemon past the thread limit macOS gives it. Those commands now wait on a small, fixed set of their own threads, repository reads never hold up starting or supervising servers, and a `git` read that hangs is stopped after a short timeout.
