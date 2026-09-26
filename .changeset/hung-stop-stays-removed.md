---
"directa": patch
---

Unregistering a server now always leaves it stopped for good. Unregistering it while a restart of it is still in progress no longer starts a copy that nothing keeps track of, and a server whose stop hangs no longer comes back the next time the daemon launches. The same holds for a project directa forgot because its folder was gone, if that folder later comes back.
