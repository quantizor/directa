---
"directa": patch
---

Saved daemon state (which servers are registered, what is running) is now written more durably. A crash at exactly the wrong moment during a save no longer risks silently losing the update, and a failed save no longer leaves a stray temporary file behind. The daemon also now cleans up any such leftover file from an earlier crash the next time it starts.
