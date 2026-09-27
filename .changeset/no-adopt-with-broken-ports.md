---
"directa": patch
---

After the daemon restarts, a still-running dev server whose port settings no longer make sense (for example a `directa.local.json` entry that places a named port inside its port span) is no longer silently taken back over with no ports recorded. It is stopped, and the restart reports the configuration error the same way `directa ensure` would.
