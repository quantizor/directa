---
"directa": patch
---

Antigravity sessions no longer repeat directa's server summary on every message. Antigravity numbers each new message from zero, so the earlier check for its first call matched every message. The summary is now added once per conversation, and again after the conversation is compacted (shortened so it fits).
