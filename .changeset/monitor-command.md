---
"directa": minor
---

`directa monitor <name>` streams a server's output shaped for an agent's own streaming tool: Claude Code's Monitor tool, or Grok Build's monitor tool. It attaches with a start marker (checkout path, phase, pid, last exit), then polls for new lines, collapsing repeats, holding lifecycle and stderr to their own budgets so a flooding server never crowds them out, and naming the exact command to read whatever it skipped. A default budget of 120 stdout lines and 30 error lines per minute (`--lines-per-minute`, `--errors-per-minute`, and their `--lines-per-arm`/`--errors-per-arm` per-run totals) keeps a chatty or looping server from filling an agent's context; re-run the command to reset it. The command ends on its own after 29 minutes, when the server is unregistered, or after a sustained daemon outage, always naming what happened and how to keep watching.

Claude Code and Grok Build sessions now see a line at session start naming this command for the project's servers; Cursor, Antigravity, and `directa context` are unchanged.
