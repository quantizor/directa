---
"directa": minor
---

`directa logs <name>` now shows only the last 200 lines by default instead of a long-running server's entire history. Pass `--all` for the old full-history behavior, or `--tail`/`--since`/`--since-mark`/`--follow` as before to bound the query yourself.
