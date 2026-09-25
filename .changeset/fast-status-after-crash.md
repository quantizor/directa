---
"directa": patch
---

`directa status` and the menu bar app's polling now answer instantly for a crashed or failed dev server after a daemon restart. Before, each check reread that server's entire log history from disk (current plus rotated files), which could take close to two seconds on a server with a large log, so the menu bar app's regular 2-second check competed with the read it had just finished.
