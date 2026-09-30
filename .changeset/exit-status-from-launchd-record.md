---
"directa": patch
---

When macOS will not tell the background daemon how a dev server exited, directa now reads the exit code or signal from the record launchd keeps for that server, instead of reporting the exit as unknown in `directa status`, `directa why`, and the event history.
