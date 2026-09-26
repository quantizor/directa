---
"directa": patch
---

Fixed the background daemon forgetting a project, including its approval and log history, on the very first moment its checkout path went missing when checked through `directa status --all` or the menu bar app's regular polling (both run every couple of seconds). It now waits for the same debounce the timer sweep always used: a checkout has to stay missing for a full sweep interval before directa forgets it, so a brief unmounted drive or a slow move no longer costs a project its trust.
