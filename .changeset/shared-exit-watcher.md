---
"directa": patch
---

The daemon no longer risks running out of threads and going unresponsive when many dev servers run under the app at once: watching every server's exit now shares one thread instead of parking a thread per server for its whole life. A dev server whose start command runs with elevated privileges (for example `sudo caddy run`) also starts again instead of being torn down as failed.
