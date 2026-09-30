---
"directa": patch
---

When the daemon restarts and shuts down a leftover dev server it can no longer supervise, a helper process of that server that ignores the polite stop request is now force-stopped too, instead of being left running (and possibly holding the server's port) once the server itself exits.
