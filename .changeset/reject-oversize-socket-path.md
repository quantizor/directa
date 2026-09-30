---
"directa": patch
---

An extremely long `DIRECTA_SOCKET` override used to make the background daemon fail silently: it printed a "listening" line and kept running, but never actually opened a socket, so every command timed out with no clear reason why. The daemon now refuses to start in that case with a clear error naming the offending path, matching what the CLI already reported when it hit the same limit.
