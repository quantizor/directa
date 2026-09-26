---
"directa": patch
---

Fixed the setup panel (and Gatekeeper quarantine clearing during install) hanging indefinitely if a command it ran printed more output than fits in one pipe buffer before exiting.
