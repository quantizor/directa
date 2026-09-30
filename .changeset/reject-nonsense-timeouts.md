---
"directa": patch
---

Every `--timeout`/`--acquire-timeout` option (`ensure`, `wait`, `restart`, `up`, `switch`, `lock`) now takes a number of seconds from 0 to 86400 and rejects anything else (text, `inf`, `nan`, a negative number, a larger number) before contacting the background daemon, instead of silently accepting it and letting the daemon quietly clamp it to something else. The error names the option, the value you gave, and the accepted range, and exits with status 2 like any other usage mistake. With `--json`, it arrives as the usual error object on standard output, with the code `usage`.
