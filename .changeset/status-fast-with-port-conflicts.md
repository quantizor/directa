---
"directa": patch
---

`directa status --all` and the menu bar stay quick when many stopped servers have a port held by another server. Each of those servers used to cost two `git` runs on every status read, which added up to seconds with a few dozen worktrees; the check now reads the checkout's own files instead.
