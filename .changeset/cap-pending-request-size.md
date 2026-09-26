---
"directa": patch
---

The background daemon's control socket now refuses a request that streams past 1 MiB without ever sending a newline to end it, instead of letting a misbehaving client grow the daemon's memory without limit. This never affects the `directa` command or the menu bar app, which always send small, complete requests; it only guards a client writing to the socket directly.
