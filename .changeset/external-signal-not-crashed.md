---
"directa": patch
---

A dev server killed by something other than directa (an IDE stop button, a forwarded Ctrl-C, an external process manager) now shows as stopped instead of crashed, as long as it was asked to shut down gracefully (SIGTERM, SIGINT, or SIGHUP). The event history says the signal and that it came from outside directa. Before, any such exit looked identical to a real crash everywhere directa surfaces server health, including the coding-agent session summary, which nudged an agent to investigate a shutdown nobody needed explained. A server actually killed (SIGKILL) or that exits on its own with a nonzero code still shows as crashed.
