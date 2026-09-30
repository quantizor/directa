---
"directa": patch
---

When a dev server crashes, directa now reliably stops the helper processes it left behind. Two cases slipped through before, both more likely on a busy machine. A server that exited moments after starting could leave its helpers running, because directa lost track of which session (the group of processes a server starts together) they belonged to. And a helper that had moved into a session of its own could be forgotten if directa happened to refresh its list of the server's processes in the instant between the crash and handling it. Either way the leftover helper kept holding its port, so the next start failed with the port still in use.
