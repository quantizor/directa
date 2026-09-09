---
"directa": major
---

`directa lock` now leaves the project's servers running by default, instead of stopping them for the duration of the command. Other commands still wait their turn for the named resource. If a running server has the locked files open, and the command changes those files, lock reports the mismatch (and by default fails) so the server cannot quietly write the old data back.

Stopping those servers is now opt-in with `--pause`, which stops them for the command and starts them again when the lock is released. The old `--no-pause` flag is gone: a plain `directa lock <resource> -- <command>` now does what `--no-pause` used to. Drop `--no-pause` from scripts. Add `--pause` if the servers really need to be down.

A lock that is only a name, with no `path` to the files it protects, cannot detect those changes. In that case lock warns on stderr and points to adding a `path` or using `--pause`.

`directa up` will not start a stopped server that uses the locked resource while another command still holds the lock. Servers that are already running stay running. The same is true when the background daemon comes back after a crash.
