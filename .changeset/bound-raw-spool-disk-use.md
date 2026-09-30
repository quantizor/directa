---
"directa": patch
---

A server that prints a lot no longer fills your disk through its raw output files (`out.spool` and `err.spool` in the server's log folder). Once directa has copied output into the server's log, it frees the disk space behind it and keeps only the newest megabyte of raw output, so a chatty or runaway server stays at a small, steady size on disk however long it runs. The server keeps writing exactly as before and nothing directa has not read yet is ever discarded. The files report a large size to tools like `ls` because the freed space is left as an empty gap rather than removed; read them with `tail` rather than `cat`.
