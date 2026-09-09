---
"directa": patch
---

Replacing `/Applications/directa.app` from a mounted DMG now stops the background agent (the installer used to hang on that step) and quits after a successful copy, so the disk can be ejected.
