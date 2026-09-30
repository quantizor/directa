---
"directa": patch
---

Fixed a message that read as a typo: waiting on a daemon still restoring servers used to print "directa: ddirecta is restoring supervised servers", which looks like a doubled or misspelled word. It now reads "directa: the daemon is restoring supervised servers". A related message shown when a deliberately stopped daemon is not running now also says "the daemon" instead of "ddirecta".
