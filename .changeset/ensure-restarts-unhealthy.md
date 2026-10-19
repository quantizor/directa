---
"directa": patch
---

`directa ensure` now restarts a server whose status reads `unhealthy` (its health checks failed several times in a row after it had been healthy) and waits until the new run is healthy, instead of returning the broken server as it was. The restart is the same single step `directa restart` takes, including the check that no leftover process still holds the server's port, and the events log records it as a stop with the detail `restarted by ensure: unhealthy`. Two sessions ensuring the same unhealthy server at once cause one restart. A server that is `running` while its latest check is failing is still waited on, not restarted.
