---
"directa": patch
---

Asking for a server a project does not have now points at where the name lives. When exactly one other registered project defines it, the error names that project and suggests `directa status <name> --project '<path>'`. When several do, it lists their paths and suggests `directa status --all <name>`. When none does, the hint is `directa status --all`, which lists every project. Before, the hint was `directa status --json`, which listed nothing for the project that was asked about. This covers `status`, `open`, `monitor`, `restart`, and the commands that start, stop, or read logs for a server. A name is never resolved into another project on its own. In a linked worktree without its own `devservers.json`, the message now also says that `--project` with the main checkout's path acts on the main checkout's server.
