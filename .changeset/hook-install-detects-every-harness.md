---
"directa": minor
---

`directa hook install` with no `--harness` now installs into every supported agent harness detected on your machine (Claude Code, Cursor, Grok Build, OpenCode, Antigravity), printing one line for each harness installed and one for each skipped as not detected, instead of only Claude Code. It fails with a clear error, naming the harnesses it checked, if none is detected at all. Passing `--harness` still installs exactly that one harness, whether or not it is detected.
