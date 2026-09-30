---
"directa": patch
---

Reading a server's logs stays quick and light on memory in two cases that used to be slow. Asking for the last lines of one stream that rarely appears (for example `directa logs web --stream err --tail 50` on a server that mostly prints to stdout) no longer loads the whole log into memory to find them, and the error tally recorded when a server stops no longer holds every error line at once. And after your Mac's clock jumps backward (a time sync after sleep, for instance), directa stamps new lines with the last time it wrote until the clock catches up; `directa monitor` and `directa logs --follow` now read only the lines that arrived since their last check in that stretch, instead of rereading the whole log file every couple of seconds.
