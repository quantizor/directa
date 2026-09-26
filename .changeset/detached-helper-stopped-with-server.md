---
"directa": patch
---

When a dev server exits or is stopped, a helper process it started just before exiting is no longer left running. A helper that detached itself (moved into a session of its own, the group of processes a server starts together) in the moment before the server quit could slip past every way directa had of finding it, and it kept holding its port so the next start failed with the port still in use. directa now also follows the kernel's record of which process started which, which survives the server exiting, so these helpers are stopped along with the server.
