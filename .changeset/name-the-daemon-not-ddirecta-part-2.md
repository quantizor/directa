---
"directa": patch
---

More messages that led with "ddirecta" (the background daemon's own binary name) now say "the daemon" instead: the wait notice while a fresh daemon restores its servers, a stuck-listener failure, a lost-connection error, a wedged-daemon timeout, `directa doctor`'s jetsam finding, the `directa daemon install/uninstall/start/stop/restart` confirmations, and the equivalent status text in the menu bar app. Several of these previously combined with the CLI's own "directa: " prefix to read as "directa: ddirecta …", easy to mistake for a typo.
