---
"directa": patch
---

`directa doctor --fix` now fully forgets a vanished project whatever spelling of its path it is given (a trailing slash, a `~` path, or a path through a symbolic link such as `/var` for `/private/var`, for example). Before, such a spelling dropped the project's registry entry but left its running dev servers, resource locks, and supervision behind, or was refused as a project directa never knew.
