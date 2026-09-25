---
"directa": patch
---

Commands that receive a very large reply from the daemon, most visibly `directa logs` without `--tail` on a long-running server, now finish in seconds instead of minutes. Reading a 36 MB reply took over ten minutes before and now takes well under a second on the client side.
