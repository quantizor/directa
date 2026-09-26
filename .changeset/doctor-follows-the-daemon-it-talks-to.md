---
"directa": minor
---

`directa doctor` now checks the files of the daemon it is talking to. Pointed at a separate daemon (for example one started for a test with its own data and logs folders), it reads that daemon's update notice cache and saved PATH instead of the ones in your home folder, so a test run no longer touches your real directa data. The CLI also accepts `DIRECTA_DATA_DIR` and `DIRECTA_LOGS_DIR` to name its own data and logs folders; with either one (or `DIRECTA_SOCKET`) set, it never installs or starts the background daemon on its own.

`directa doctor --fix` now asks the daemon to remove each leftover log folder, and the daemon checks at that moment that no project uses it, so a project started while doctor runs always keeps its logs. An older daemon that cannot do this gets the report without any removal and a note to run `directa daemon restart`.
