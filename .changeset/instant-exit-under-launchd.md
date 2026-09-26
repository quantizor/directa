---
"directa": patch
---

When directa runs as the background daemon installed with the app, a dev server whose start command exits immediately (a bad script, a typo'd binary, a config error caught before the server even binds) now reports that it exited, with a real exit code or signal when the process survives long enough for directa to observe it, instead of the unhelpful "never became a session leader" spawn failure. `directa status` and `directa why` can now tell an instant, wrong-command failure apart from directa itself failing to launch the process.
