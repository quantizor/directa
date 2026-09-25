---
"directa": patch
---

The background daemon now uses the same small, fixed amount of resources to watch its dev servers no matter how many are running, so a machine running many servers under the app no longer risks the daemon running short of threads. A dev server whose start command runs with elevated privileges (for example `sudo caddy run`) also starts again instead of being torn down as failed.
