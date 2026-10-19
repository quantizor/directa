---
"directa": minor
---

`directa lock --pause` now starts your command only once every paused server, and every process it started, has fully exited, so a worker that was slow to shut down can no longer still be holding the file your command is about to change. If a server's stop gives up with processes still running, the lock fails with `resource-locked`, names that server and points at `directa why <name>`, puts back any server it had already paused, and never runs your command.

The command now also sees a `DIRECTA_LOCKS` environment variable listing the locks held around it (each as the project's full path, `::`, and the resource name, comma-separated, added after any value already set), so a tool with its own lock for the same resource can tell it is already protected. `directa lock` reads that variable itself: a command run under a lock that already lists the one it asks for runs at once, so a guarded script that locks the same resource again no longer waits on its own parent. A resource name containing `,` or `::` is refused with a usage error, since the list could not be split back apart.
