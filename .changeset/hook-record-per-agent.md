---
"directa": patch
---

The after-tool hook no longer repeats a server summary it already gave. When Claude Code subagents run beside their parent, or an agent moves between a project's checkouts, each agent now remembers what it was last told about each checkout separately, so unchanged servers stay quiet instead of being announced as new or removed on every call. Two tool calls that finish at the same moment also take turns, so only one of them speaks.
