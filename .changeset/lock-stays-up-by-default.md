---
"directa": major
---

`directa lock` now leaves the servers that declare a resource running by default, instead of stopping them for the duration of the command. Exclusive access still comes from the resource mutex, and when a declaring server holds the state open, a fingerprint guard reports (by default, fails) if the command changed that state underneath it.

Stopping the declaring servers is now opt-in with `--pause`, which stops them for the command and resumes them on release. The old `--no-pause` flag is removed: it was the previous non-default and is now the default, so a plain `directa lock <resource> -- <command>` behaves as `--no-pause` used to. Scripts passing `--no-pause` should drop it; scripts that relied on the servers being stopped should add `--pause`.

A bare-named lock (one with no declared state `path`) has nothing to fingerprint, so a default hold that leaves a declaring server running now warns on stderr that the corruption guard is off, pointing to a `path` declaration or `--pause`.
