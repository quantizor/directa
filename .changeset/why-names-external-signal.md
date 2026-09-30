---
"directa": patch
---

`directa why` now says when a server was stopped by something other than directa: an IDE stop button, a forwarded Ctrl-C, or another process manager sending a graceful signal (SIGTERM, SIGINT, or SIGHUP). Before, that server showed the same bare "not running (stopped)" as a server directa itself stopped, giving no hint that something outside directa shut it down.
