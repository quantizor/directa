---
"directa": patch
---

Fixed `directa lock <resource> -- <command>` running `<command>` in the project's root directory instead of wherever you actually ran it from. A relative file argument, or a tool that finds its own config by walking up from the current directory, now sees the same directory it would running the command directly.
