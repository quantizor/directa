---
"directa": patch
---

Agent sessions no longer get directa's server summary more than once. Cursor also runs the hooks Claude Code is configured with, so a machine with directa's hook installed for both used to show the summary twice in every Cursor session; the Claude Code hook now stays quiet when Cursor runs it and directa's Cursor hook is installed. Antigravity runs its hook before every model call rather than once at session start, so the summary is now added only on the first call instead of every one.
