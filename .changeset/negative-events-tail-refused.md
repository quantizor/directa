---
"directa": patch
---

`directa events --tail` with a negative number now fails with a usage error naming the fix. Before, the background daemon crashed on it, and the system restarted it only to crash again for as long as a client kept sending that request.
