---
"directa": patch
---

Agent sessions hear about a dev server again when it actually changes, not on every tool call. Claude Code, Cursor, and Grok Build check after each tool and paste the server summary only when that picture is different from the last one they showed. The last 10 error lines are included when those lines are new, so the agent can see what the server just printed. Antigravity does the same after its tools, and when the new text is error lines it asks the model to take another turn, up to three times in one conversation. Re-run `directa hook install` to pick up the new hook.
