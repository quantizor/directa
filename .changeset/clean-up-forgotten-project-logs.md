---
"directa": patch
---

A project's log directory now gets removed automatically once directa forgets the project, either because you unregistered its last server or because the daemon noticed the checkout is gone. Before, that directory sat under `~/Library/Logs/directa` forever, and only `directa uninstall --purge` ever cleaned it up. `directa doctor` also now flags any log directory left over from before this fix (or orphaned some other way), naming its size, and `directa doctor --fix` removes it for you. It only ever deletes a leftover folder inside directa's own logs folder, never a shortcut (symbolic link) pointing somewhere else, and never one a project still uses.
