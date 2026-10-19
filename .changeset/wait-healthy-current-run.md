---
"directa": patch
---

`directa wait --healthy` stays blocked until a health check has passed for the process that is up now. A check from the process it replaced no longer counts, so a restart that is still coming up is not reported ready, and a server whose latest check is failing is not treated as ready either. `directa ensure` waits in that same window instead of returning immediately. Status for the new process no longer shows the previous process's exit.
