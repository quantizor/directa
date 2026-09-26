---
"directa": minor
---

`directa up` and `directa down` now accept an optional server name, matching every other single-server command (`ensure`, `restart`, `stop`, `wait`). `directa up web` is shorthand for `directa up --only web` (passing both is a usage error); `directa down api` stops only that server, leaving the rest of the project running. Omitting the name still targets the whole project.
