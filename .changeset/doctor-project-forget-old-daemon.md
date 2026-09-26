---
"directa": patch
---

`directa doctor --fix` now says plainly when the running background daemon is too old to know `project.forget` ("run: directa daemon restart") instead of printing a raw "unknown method" error, and correctly says "1 server" instead of "1 servers" when forgetting a project with exactly one.
