---
"directa": patch
---

`directa doctor --fix` now fully forgets a vanished project whatever spelling of its path it is given (a trailing slash or a `~` path, for example). Before, such a spelling dropped the project's registry entry but left its running dev servers, resource locks, and supervision behind.
