---
"directa": patch
---

`directa wait <name> --stopped` now returns only once the server has no process left running. Before, a server whose port was taken by another server kept its process alive but reported as failed, and the wait returned early while that process was still up. If the wait times out on such a server, the message now names `directa stop <name>` as the next step.
