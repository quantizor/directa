---
"directa": patch
---

Health reporting now tells the truth about slow and failing servers. A health check's `timeoutMs` now covers the whole check: a server that answers after six or seven seconds passes when the limit is ten, where before every check gave up at five seconds whatever the config said, so a slow cold boot stayed "starting" and then timed out. A check that fails to connect over IPv4 now tries IPv6 only when the connection was refused, and a timeout is no longer retried (which doubled the wait).

`directa status` and `directa why` no longer call a server "running and healthy" when its latest health check failed. A running server whose checks are failing is described as such, with how many failed in a row and why ("HTTP 500", "connection refused", "timed out after 10s"). The same information is in `status --json` as `lastHealthCheck` (absent when no healthcheck is configured), and the session context lists such a server first with a pointer to `directa why`.

When `ensure`, `wait`, `up`, `restart`, or `switch` time out while a server is still starting, the output now says it is still starting, not failed, and names `directa wait <name> --timeout <seconds>` to keep waiting. The exit code is unchanged.
