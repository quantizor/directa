---
"directa": patch
---

`directa doctor --fix` now actually forgets a leftover registry entry for a project whose checkout is gone (its registry row, trust, and log directory), rather than reporting success while leaving the entry in place, which could otherwise leave a trusted project stuck registered forever with no checkout behind it. The tool still refuses to touch a project whose checkout has reappeared on disk, since forgetting a live project would drop its approval to run its committed config.
