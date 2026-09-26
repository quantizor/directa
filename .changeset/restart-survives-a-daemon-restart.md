---
"directa": patch
---

`directa restart` no longer fails with "daemon closed the connection" when the daemon goes away in the middle of it (for example when macOS stops it under memory pressure and it starts again). The command now waits for the daemon to come back, checks the server, and finishes the restart from where it stopped, so it does not restart the server a second time. Before, the error invited running the command again, which bounced a server that had already come back.
