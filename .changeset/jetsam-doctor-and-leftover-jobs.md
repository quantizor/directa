---
"directa": patch
---

`directa doctor` now warns when macOS killed the background daemon to free memory (jetsam), and when leftover server-process entries are still registered after that death. The daemon also cleans those leftovers up when it comes back, so they do not pile up across automatic restarts.
