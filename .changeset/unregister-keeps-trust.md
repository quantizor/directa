---
"directa": patch
---

`directa unregister` no longer refuses a project's recorded trust as a side effect of removing a server. Before, unregistering a project's last ad hoc server (one added with `directa register`, distinct from a server declared in devservers.json) could silently forget the whole project, including its trust, if the project also had a committed devservers.json server still running: that server's logs were then deleted out from under it, and a later reboot or watch-triggered restart refused to bring it back until you approved it again. Unregistering a name directa never registered ad hoc now fails with a clear error instead of silently succeeding.
