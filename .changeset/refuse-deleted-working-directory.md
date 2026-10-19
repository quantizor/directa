---
"directa": patch
---

Running a `directa` command from a directory that no longer exists (for example a removed worktree) now fails at once with a message saying the current directory is gone, and suggests `directa status --all` to list projects. Before, every command that works on a project spun at full CPU forever. Pass `--project` with a path to run a command that does not need the current directory from there. `directa lock` still needs a current directory to run its command in and refuses either way. Agent session hooks and the statusline stay silent in that case.
