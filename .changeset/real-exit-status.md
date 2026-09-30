---
"directa": patch
---

When directa runs as the background daemon installed with the app, it now records the real reason a dev server exited. Before, every exit read as a clean `code=0`, so a server that failed with an error or was killed by a signal looked the same as one that quit normally in `directa status`, `directa why`, and the event history. The warning for a server stuck waiting on an interactive login can now appear for these servers too.
