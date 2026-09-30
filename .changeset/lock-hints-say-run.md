---
"directa": patch
---

The suggested fix that `directa lock` prints when it is missing a command, or when the locked state changed under a running server, now starts with `run: ` like every other suggestion directa gives, and puts a resource name containing spaces or other shell characters in quotes so it can be pasted as is. The suggestion after a failed `directa switch` step reads "fix the failure, then run: directa up".
