---
"directa": patch
---

Fixed several cases where directa lost track of a server that failed because of its port (another server answered on it, or the server listened somewhere other than the port it was given). That kind of failure leaves the server's process running, and now every part of directa treats it that way: `directa lock --pause` stops it like any running server, `directa lock` without `--pause` lists it as still running, checking its status no longer resets the port and URL it was started with, `directa ensure` no longer reports its own process as an unknown program holding the port, and the menu bar app offers Stop and Restart for it instead of only Start.

Fixed a server in a second git worktree (a second checkout of the same repository) sometimes landing on ports inside the block the first checkout's server reserves with `portSpan`, when the first checkout was only listening on the first port of that block. The second checkout now always moves to a block that clears every port the first one reserves.

Fixed two `directa ensure` calls for the same server, arriving at nearly the same moment, occasionally refusing the second one with a "port is held by an unmanaged process" error that named the first call's own freshly started server.
