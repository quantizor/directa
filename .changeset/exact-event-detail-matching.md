---
"directa": patch
---

Fixed `directa why` and `directa doctor`'s jetsam-restart count misreading a watch-triggered restart as an externally sent stop signal, or as a daemon restart, whenever the changed file's path happened to contain the literal text "(external)" or "daemon-restart" (a directory or file legitimately named that). Both now recognize only the exact detail directa itself writes for those events.
