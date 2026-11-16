---
"directa": patch
---

directa now sits idle until one of your servers changes. With four servers running and the menu closed, the background service went from 2.67% of a CPU core to 0.24%, and the menu bar app from 1.27% to 0.01%. The app no longer checks every server's status every two seconds; it waits to be told something changed, and the menu still updates the moment a server starts, stops, crashes, or turns unhealthy.

Upgrading from 3.0 with `directa daemon install` keeps your running servers running instead of restarting them.

When the background service has stopped and something needs it, the menu bar app starts it right away instead of after about ten seconds.

Unhealthy servers now say why their health check failed (for example `connection refused` or `HTTP 503`) in `directa events` and the dashboard timeline.
