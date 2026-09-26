---
"directa": patch
---

`directa logs <name> --tail N` (no `--since`, no `--grep`) now answers from the end of the log file instead of reading and parsing the whole thing first. Measured against a real 26 MB log asking for the last 50 lines: about 920 ms before, about 2 ms now, reading roughly 64 KB off disk instead of the full file.
