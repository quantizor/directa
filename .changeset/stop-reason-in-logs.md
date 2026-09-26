---
"directa": patch
---

A dev server's log and event history now say why directa stopped it (a restart, a watch-triggered restart naming the file that changed, a resource lock pausing it, a `down`, or the daemon shutting down), not just the exit code. Before, that reason only ever appeared in the background daemon's own internal log, which macOS does not keep, so `directa logs`, `directa why`, and the event timeline showed the same `exited code=0` for every deliberate stop regardless of cause.
