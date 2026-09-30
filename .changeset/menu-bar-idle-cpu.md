---
"directa": patch
---

Fixed the menu bar app using a steady share of a CPU core after any server had started. The breathing dot a starting server shows kept redrawing after the server came up, even with the popover closed. The dot now stops breathing the moment the server leaves the starting state.
