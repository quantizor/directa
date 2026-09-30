---
"directa": patch
---

A dev server that was running when the background daemon restarted now comes back once a resource lock it depends on is released, instead of staying marked crashed until someone runs `directa ensure`. (A resource lock is what `directa lock` holds while a command like a database migration runs.) A server the daemon stopped on its way down now reads stopped rather than crashed when it cannot be brought back right away.
