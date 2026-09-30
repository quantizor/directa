---
"directa": patch
---

The warning `directa lock` prints when a resource has no `path` declared (so it cannot detect a change while a declaring server keeps running) now names the exact fix: which server declares the resource, and the `devservers.json` object to give it, for example `{"name": "d1", "path": "<path to d1's state>"}`, instead of the vaguer "add a `path` to the lock declaration".
