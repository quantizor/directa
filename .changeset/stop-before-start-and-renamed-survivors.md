---
"directa": patch
---

Stopping a server in the first moments of its launch, before directa has its process ID, now waits for the process to appear and stops it, instead of reporting it stopped while it comes up anyway. And when the daemon relaunches to find a server was renamed or removed from `devservers.json` while its process kept running, that leftover process is now shut down instead of running on with nothing tracking it. A server marked failed because it listened on the wrong port, or because another server answered on its port, is now really stopped by `directa stop`, and starting it again replaces that copy instead of running a second one beside it.
