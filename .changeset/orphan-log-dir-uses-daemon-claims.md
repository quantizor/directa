---
"directa": patch
---

Fixed `directa doctor`'s orphan-log-dir finding recommending `rm -rf` on a live project's log directory when that project's devservers.json was mid-edit invalid or had just been deleted: the daemon still claims that project and is still writing to its logs, but it had temporarily dropped out of the machine-wide server list the finding used to check against. It now checks against every project the daemon actually claims (including one it cannot currently read the config for), and skips the finding entirely when talking to a daemon too old to report that list, rather than guessing.
