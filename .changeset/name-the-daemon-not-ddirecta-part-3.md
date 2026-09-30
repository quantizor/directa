---
"directa": patch
---

A few more messages that led with "ddirecta" (the background daemon's own binary name) now say "the daemon" instead: the install failure when neither a LaunchAgent nor the daemon binary can be found, the app's "asked the app to start it, but it never answered" message, and `directa daemon info`'s human-readable output. The menu bar app's "the daemon is stopped" and "the daemon is not running" rows are now capitalized consistently with the "Starting the daemon…" row beside them. `directa hook install --harness bogus` and `directa hook uninstall --harness bogus` now point at the literal command to run instead of a bare list of supported names.
