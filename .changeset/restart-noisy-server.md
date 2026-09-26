---
"directa": patch
---

Restarting a dev server that prints a lot of output no longer takes down the background daemon. Before, the daemon's memory could climb to several gigabytes in seconds until macOS killed it, stopping every other server's supervision with it. A stop that cannot finish now gives up after a bounded wait and notes it in that server's log instead of hanging the command.
