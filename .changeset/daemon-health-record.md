---
"directa": patch
---

The background daemon now keeps a small diagnostic record of its own health, to help explain unexpected restarts. It notes how many threads and how much memory it is using, what it is waiting on, and when servers stop and restart. After each restart it also saves a short report on how the previous run ended. Everything lives in a `daemon` folder inside directa's logs folder (`~/Library/Logs/directa/daemon`). Old entries are removed automatically, so the record settles at about 70 MB of disk and never grows past about 100 MB. Nothing is sent anywhere.
