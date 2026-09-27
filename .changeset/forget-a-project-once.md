---
"directa": patch
---

When `directa doctor --fix` forgets a vanished project while the daemon's own cleanup is already removing it, the project's servers are now stopped and recorded as unregistered once, not twice.
