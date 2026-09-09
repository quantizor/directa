---
"directa": patch
---

`directa doctor` now warns when the background daemon last exited because macOS jetsammed it, and when leftover one-shot child jobs are still registered after that death. A jetsammed daemon also reaps those leftover jobs on recover, so they do not accumulate across KeepAlive relaunches.
