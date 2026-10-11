---
"directa": patch
---

Agent sessions hear about a dev server only when it changes, and only the part that changed. Claude Code, Cursor, and Grok Build check after each tool and stay silent unless a server's state moved: it crashed, restarted, or changed port, for example. When something did change, the agent gets one short line per affected server instead of the whole summary. A server that just crashed, failed, or turned unhealthy also brings the few error lines the agent has not seen yet. Ordinary error output from a healthy server stays quiet, and `directa monitor` streams it on request. Antigravity follows the same rule after its tools, and when that rule brings error lines it asks the model to take another turn, up to three times in one conversation. Re-run `directa hook install` to pick up the new hook.
