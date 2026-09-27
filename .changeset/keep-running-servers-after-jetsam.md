---
"directa": patch
---

After macOS kills the background daemon to free memory, a dev server that is still running is picked up again instead of being stopped and started. If macOS does not answer when the daemon asks which of those servers are still running, the daemon leaves them running rather than restarting them.
