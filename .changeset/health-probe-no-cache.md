---
"directa": patch
---

`directa wait --healthy` and the healthy status could report a server healthy right after a restart, before it was listening, when its health URL sent a short cache lifetime (`Cache-Control: max-age`). The health check reused the answer from the server's previous run instead of connecting. Every health check now reaches the server.
