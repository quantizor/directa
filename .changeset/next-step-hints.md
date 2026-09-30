---
"directa": patch
---

Commands that fall short now say what to run next. `directa status` in a folder with no servers points to `directa status --all` when other projects have some. `directa wait` that ends on a crashed or stopped server names `directa ensure <name>`. `directa restart` prints why a server fell short, the same way `up` and `switch` do. A command that times out while directa asks macOS about its background agent now says it timed out instead of reporting a blank error.
