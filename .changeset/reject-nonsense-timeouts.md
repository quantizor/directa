---
"directa": patch
---

Every `--timeout`/`--acquire-timeout` option (`ensure`, `wait`, `restart`, `up`, `switch`, `lock`) now rejects a non-finite value (`inf`, `nan`) or one outside 0 to 86400 seconds with a clear error, instead of silently accepting it and letting the background daemon quietly clamp it to something else.
