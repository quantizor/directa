---
"directa": patch
---

Agent sessions no longer get directa's server summary more than once. Cursor also runs the hooks Claude Code is configured with, so a machine with directa's hook installed for both used to show the summary twice in every Cursor session; the Claude Code hook now stays quiet when Cursor runs it and directa's Cursor hook is installed. Antigravity runs its hook before every model call and numbers each new message from zero, so a check on the first call repeated the server summary on every message. The summary is now added once per conversation, and again after the conversation is compacted (shortened so it fits).
