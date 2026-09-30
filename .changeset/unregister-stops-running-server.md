---
"directa": patch
---

`directa unregister` now stops a server before removing it if that server is still running, instead of dropping it from tracking while leaving the real process alive and its logs deleted out from under it. An already stopped server unregisters exactly as before.
