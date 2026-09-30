# Changelog

## 3.0.0
### Major Changes



- [#34](https://github.com/quantizor/directa/pull/34) [`e6bd7b6`](https://github.com/quantizor/directa/commit/e6bd7b6894844af8f1e406c29069eda7001bf7fe) - `directa lock` now leaves the project's servers running by default, instead of stopping them for the duration of the command. Other commands still wait their turn for the named resource. If a running server has the locked files open, and the command changes those files, lock reports the mismatch (and by default fails) so the server cannot quietly write the old data back.
  
  Stopping those servers is now opt-in with `--pause`, which stops them for the command and starts them again when the lock is released. The old `--no-pause` flag is gone: a plain `directa lock <resource> -- <command>` now does what `--no-pause` used to. Drop `--no-pause` from scripts. Add `--pause` if the servers really need to be down.
  
  A lock that is only a name, with no `path` to the files it protects, cannot detect those changes. In that case lock warns on stderr and points to adding a `path` or using `--pause`.
  
  `directa up` will not start a stopped server that uses the locked resource while another command still holds the lock. Servers that are already running stay running. The same is true when the background daemon comes back after a crash.

### Minor Changes



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa doctor` now checks the files of the daemon it is talking to. Pointed at a separate daemon (for example one started for a test with its own data and logs folders), it reads that daemon's update notice cache and saved PATH instead of the ones in your home folder, so a test run no longer touches your real directa data. The CLI also accepts `DIRECTA_DATA_DIR` and `DIRECTA_LOGS_DIR` to name its own data and logs folders; with either one (or `DIRECTA_SOCKET`) set, it never installs or starts the background daemon on its own.
  
  `directa doctor --fix` now asks the daemon to remove each leftover log folder, and the daemon checks at that moment that no project uses it, so a project started while doctor runs always keeps its logs. An older daemon that cannot do this gets the report without any removal and a note to run `directa daemon restart`.


- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa hook install` with no `--harness` now installs into every supported agent harness detected on your machine (Claude Code, Cursor, Grok Build, OpenCode, Antigravity), printing one line for each harness installed and one for each skipped as not detected, instead of only Claude Code. It fails with a clear error, naming the harnesses it checked, if none is detected at all. Passing `--harness` still installs exactly that one harness, whether or not it is detected.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa logs <name>` now shows only the last 200 lines by default instead of a long-running server's entire history. Pass `--all` for the old full-history behavior, or `--tail`/`--since`/`--since-mark`/`--follow` as before to bound the query yourself.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa monitor <name>` streams a server's output shaped for an agent's own streaming tool: Claude Code's Monitor tool, or Grok Build's monitor tool. It attaches with a start marker (checkout path, phase, pid, last exit), then polls for new lines, collapsing repeats, holding lifecycle and stderr to their own budgets so a flooding server never crowds them out, and naming the exact command to read whatever it skipped. A default budget of 120 stdout lines and 30 error lines per minute (`--lines-per-minute`, `--errors-per-minute`, and their `--lines-per-arm`/`--errors-per-arm` per-run totals) keeps a chatty or looping server from filling an agent's context; re-run the command to reset it. It keeps streaming across a daemon restart and never starts the daemon itself. The command ends on its own after 29 minutes (naming a command that reads anything written after it stops), when the server is unregistered, after a sustained daemon outage, or when the daemon refuses it, always naming what happened and how to keep watching.
  
  Claude Code and Grok Build sessions now see a line at session start naming this command for the project's servers; Cursor, Antigravity, and `directa context` are unchanged.


- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa up` and `directa down` now accept an optional server name, matching every other single-server command (`ensure`, `restart`, `stop`, `wait`). `directa up web` is shorthand for `directa up --only web` (passing both is a usage error); `directa down api` stops only that server, leaving the rest of the project running. Omitting the name still targets the whole project.


### Patch Changes



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - When the daemon restarts and shuts down a leftover dev server it can no longer supervise, a helper process of that server that ignores the polite stop request is now force-stopped too, instead of being left running (and possibly holding the server's port) once the server itself exits.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - A server that prints a lot no longer fills your disk through its raw output files (`out.spool` and `err.spool` in the server's log folder). Once directa has copied output into the server's log, it frees the disk space behind it and keeps only the newest megabyte of raw output, so a chatty or runaway server stays at a small, steady size on disk however long it runs. The server keeps writing exactly as before and nothing directa has not read yet is ever discarded. The files report a large size to tools like `ls` because the freed space is left as an empty gap rather than removed; read them with `tail` rather than `cat`.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - The background daemon's control socket now refuses a request that streams past 1 MiB without ever sending a newline to end it, instead of letting a misbehaving client grow the daemon's memory without limit. This never affects the `directa` command or the menu bar app, which always send small, complete requests; it only guards a client writing to the socket directly.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Fixed the background daemon leaking two threads and their file descriptors every time it tried to read git information (for sibling-port rebind, or worktree detection) from a working directory that could not actually be used to run a process (a checkout mid-move, an invalid path). Repeated failures no longer accumulate; a normal git checkout is unaffected.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - A project's log directory now gets removed automatically once directa forgets the project, either because you unregistered its last server or because the daemon noticed the checkout is gone. Before, that directory sat under `~/Library/Logs/directa` forever, and only `directa uninstall --purge` ever cleaned it up. `directa doctor` also now flags any log directory left over from before this fix (or orphaned some other way), naming its size, and `directa doctor --fix` removes it for you. It only ever deletes a leftover folder directa itself created inside its own logs folder, never another app's folder, never a shortcut (symbolic link) pointing somewhere else, and never one a project still uses, including a project you started while `doctor` was busy with its other checks.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - When a dev server crashes, directa now reliably stops the helper processes it left behind. Two cases slipped through before, both more likely on a busy machine. A server that exited moments after starting could leave its helpers running, because directa lost track of which session (the group of processes a server starts together) they belonged to. And a helper that had moved into a session of its own could be forgotten if directa happened to refresh its list of the server's processes in the instant between the crash and handling it. Either way the leftover helper kept holding its port, so the next start failed with the port still in use.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - The background daemon now keeps a small diagnostic record of its own health, to help explain unexpected restarts. It notes how many threads and how much memory it is using, what it is waiting on, and when servers stop and restart. After each restart it also saves a short report on how the previous run ended. Everything lives in a `daemon` folder inside directa's logs folder (`~/Library/Logs/directa/daemon`). Old entries are removed automatically, so the record settles at about 70 MB of disk and never grows past about 100 MB. Nothing is sent anywhere.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Fixed the background daemon forgetting a project, including its approval and log history, on the very first moment its checkout path went missing when checked through `directa status --all` or the menu bar app's regular polling (both run every couple of seconds). It now waits for the same debounce the timer sweep always used: a checkout has to stay missing for a full sweep interval before directa forgets it, so a brief unmounted drive or a slow move no longer costs a project its trust.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - When a dev server exits or is stopped, a helper process it started just before exiting is no longer left running. A helper that detached itself (moved into a session of its own, the group of processes a server starts together) in the moment before the server quit could slip past every way directa had of finding it, and it kept holding its port so the next start failed with the port still in use. directa now also follows the kernel's record of which process started which, which survives the server exiting, so these helpers are stopped along with the server.



- [#34](https://github.com/quantizor/directa/pull/34) [`e6bd7b6`](https://github.com/quantizor/directa/commit/e6bd7b6894844af8f1e406c29069eda7001bf7fe) - Replacing `/Applications/directa.app` from a mounted DMG now stops the background agent (the installer used to hang on that step) and quits after a successful copy, so the disk can be ejected.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa doctor --fix` now actually forgets a leftover registry entry for a project whose checkout is gone (its registry row, trust, and log directory), rather than reporting success while leaving the entry in place, which could otherwise leave a trusted project stuck registered forever with no checkout behind it. The tool still refuses to touch a project whose checkout has reappeared on disk, since forgetting a live project would drop its approval to run its committed config.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa doctor --fix` now says plainly when the running background daemon is too old to know `project.forget` ("run: directa daemon restart") instead of printing a raw "unknown method" error, and correctly says "1 server" instead of "1 servers" when forgetting a project with exactly one.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Saved daemon state (which servers are registered, what is running) is now written more durably. A crash at exactly the wrong moment during a save no longer risks silently losing the update, and a failed save no longer leaves a stray temporary file behind. The daemon also now cleans up any such leftover file from an earlier crash the next time it starts.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Fixed `directa why` and `directa doctor`'s jetsam-restart count misreading a watch-triggered restart as an externally sent stop signal, or as a daemon restart, whenever the changed file's path happened to contain the literal text "(external)" or "daemon-restart" (a directory or file legitimately named that). Both now recognize only the exact detail directa itself writes for those events.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - When macOS will not tell the background daemon how a dev server exited, directa now reads the exit code or signal from the record launchd keeps for that server, instead of reporting the exit as unknown in `directa status`, `directa why`, and the event history.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - A dev server killed by something other than directa (an IDE stop button, a forwarded Ctrl-C, an external process manager) now shows as stopped instead of crashed, as long as it was asked to shut down gracefully (SIGTERM, SIGINT, or SIGHUP). The event history says the signal and that it came from outside directa. Before, any such exit looked identical to a real crash everywhere directa surfaces server health, including the coding-agent session summary, which nudged an agent to investigate a shutdown nobody needed explained. A server actually killed (SIGKILL) or that exits on its own with a nonzero code still shows as crashed.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Commands that receive a very large reply from the daemon, most visibly `directa logs` without `--tail` on a long-running server, now finish in seconds instead of minutes. Reading a 36 MB reply took over ten minutes before and now takes well under a second on the client side.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa status` and the menu bar app's polling now answer instantly for a crashed or failed dev server after a daemon restart. Before, each check reread that server's entire log history from disk, noticeably slow on a server with a large log, so the menu bar app's regular polling competed with the read it had just finished.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - When `directa doctor --fix` forgets a vanished project while the daemon's own cleanup is already removing it, the project's servers are now stopped and recorded as unregistered once, not twice.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa doctor --fix` now fully forgets a vanished project whatever spelling of its path it is given (a trailing slash, a `~` path, or a path through a symbolic link such as `/var` for `/private/var`, for example). Before, such a spelling dropped the project's registry entry but left its running dev servers, resource locks, and supervision behind, or was refused as a project directa never knew.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Fixed sibling-port rebind and worktree detection hanging indefinitely against a git checkout that prints a long warning (a "detached HEAD" or "unsafe repository" notice, for example) before answering.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Unregistering a server now always leaves it stopped for good. Unregistering it while a restart of it is still in progress no longer starts a copy that nothing keeps track of, and a server whose stop hangs no longer comes back the next time the daemon launches. The same holds for a project directa forgot because its folder was gone, if that folder later comes back. A server whose stop hangs is now also shut down the next time the daemon starts, if it is still running then.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - When directa runs as the background daemon installed with the app, a dev server whose start command exits immediately (a bad script, a typo'd binary, a config error caught before the server even binds) now reports that it exited, instead of the unhelpful "never became a session leader" spawn failure. It carries the real exit code, or the signal that ended it, whenever macOS still has that on record. A command directa cannot run at all, such as a typo'd path, now exits with code 127 and prints `directa: cannot run <command>: <reason>` as its error output, where before it exited 0 without a word. `directa status` and `directa why` can now tell an instant, wrong-command failure apart from directa itself failing to launch the process, and the command's own error output (printed to stderr before it exited) now reaches `directa logs` and `directa why` instead of being silently dropped. A command that exits before directa is able to watch it is not started again just because the daemon comes back; a server that was actually watched, including one that exited a moment after directa started watching it, still is.



- [#34](https://github.com/quantizor/directa/pull/34) [`e6bd7b6`](https://github.com/quantizor/directa/commit/e6bd7b6894844af8f1e406c29069eda7001bf7fe) - `directa doctor` now warns when macOS killed the background daemon to free memory (jetsam), and when leftover server-process entries are still registered after that death. The daemon also cleans those leftovers up when it comes back, so they do not pile up across automatic restarts.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - After macOS kills the background daemon to free memory, a dev server that is still running is picked up again instead of being stopped and started. If macOS does not answer when the daemon asks which of those servers are still running, the daemon leaves them running rather than restarting them.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - The suggested fix that `directa lock` prints when it is missing a command, or when the locked state changed under a running server, now starts with `run: ` like every other suggestion directa gives, and puts a resource name containing spaces or other shell characters in quotes so it can be pasted as is. The suggestion after a failed `directa switch` step reads "fix the failure, then run: directa up".



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - The warning `directa lock` prints when a resource has no `path` declared (so it cannot detect a change while a declaring server keeps running) now names the exact fix: which server declares the resource, and the `devservers.json` object to give it, for example `{"name": "d1", "path": "<path to d1's state>"}`, instead of the vaguer "add a `path` to the lock declaration".



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Fixed `directa lock <resource> -- <command>` running `<command>` in the project's root directory instead of wherever you actually ran it from. A relative file argument, or a tool that finds its own config by walking up from the current directory, now sees the same directory it would running the command directly; this holds even when you pass `--project` to lock a different project's resource, since `<command>` still runs where you are, not there.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Fixed the menu bar app using a steady share of a CPU core after any server had started. The breathing dot a starting server shows kept redrawing after the server came up, even with the popover closed. The dot now stops breathing the moment the server leaves the starting state.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - More messages that led with "ddirecta" (the background daemon's own binary name) now say "the daemon" instead: the wait notice while a fresh daemon restores its servers, a stuck-listener failure, a lost-connection error, a wedged-daemon timeout, `directa doctor`'s jetsam finding, the `directa daemon install/uninstall/start/stop/restart` confirmations, and the equivalent status text in the menu bar app. Several of these previously combined with the CLI's own "directa: " prefix to read as "directa: ddirecta …", easy to mistake for a typo.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - A few more messages that led with "ddirecta" (the background daemon's own binary name) now say "the daemon" instead: the install failure when neither a LaunchAgent nor the daemon binary can be found, the app's "asked the app to start it, but it never answered" message, and `directa daemon info`'s human-readable output. The menu bar app's "the daemon is stopped" and "the daemon is not running" rows are now capitalized consistently with the "Starting the daemon…" row beside them. `directa hook install --harness bogus` and `directa hook uninstall --harness bogus` now point at the literal command to run instead of a bare list of supported names.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Fixed a message that read as a typo: waiting on a daemon still restoring servers used to print "directa: ddirecta is restoring supervised servers", which looks like a doubled or misspelled word. It now reads "directa: the daemon is restoring supervised servers". A related message shown when a deliberately stopped daemon is not running now also says "the daemon" instead of "ddirecta".



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa events --tail` with a negative number now fails with a usage error naming the fix. Before, the background daemon crashed on it, and the system restarted it only to crash again for as long as a client kept sending that request.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Commands that fall short now say what to run next. `directa status` in a folder with no servers points to `directa status --all` when other projects have some. `directa wait` that ends on a crashed or stopped server names `directa ensure <name>`. `directa restart` prints why a server fell short, the same way `up` and `switch` do. A command that times out while directa asks macOS about its background agent now says it timed out instead of reporting a blank error.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - After the daemon restarts, a still-running dev server whose port settings no longer make sense (for example a `directa.local.json` entry that places a named port inside its port span) is no longer silently taken back over with no ports recorded. It is stopped, and the restart reports the configuration error the same way `directa ensure` would.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa events` and the dashboard timeline no longer show a duplicate "stopped" entry when directa notices a project's checkout is gone and stops a server that was still running. A server that was already stopped still gets its one entry recording that the checkout disappeared.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Agent sessions no longer get directa's server summary more than once. Cursor also runs the hooks Claude Code is configured with, so a machine with directa's hook installed for both used to show the summary twice in every Cursor session; the Claude Code hook now stays quiet when Cursor runs it and directa's Cursor hook is installed. Antigravity runs its hook before every model call rather than once at session start, so the summary is now added only on the first call instead of every one.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - The menu bar popover now has a solid background, so server rows stay readable no matter what window or wallpaper sits behind it. The filter and sort controls at the top are solid too, so rows scrolling beneath them no longer show through. The popover also follows your system Light or Dark setting; before, it followed the menu bar, which macOS tints to match the wallpaper, so a Dark Mode user on a bright wallpaper got a light popover.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Fixed `directa doctor`'s orphan-log-dir finding recommending `rm -rf` on a live project's log directory when that project's devservers.json was mid-edit invalid or had just been deleted: the daemon still claims that project and is still writing to its logs, but it had temporarily dropped out of the machine-wide server list the finding used to check against. It now checks against every project the daemon actually claims (including one it cannot currently read the config for), and skips the finding entirely when talking to a daemon too old to report that list, rather than guessing.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - A dev server running on the port its checkout's `directa.local.json` gives it is now recognized as directa's own when another project asks for that port, even right after a daemon restart. Before, `directa ensure` and `directa status` could call it an unknown process holding the port, and a sibling worktree could not rebind around it.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Fixed several cases where directa lost track of a server that failed because of its port (another server answered on it, or the server listened somewhere other than the port it was given). That kind of failure leaves the server's process running, and now every part of directa treats it that way: `directa lock --pause` stops it like any running server, `directa lock` without `--pause` lists it as still running, checking its status no longer resets the port and URL it was started with, `directa ensure` no longer reports its own process as an unknown program holding the port, and the menu bar app offers Stop and Restart for it instead of only Start.
  
  Fixed a server in a second git worktree (a second checkout of the same repository) sometimes landing on ports inside the block the first checkout's server reserves with `portSpan`, when the first checkout was only listening on the first port of that block. The second checkout now always moves to a block that clears every port the first one reserves.
  
  Fixed two `directa ensure` calls for the same server, arriving at nearly the same moment, occasionally refusing the second one with a "port is held by an unmanaged process" error that named the first call's own freshly started server.


- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa doctor` no longer warns about an unmanaged program on a server's port when the listener is another directa server whose port check failed but whose process is still running on that port.
  
  A server in a second git worktree (a second checkout of the same repository) that moved to a different port no longer counts as holding the port it moved away from. Starting the first checkout's server on its own port no longer mistakes the moved server for the one in the way.


- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - When directa runs as the background daemon installed with the app, it now records the real reason a dev server exited. Before, every exit read as a clean `code=0`, so a server that failed with an error or was killed by a signal looked the same as one that quit normally in `directa status`, `directa why`, and the event history. The warning for a server stuck waiting on an interactive login can now appear for these servers too.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Every `--timeout`/`--acquire-timeout` option (`ensure`, `wait`, `restart`, `up`, `switch`, `lock`) now takes a number of seconds from 0 to 86400 and rejects anything else (text, `inf`, `nan`, a negative number, a larger number) before contacting the background daemon, instead of silently accepting it and letting the daemon quietly clamp it to something else. The error names the option, the value you gave, and the accepted range, and exits with status 2 like any other usage mistake. With `--json`, it arrives as the usual error object on standard output, with the code `usage`.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - An extremely long `DIRECTA_SOCKET` override used to make the background daemon fail silently: it printed a "listening" line and kept running, but never actually opened a socket, so every command timed out with no clear reason why. The daemon now refuses to start in that case with a clear error naming the offending path, matching what the CLI already reported when it hit the same limit.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - The app, the command-line tool, and the Homebrew cask now declare macOS 26 (Tahoe) as their minimum, the oldest macOS directa is tested on (continuous integration runs macOS 26, and day-to-day use is on macOS 27).



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Restarting a dev server that prints a lot of output no longer takes down the background daemon. Before, the daemon's memory could climb to several gigabytes in seconds until macOS killed it, stopping every other server's supervision with it. A stop that cannot finish now gives up after a bounded wait and notes it in that server's log instead of hanging the command, and a `start` or `ensure` that arrives during such a stop gives up the same way (an `ensure` within its own `--timeout`, counting the time it spent waiting).



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa restart` no longer fails with "daemon closed the connection" when the daemon goes away in the middle of it (for example when macOS stops it under memory pressure and it starts again). The command now waits for the daemon to come back, checks the server, and finishes the restart from where it stopped, so it does not restart the server a second time. Before, the error invited running the command again, which bounced a server that had already come back. A daemon that comes back but never answers ends that wait on time rather than holding the command for minutes.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - A dev server that was running when the background daemon restarted now comes back once a resource lock it depends on is released, instead of staying marked crashed until someone runs `directa ensure`. (A resource lock is what `directa lock` holds while a command like a database migration runs.) A server the daemon stopped on its way down now reads stopped rather than crashed when it cannot be brought back right away.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Fixed the setup panel (and Gatekeeper quarantine clearing during install) hanging indefinitely if a command it ran printed more output than fits in one pipe buffer before exiting.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - The background daemon now uses the same small, fixed amount of resources to watch its dev servers no matter how many are running, so a machine running many servers under the app no longer risks the daemon running short of threads. A dev server whose start command runs with elevated privileges (for example `sudo caddy run`) also starts again instead of being torn down as failed.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - The background daemon stays responsive while `git`, `launchctl`, or a port lookup is slow. A checkout on a slow network drive or a stuck repository could tie up the threads the daemon uses for everything else, so `directa status`, starts, and health checks all stalled together, and a burst of those calls could push the daemon past the thread limit macOS gives it. Those commands now wait on a small, fixed set of their own threads, repository reads never hold up starting or supervising servers, and a `git`, `launchctl`, `lsof`, or `ps` call that hangs is stopped after a timeout, together with anything it started.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - With Start at login on, the menu bar app now comes back on its own after macOS or a memory-pressure pass kills it. Start at login stays your choice: upgrading does not turn it on, turning it off keeps it off, and choosing Quit from the menu still keeps the app closed. If you already had Start at login on and macOS asks you to allow directa in System Settings after the upgrade, directa keeps starting at login the old way until you do.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa status --all` and the menu bar stay quick when many stopped servers have a port held by another server. Each of those servers used to cost two `git` runs on every status read, which added up to seconds with a few dozen worktrees; the check now reads the checkout's own files instead.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Reading a server's logs stays quick and light on memory in two cases that used to be slow. Asking for the last lines of one stream that rarely appears (for example `directa logs web --stream err --tail 50` on a server that mostly prints to stdout) no longer loads the whole log into memory to find them, and the error tally recorded when a server stops no longer holds every error line at once. And after your Mac's clock jumps backward (a time sync after sleep, for instance), directa stamps new lines with the last time it wrote until the clock catches up; `directa monitor` and `directa logs --follow` now read only the lines that arrived since their last check in that stretch, instead of rereading the whole log file every couple of seconds.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Stopping a server in the first moments of its launch, before directa has its process ID, now waits for the process to appear and stops it, instead of reporting it stopped while it comes up anyway. And when the daemon relaunches to find a server was renamed or removed from `devservers.json` while its process kept running, that leftover process is now shut down instead of running on with nothing tracking it. A server marked failed because it listened on the wrong port, or because another server answered on its port, is now really stopped by `directa stop`, and starting it again replaces that copy instead of running a second one beside it. After a restart of the Mac, directa no longer stops an unrelated app that happens to reuse a process ID a dev server had before the restart: it checks the process start time first.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - A dev server's log and event history now say why directa stopped it (a restart, a watch-triggered restart naming the file that changed, a resource lock pausing it, a `down`, or the daemon shutting down), not just the exit code. Before, that reason only ever appeared in the background daemon's own internal log, which macOS does not keep, so `directa logs`, `directa why`, and the event timeline showed the same `exited code=0` for every deliberate stop regardless of cause.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa logs <name> --tail N` (no `--since`, no `--grep`) now answers from the end of the log file instead of reading and parsing the whole thing first. Measured against a real 26 MB log asking for the last 50 lines: about 920 ms before, about 2 ms now, reading roughly 64 KB off disk instead of the full file.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa events` and the dashboard timeline no longer fail the whole response when the daemon reports an event kind this build of directa predates; that one event now shows up with its kind as reported instead of the entire list disappearing.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa unregister` no longer drops a project's recorded trust as a side effect of removing a server. Before, unregistering a project's last ad hoc server (one added with `directa register`, distinct from a server declared in devservers.json) could silently forget the whole project, including its trust, if the project also had a committed devservers.json server still running: that server's logs were then deleted out from under it, and a later reboot or watch-triggered restart refused to bring it back until you approved it again. Unregistering a name directa never registered ad hoc, including one declared only in devservers.json and never added with `directa register`, now fails with a clear "not found" error instead of silently succeeding.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa unregister` now stops a server before removing it if that server is still running, instead of dropping it from tracking while leaving the real process alive and its logs deleted out from under it. An already stopped server unregisters exactly as before.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - `directa why` now says when a server was stopped by something other than directa: an IDE stop button, a forwarded Ctrl-C, or another process manager sending a graceful signal (SIGTERM, SIGINT, or SIGHUP). Before, that server showed the same bare "not running (stopped)" as a server directa itself stopped, giving no hint that something outside directa shut it down.



- [#37](https://github.com/quantizor/directa/pull/37) [`e4d22ea`](https://github.com/quantizor/directa/commit/e4d22ea5db61408bee29b6cdfa2e9d9331354314) - Commands run inside a git worktree now act on that worktree's own servers. Before, a worktree nested inside its main checkout (the layout Claude Code uses for isolated agents) could pick up the main checkout's `devservers.json` and act on the main checkout's servers without saying so. When a worktree has no config of its own, the not-found message says how to fix it (commit or copy `devservers.json` into the worktree, or pass `--project`) and gives the command that lists the main checkout's servers. One setup changes: a bare repository with a worktree per branch and a single `devservers.json` in the parent folder now needs `--project` or a config in each worktree.
  
  `directa logs --follow` now streams reliably through a pipe. Lines arrive as they are written instead of sitting in a buffer, lines written in the same millisecond are never dropped or repeated, and a follow that starts before the server has printed anything no longer re-reads the whole log on every poll. The new `--head N` option reads the oldest lines from a starting point, for catching up on a stretch of output in order. Log queries over large histories are also much faster and use far less memory.

## 2.0.0
### Major Changes



- [#32](https://github.com/quantizor/directa/pull/32) [`45caa88`](https://github.com/quantizor/directa/commit/45caa8884e38737cdc3b1c9e813991a3d210dcc5) - The product is now called directa. The CLI is `directa`, the daemon is `ddirecta`, the menu bar app is `directa.app`, and deep links use `directa://`. `devservers.json` is unchanged.


### Patch Changes



- [#32](https://github.com/quantizor/directa/pull/32) [`45caa88`](https://github.com/quantizor/directa/commit/45caa8884e38737cdc3b1c9e813991a3d210dcc5) - The menu bar app has a standard About panel (directa > About directa) showing the version, copyright, and MIT License.

## 1.5.3
### Patch Changes



- [#30](https://github.com/quantizor/devctl/pull/30) [`34c9331`](https://github.com/quantizor/devctl/commit/34c933123bbfb7ca82894b11640c34333ca8d19e) - The menu bar icon no longer quits itself as idle after macOS reclaims memory. The extra has no windows AppKit counts as "in use", so a memory-pressure pass was allowed to terminate it, and Start at Login only brings it back at the next login.

## 1.5.2
### Patch Changes



- [#28](https://github.com/quantizor/devctl/pull/28) [`3e19c23`](https://github.com/quantizor/devctl/commit/3e19c2382a45b43ded510a228eb079d8b8c3dfe4) - A memory-hungry dev server no longer takes the background daemon down with it. Under the menu bar agent, each server now runs as its own launchd job, so macOS can reclaim that server's memory without killing every other server the daemon is supervising.

## 1.5.1
### Patch Changes



- [#26](https://github.com/quantizor/devctl/pull/26) [`13e293b`](https://github.com/quantizor/devctl/commit/13e293b11fce8ab22d938049621d6adaed6d3528) - Grok Build sessions receive a live server snapshot. `devctl hook install --harness grok` wires PreToolUse (the event Grok delivers into context, after the first tool of a turn) and UserPromptSubmit (the per-turn gate) alongside the existing home rule, and removes a leftover SessionStart or Stop registration of the same command. Re-run install to upgrade a SessionStart-only hook; `devctl doctor` reports the old install as missing.



- [#26](https://github.com/quantizor/devctl/pull/26) [`13e293b`](https://github.com/quantizor/devctl/commit/13e293b11fce8ab22d938049621d6adaed6d3528) - A noisy dev server no longer drives the daemon's memory into the tens of gigabytes.



- [#26](https://github.com/quantizor/devctl/pull/26) [`13e293b`](https://github.com/quantizor/devctl/commit/13e293b11fce8ab22d938049621d6adaed6d3528) - `devctl uninstall` now also removes Start at Login and the leftover background item in System Settings, so the app cannot launch itself after you remove it. A DMG-installed app is moved to the Trash; Homebrew's copy is left for brew to remove. `--purge` also deletes preferences and caches.

## 1.5.0
### Minor Changes



- [#25](https://github.com/quantizor/devctl/pull/25) [`be1705a`](https://github.com/quantizor/devctl/commit/be1705a9ce9d6d7f26bcc277d238373a4622ed92) - Servers in a linked git worktree keep the project's declared host instead of getting an ephemeral `worktree-<label>.<preferred>.localhost` origin. Every `*.localhost` name resolves to loopback, so the label never disambiguated a bind, while the third-level subdomain broke any auth config an app pins to one origin (an OAuth callback, a cookie domain, a CORS allow list, a trusted-origins check). Sibling worktrees of one repo are still told apart: the shared committed port auto-rebinds as before, and the worktree name surfaces as a display value (`worktree` and `mainProject` on status JSON, a `worktree: <label>` line in `devctl status` human output and in `config check`, and a banner line in session context). The menu bar app and Spotlight show a worktree server under its project family (`myproj · review`), so searching for the project name still finds it.


### Patch Changes



- [#25](https://github.com/quantizor/devctl/pull/25) [`557bc3c`](https://github.com/quantizor/devctl/commit/557bc3c1ec0590a3bcd017a9904dd06218d134a5) - Antigravity sessions now rediscover running servers the way Claude Code and Cursor already do. `devctl hook install --harness antigravity` (also offered at first run and in Settings when `~/.gemini` is present) wires a PreInvocation hook so a new session sees live `devctl` status instead of spawning duplicates. `devctl hook uninstall --harness antigravity` removes it.



- [`ef2adc7`](https://github.com/quantizor/devctl/commit/ef2adc76f3e7a8d270bbad3b3899c0978950440b) - `devctl doctor` now catches a second devctl copy shadowing your Homebrew install, the failure where `brew upgrade` changes one copy while a bare `devctl` (or the background daemon) keeps running an older one. It reports when a manual `~/.local/bin` install coexists with the Homebrew cask (whichever `~/.local/bin` or brew's bin comes first on your PATH is what actually runs), and when an `/Applications/devctl.app` that Homebrew did not place is still present. Each finding names the exact cleanup command. Like doctor's other environment findings, it only reports, and only fires when a Homebrew install is present, so a plain `make install` is never flagged.



- [#25](https://github.com/quantizor/devctl/pull/25) [`69232b8`](https://github.com/quantizor/devctl/commit/69232b8e845a3a65eb9f4e6c70f1527e68c88bef) - Grok Build is a supported agent harness. `devctl hook install --harness grok` (also offered at first run and in Settings when `~/.grok` is present) wires a session hook and a short home rule that tells Grok to run `devctl context` before touching a server, so a new session does not spawn duplicates. `devctl hook uninstall --harness grok` removes both.



- [#25](https://github.com/quantizor/devctl/pull/25) [`b170109`](https://github.com/quantizor/devctl/commit/b170109999d2b52039469ed4f7552d6dc8cde77b) - A server whose start command waits on an interactive credential prompt (a secrets CLI unlock, a biometric approval) can no longer crash-loop invisibly. When runs repeatedly exit on their own, nonzero, after tens of seconds, without ever passing a healthcheck, status surfaces `blockedOn: "interactive-auth"` with the remedy in human status, `devctl why`, and the session-context block: start the server once in a terminal to surface the prompt, then `devctl ensure`. The classification is a heuristic in devctl's own words and clears the first time a run dies differently or a healthcheck passes.



- [#25](https://github.com/quantizor/devctl/pull/25) [`3f8a7c2`](https://github.com/quantizor/devctl/commit/3f8a7c28a6d07fcc8b3606de69e998477c335af8) - Servers under a discarded checkout now stop on their own within about a minute of the checkout disappearing, instead of waiting for a reboot or a machine-wide `devctl status --all`. The daemon stats every registered project every 30 seconds and prunes a path only after it is missing on two consecutive sweeps, so one flaky stat (a network mount blip, a slow Finder move) never tears down a live project.



- [#25](https://github.com/quantizor/devctl/pull/25) [`8409259`](https://github.com/quantizor/devctl/commit/84092598c2f0e5fe91d0215e75436dec12f532ed) - OpenCode is a supported agent harness. `devctl hook install --harness opencode` (also offered at first run and in Settings when `~/.config/opencode` is present) writes a managed `~/.config/opencode/devctl.md` that tells OpenCode to run `devctl context` before touching a server, wired through the `instructions` array of the winning global config file, so a new session discovers the servers without spawning duplicates. OpenCode has no session-start hook to inject live context into, so the standing instruction is the integration; instruction files already referenced by a losing `opencode.json` stay active after the entry lands in `opencode.jsonc`. `devctl hook uninstall --harness opencode` removes both halves.



- [#25](https://github.com/quantizor/devctl/pull/25) [`3f8a7c2`](https://github.com/quantizor/devctl/commit/3f8a7c28a6d07fcc8b3606de69e998477c335af8) - `--project` now refuses anything that is not an existing directory (exit 2, `usage`). Passing a project's NAME instead of its path used to resolve to a nonexistent relative directory and answer an empty scoped view: `devctl down --project myproj` reported success against a phantom project while the real server kept running.

## 1.4.1
### Patch Changes



- [`397a4b0`](https://github.com/quantizor/devctl/commit/397a4b0e24955bb0d0b9cc58778c1e45ad0ea56e) - The Homebrew install now tells you what to do next. A fresh `brew install --cask quantizor/tap/devctl` used to finish with a post-install message that mentioned only uninstall, so you were left with an app that had not started and no hint that the background agent only comes up once you open the app for the first time. The message now names the menu bar app and its agent, the one step to start it (`open -a devctl`), the one-time macOS confirmation you will see on that first launch, and how to enable your coding-agent session hooks.

## 1.4.0
### Minor Changes



- [#12](https://github.com/quantizor/devctl/pull/12) [`f5831ac`](https://github.com/quantizor/devctl/commit/f5831ac3fa6c6d3db68082419d6580df22ebd7b4) - `devctl config init` writes a devservers.json from the servers the daemon already knows, which is the way back from losing one. The file is routinely gitignored per machine and nothing could regenerate it, so a lost or destroyed config meant retyping every server by hand. What it writes is deliberately portable: an effective or rebound port, a worktree-derived host, a materialized url, an absolute icon path, and the port and host variables devctl injects are all dropped, so a file recovered inside a linked worktree is still correct on someone else's machine. `--dry-run` shows the content without touching disk, and an existing file is refused unless `--force`. `devctl register --write` appends one server to the file, leaving every other entry alone.
  
  `devctl config check` now reports the host a start would actually use when it differs from the declared one. A linked worktree gets an ephemeral host, so any origin the app itself pins (an auth callback URL, a CORS allow list, an API key referrer restriction) was already wrong with nothing saying so until the app broke.
  
  `devctl stop` on a server that declares a resource points at `devctl lock`, which gets exclusive access without a bounce, and `ServerStatus` carries the server's `locks` so the same fact reaches `--json` consumers. The session context block names `devctl lock` as the way to exclusive access, and its invitation to report devctl friction now says to describe the problem generically rather than naming the project, since that backlog lives outside it.


- [#18](https://github.com/quantizor/devctl/pull/18) [`0069434`](https://github.com/quantizor/devctl/commit/0069434c7906828599c69061038a209bc89b4de9) - devctl installs from Homebrew: `brew install --cask quantizor/tap/devctl`. `brew upgrade` keeps it current, and when a newer version ships the menu bar popover shows a quiet notice with a one-click Upgrade button that runs the upgrade in Terminal (a Homebrew install) or links to the release notes (a direct download). A direct DMG download still works exactly as before.
  
  A new Settings window, opened from the gear at the bottom of the popover, is the way back to anything you skipped at first run: install or remove the Claude Code and Cursor session hooks per harness, toggle Start at login, and turn the update check on or off. devctl still only edits a harness's settings when you click; it never changes them on its own.
  
  Removing devctl is now a single command. `devctl uninstall` unregisters the background agent, removes the agent hooks, and removes the CLI, keeping your data unless you pass `--purge`; running servers keep going. The Settings window offers the same as a button. `devctl doctor` reports a harness whose hook is missing or points at a path that no longer exists, and names the command to fix it.


- [#13](https://github.com/quantizor/devctl/pull/13) [`5f24f46`](https://github.com/quantizor/devctl/commit/5f24f4634d3ac5ea4d72fc58286f89fe85f3976b) - `devctl lock` can now tell you when a command changed the state it was guarding while a server still held that state open. A `locks` entry may name where the resource lives on disk (`{"name": "d1", "path": ".wrangler/state/v3/d1"}`, alongside the plain `"d1"` form, which keeps working unchanged). With a path declared, `lock` fingerprints that state before and after the command. Under `--no-pause` with a declaring server still running, a change is a `resource-mutated` failure naming the servers to stop and the command to re-run, because the running server holds the old state open and can write its cached pages back over what the command wrote. Under the default paused mode the same change is just a note.
  
  This closes a silent data loss: a migration run under `--no-pause` that wiped and rebuilt a local database reported success while the seeded rows were gone, and nothing in the output distinguished that from a clean run. The check is deliberately modest about its limits, and the contract states them: it flags the risk window rather than the damage, it cannot see state outside the declared path or divergence that never reaches disk, and above 8 MiB it samples a file rather than hashing it whole.


- [#13](https://github.com/quantizor/devctl/pull/13) [`5f24f46`](https://github.com/quantizor/devctl/commit/5f24f4634d3ac5ea4d72fc58286f89fe85f3976b) - `devctl lock` no longer passes its own options to the guarded command. `devctl lock d1 --timeout 300 -- cmd` ran `env --timeout 300 -- cmd` and died with `env: illegal option -- t`, because the resource name ended option parsing and everything after it was captured as the command. The command is now taken from after `--` verbatim, so a nested `--`, a dash option, and an empty string all survive, while a missing terminator or an unknown option is rejected instead of quietly passed through.
  
  A contended `devctl lock` says who holds the resource instead of blocking silently for up to five minutes. It names the holder's pid, how long that run has been going, and which servers it paused or left running, then repeats a still-waiting line while it waits. Silence there reads as a hung gate, and the reflex it invites is killing the run that holds the lock, which is the one making progress. `--acquire-timeout 0` now makes exactly one attempt and fails immediately, which it could not do before: the wait loop never ran its body at a zero budget and failed with a message naming no holder. All of `lock`'s own output moved to stderr, so stdout carries only the guarded command's.


- [#11](https://github.com/quantizor/devctl/pull/11) [`ae6a118`](https://github.com/quantizor/devctl/commit/ae6a11804fae863f8b3aff02b0443df02c1a75b3) - Port conflicts now announce themselves at the first surface that can see them. `why` names the server and project holding a stopped server's port instead of answering only "not running (stopped)", and the machine-wide status sweep carries the same annotation, so the menu bar app and `doctor` see it too. `doctor` gains a `port-collision` finding for two unrelated projects that declare one port, which the host-keyed signature table could never report because the hostnames differ while the bind does not; sibling worktrees stay excluded since they rebind by design. A server whose healthcheck is answered by another supervised server now fails with `portConflict.state: "foreign"` rather than reporting healthy while serving nothing, and a port held by this server and a stranger at once is reported as `"shared"`. A listener outside the process tree that cannot be attributed to a managed server is annotated but left running, because a container-backed or daemonizing server keeps its socket in a process devctl never parented. An unavailable `lsof` can never fail a healthy server, since an empty result is not treated as evidence.
  
  `config check` warns when a healthcheck declares `type: http` with no `url`, which silently falls back to a TCP probe: a mistyped key otherwise yields a server reporting healthy while its HTTP layer was never checked. `doctor` also stops calling a listener unmanaged when another supervised server is the one holding the port.
  
  `devctl daemon status --json` now reports `reachable`. Every other command's hint points at this one, and it previously answered `{"launchd": "state = running"}` with exit 0 when nothing was listening, so a script or agent following the hint was told things were fine. `launchd: running` only means a job is loaded, never that the socket accepts.


- [#10](https://github.com/quantizor/devctl/pull/10) [`b7bc910`](https://github.com/quantizor/devctl/commit/b7bc91039cb34c077d51949d6a3cdcaac2a61e11) - Lock resume waits until claimed ports are free before re-ensuring, so a pause no longer races a dirty bind. Composite servers declare a port span or named subports so sibling worktrees rebind a whole claim block (relative offsets move, absolute ports stay singleton), and `devctl why` keeps the refusal lines from the last run across ensure retries instead of going blank on exit 0.



- [#15](https://github.com/quantizor/devctl/pull/15) [`aa209df`](https://github.com/quantizor/devctl/commit/aa209dfdcf5011c2f00b40b7371fe5107ff31123) - `devctl restart <name>` is a real command. Agents were writing `devctl stop X && devctl ensure X` by hand, and several assumed the verb already existed. That pair has two problems this fixes: another session's `ensure` can land between the two commands, and a refusal (a held resource, a paused server, a config that no longer parses) arrives only after the server is already down, leaving it down. A restart now refuses before it stops anything, and keeps the server's resume-on-boot intent, which a manual stop clears.
  
  A server can also list the config files it reads at boot but does not reload on its own, and devctl restarts it when one changes. Without that, a long-lived supervised server keeps running the old config, so a correct fix looks like it did nothing and a test harness keeps checking stale behavior. A server whose framework already reloads its own config declares nothing and behaves exactly as before. A config a server writes during its own startup will not bounce it, one save touching several files is a single restart, and a server that rewrites its own watched file has its watch suspended with a log line naming the culprit rather than restarting forever.


- [#16](https://github.com/quantizor/devctl/pull/16) [`22d5743`](https://github.com/quantizor/devctl/commit/22d57430d486e1de39ba94dde8984b768d33131a) - A daemon that is coming back up no longer looks like one that is gone. While devctld restores supervised servers at boot it kept its socket closed, so every client got `daemon-unreachable`, which is the same answer a daemon that was never started gives. An agent polling across a `daemon install` or `daemon restart` read a busy daemon as a dead one and tried to start another.
  
  The daemon now accepts as soon as its listener is up and says which state it is in. `devctl daemon status` reports `restoring` while it works, and any other command waits the window out instead of failing, saying on stderr what it is waiting for. Commands that reach the daemon mid-restore are refused with `daemon-starting` rather than served against half-restored state, so the ordering guarantee that made the socket closed in the first place is unchanged.


- [#10](https://github.com/quantizor/devctl/pull/10) [`b7bc910`](https://github.com/quantizor/devctl/commit/b7bc91039cb34c077d51949d6a3cdcaac2a61e11) - Two git worktrees of one repo can both run under supervision without editing `devservers.json`. When a sibling checkout already holds the committed port, `ensure` auto-rebinds to a free port, keeps the main origin on the declared host, and gives the worktree an ephemeral `worktree-*.<preferred>.localhost` URL; unrelated projects and unmanaged listeners still get a loud `port-held` naming the holder. Session context and ensure/status JSON warn about latent and rebound conflicts so agents use the live URL, and `lock --no-pause` lets a harness take the mutex without stopping the server it reuses. Discarding a worktree stops its servers and frees the ephemeral host without a manual doctor pass. Bad-state servers in the session-start block still lead with a `devctl why` recommendation and a stderr line count, never the server's own output.


### Patch Changes



- [#16](https://github.com/quantizor/devctl/pull/16) [`22d5743`](https://github.com/quantizor/devctl/commit/22d57430d486e1de39ba94dde8984b768d33131a) - A number in devservers.json can no longer take the daemon down. Out-of-range ports were already caught, but the values beside them were not: a `ports` entry's `offset`, a `portSpan` that overflows when added to its port, and a healthcheck's `healthyAfter`, `intervalMs`, `timeoutMs` and `unhealthyAfter` all reached code that assumed they fit. `devctl config check` now reports each of them by name with the range it expected, and refuses the start rather than letting it crash.
  
  The `offset` case was the one nothing could see. It was checked for being too small but never for being too large, so `config check` called the file clean and reported no errors at all, and the failure only arrived later as an unrelated-looking `daemon-unreachable`.
  
  One bad project no longer stops the others. Reading status across every project validated each one's config along the way, so a single unusable number anywhere on the machine took down the daemon supervising all of them, and the menu bar's polling brought it straight back to do it again.
  
  A damaged state file is no longer fatal either. A process id too large to be one was read back from disk and used directly, which crashed the daemon on startup, and starting again re-read the same file. Such a value is now treated the way an exited process already was.
  
  `devctl lock` no longer reports success while protecting nothing. When a project's config could not be read, the lock found no servers declaring the resource, paused none of them, and said it had taken the hold, so the guarded command ran against a live server still holding the resource open. It now refuses.


- [#16](https://github.com/quantizor/devctl/pull/16) [`22d5743`](https://github.com/quantizor/devctl/commit/22d57430d486e1de39ba94dde8984b768d33131a) - A repo's devservers.json can no longer reach outside what it describes. A server name became a path component of the log directory verbatim, so a name containing `../` made the daemon create directories elsewhere on the machine and write that server's raw output into them. Names are now flattened to a single component, and two names that flatten alike keep separate homes.
  
  Session context is devctl's own words again. A server name, url, or head went into the fenced block unescaped, and a JSON key legally holds a newline, so a pulled branch could close the fence and continue as though the harness were speaking. Those values are now kept to one line and the fence is left intact. The port-conflict warning also carried the squatting process's own command line, chosen by that process; it now says which port and what state, which is the part devctl knows.
  
  A port a TCP port cannot hold took the daemon down. `config check` accepted `"port": 70000`, and the first probe against it crashed devctld, which under launchd came straight back, re-read the same config, and crashed again. Out-of-range ports, including a `portSpan` that runs past the end, are now config errors, and the probe answers that nothing is listening rather than failing.
  
  Logs no longer repeat themselves. A server writing while devctl was reading its output had the overlap ingested twice, so lines appeared in duplicate and error tallies counted them twice.
  
  Two crashes in the same moment now raise two notifications. The menu bar tracked how far it had read using a value it advanced mid-pass, so when several servers went down together, only the first was announced.


- [#16](https://github.com/quantizor/devctl/pull/16) [`22d5743`](https://github.com/quantizor/devctl/commit/22d57430d486e1de39ba94dde8984b768d33131a) - `devctl lock` now catches a change to a large database file that it used to miss. A lock resource above 8 MiB was fingerprinted by its head, its tail, its size, and its mtime, so a command that rewrote the middle while preserving all four was reported as no change at all. A local sqlite database is exactly the shape that happens to, and not noticing is the worst answer a check that exists to notice can give.
  
  A file is now hashed whole at any size, read in chunks so the cost is memory-flat, and the identity no longer claims to be exact when it is not. A directory keeps a byte budget, since its cost is the sum over the whole tree and the fingerprint is taken twice per guarded command.


- [#19](https://github.com/quantizor/devctl/pull/19) [`73280a7`](https://github.com/quantizor/devctl/commit/73280a7cc08c63345285fffec19619bc93c19c96) - A cloned repo's devservers.json can no longer start itself. devctl's rule is that it never acts on a project's committed config until you approve it by running a server there once, but boot restore skipped that check: after a reboot it would bring back a committed server for a project that was never approved. It now honors the same gate every other path does, so an unapproved project's config stays inert until you start it by hand. An explicit `start`, `ensure`, or `up` still records that approval, exactly as before.
  
  `devctl register` now screens a server the same way the config file is screened. Registering a server directly was the one way into the daemon that skipped validation, so a spec `devctl config check` would reject (an out-of-range port, an empty command, a name containing the reserved `::`) could still be registered and then started. It is refused up front now.
  
  `devctl switch` validates the branch's devservers.json before running that branch's lifecycle commands. A config the daemon would refuse to load no longer has its commands handed to the shell anyway, and an empty lifecycle command is now caught by `config check`.
  
  A bad `--grep` pattern can no longer hang the daemon. A regular expression that nests one unbounded repeat inside another (the classic `(a+)+`) makes the engine run for minutes on a single log line; `devctl logs --grep` now rejects that shape before it runs, with a message that names the fix.
  
  devctl no longer hangs waiting on a stuck daemon. A wedged daemon used to leave `devctl` and the menu bar app blocked with no output and no way out; requests now fail in bounded time and point you at `devctl daemon restart`, while a legitimately long `ensure`, `wait`, or group rollout is given the room it needs.
  
  Editing a project's config through the menu bar can only write to a project devctl already tracks, closing a path where a crafted request could have dropped a devservers.json anywhere on disk.


- [#18](https://github.com/quantizor/devctl/pull/18) [`0069434`](https://github.com/quantizor/devctl/commit/0069434c7906828599c69061038a209bc89b4de9) - The installer no longer tells you to fix a PATH that is already fine. It asked the app's own process for its PATH, and the app is launched by Finder, so that was launchd's rather than your shell's: it can never contain `~/.local/bin`, so the warning appeared for everyone whatever their shell actually had.
  
  Asking a login shell was not enough either. `zsh -l` without `-i` runs `.zshenv`, `.zprofile` and `.zlogin` and skips `.zshrc`, which is where most tools put themselves. On the machine this was found, that meant devctl handed every server it started a PATH missing `~/.local/bin`, pnpm, conda and gcloud, so a server script calling `devctl` could not find it. Both the warning and the PATH your servers inherit now reflect what your shell really has.
  
  Reading that PATH means running your shell profile, which devctl does not control, so it now gives up after a while and falls back rather than waiting forever. A profile that waits on the network or on a terminal that is not there used to hang the app at launch with nothing on screen. `DEVCTL_RESOLVING_ENVIRONMENT` is set while it runs, so a profile can skip whatever needs a real session.


- [`b87a4cc`](https://github.com/quantizor/devctl/commit/b87a4cc5efac1ae2ebb99c2d54e62ce9910be10e) - Installing and upgrading devctl from the DMG is clean, with none of the glitches that used to appear around the handoff to Applications.
  
  Installing no longer leaves two menu bar apps running. A second copy of the same app doubles everything you see: two icons, two pollers, and two notifications for one crash. Nothing prevented it, and the install hands off by asking macOS for a new instance by name, so any second trigger produced one, whether that was the relaunch button racing the automatic handoff, a squatting copy that would not quit, or opening the app in Finder while it was already running. A copy that finds the same app already running now steps aside on its own, whichever way it was launched.
  
  Upgrading no longer flashes two menu bar icons. Double-clicking the app in the disk image used to briefly show its icon next to the one for the copy already installed, before the handoff finished. The copy on the disk image now runs purely as an installer: it shows only its setup window and never adds a menu bar icon, so the single icon you see stays the installed one throughout. The disk image copy and the Applications copy still run side by side for the moment the handoff needs, since that pair is the one case where two is correct.
  
  The disk image ejects right after you install. The daemon could end up running its program straight from the mounted image instead of the copy in Applications, because the image and the installed app share an identity and macOS sometimes preferred the mounted one; while that lasted the disk reported itself in use and refused to eject until the daemon happened to restart. The daemon now notices at startup when it is running from a mounted volume and relaunches itself from the installed copy first, so the image is free to eject as soon as you have dragged the app to Applications.
  
  Confirming an upgrade now stops rather than replacing the app in Applications while an old copy is still running it, and says which app to quit. It used to try for a few seconds, give up quietly, and replace the bundle anyway, leaving that copy running code no longer on disk.


- [#16](https://github.com/quantizor/devctl/pull/16) [`22d5743`](https://github.com/quantizor/devctl/commit/22d57430d486e1de39ba94dde8984b768d33131a) - `devctl hook install` can no longer erase your harness settings. It merges its session hook into a file it does not own, and it writes that whole file back, so it has to read everything already in it first. When that read failed, for a stray character mid-edit or anything else that stopped the file parsing, it treated the file as empty and wrote it back with only its own hook in it, taking every other hook, permission and setting along with it, then reported a successful install. It now leaves the file alone and says which file it could not read and why.
  
  The port shown for a server is the port it is actually on. When a server rebound to a different port to avoid a collision with a sibling checkout, the menu bar and the statusline still showed the port it had asked for, sending you somewhere nothing was listening, while the session context shown to agents had it right. All three now agree.
  
  A version mismatch between `devctl` and a running daemon is reported rather than skipped. If the opening handshake failed partway, the connection was left half-open and every later request on it went out without the check ever running again.
  
  A timestamp before 1970 no longer comes out in a form devctl cannot read back.


- [#12](https://github.com/quantizor/devctl/pull/12) [`f5831ac`](https://github.com/quantizor/devctl/commit/f5831ac3fa6c6d3db68082419d6580df22ebd7b4) - A server that loses its port to another supervised server now names that server the way a person reads it. The message carried devctl's internal server id, so it read `managed server '/Users/me/code/proj::web'`, and it now says `'web' in /Users/me/code/proj` with a `devctl stop` command that can be run as printed.



- [#21](https://github.com/quantizor/devctl/pull/21) [`327fc60`](https://github.com/quantizor/devctl/commit/327fc602701fe1a73eecd038553244dc3a98a698) - Server teardown is now safe against pid reuse. Every signal devctl sends while stopping or cleaning up after a server is checked against the identity it recorded for that process while it was alive, so a pid the kernel has since handed to an unrelated process is never signaled. The deliberate-stop path and the crash-cleanup path now share one revalidated sweep, and the crash path, whose process is already gone, no longer directs a signal at its former process group at all.
  
  `devctl stop` now also cleans up a descendant that escaped into the background. A server that spawns a helper which itself exits, leaving a grandchild reparented away, used to leave that grandchild running after a stop; the stop now sweeps the server's whole session, not only the processes still directly parented to it.
  
  The daemon refuses to start rather than erase its own records. If a saved store (the registry, run state, or resource locks) exists but cannot be read, from an I/O error or too many open file descriptors, devctld now exits and lets launchd retry instead of treating the data as absent and overwriting it on the next write. A missing file still starts clean, and an unparseable one is still quarantined and rebuilt.


- [#10](https://github.com/quantizor/devctl/pull/10) [`b7bc910`](https://github.com/quantizor/devctl/commit/b7bc91039cb34c077d51949d6a3cdcaac2a61e11) - Installing or restarting the daemon no longer floods the menu bar with false "server crashed" alerts for the expected bounce, and boot restore finishes before clients connect so upgrade re-ensure does not race and leave servers on a bad port. `devctl why` also diagnoses file-backed projects correctly, and an unexpected server exit tears down leftover child processes so the next ensure is not blocked by stale locks.



- [#12](https://github.com/quantizor/devctl/pull/12) [`f5831ac`](https://github.com/quantizor/devctl/commit/f5831ac3fa6c6d3db68082419d6580df22ebd7b4) - A head or healthcheck url written as a path (`/admin`) now resolves against the server's own effective base, so it follows a rebind or a worktree host swap. It previously serialized as `//:33334/admin`, a value that reads as a URL in the menu bar, Spotlight, `devctl open`, and agent context, and works in none of them. `config check` now rejects a head or healthcheck url that is neither an absolute URL nor a path, and one written as a path on a server that declares no port or url to resolve it against, so the mistake is caught while it is still cheap.
  
  `devctl up` now spawns with the same spec `ensure` does. It prepared each server's spawn and then re-resolved the supervisor inside its dependency waves, which re-applied the committed config to anything not yet running and discarded the prepared spawn: the rebound port, the worktree host, the substituted `{port}` / `{host}` argv, and the injected environment. In a linked worktree that meant the child bound the committed port while devctl reported the rebind, so `up` in two sibling checkouts left both servers stuck starting. Sibling worktrees now coexist under `up` exactly as they already did under `ensure`.


- [#16](https://github.com/quantizor/devctl/pull/16) [`22d5743`](https://github.com/quantizor/devctl/commit/22d57430d486e1de39ba94dde8984b768d33131a) - A crashed server no longer leaves its workers running. When a supervised server spawned a helper process and then crashed, that helper could survive forever, holding its port and its files while devctl reported the server as gone. The next start would then fail on a port held by a process nothing was tracking.
  
  Two things had to line up, and both are common. A helper started through most process APIs lands in its own process group, so signalling the server's group never reaches it, leaving devctl's record of live descendants as the only way to find it. That record was refreshed when the server started and then not again until its first healthcheck, which for a server declaring no healthcheck is a couple of seconds later. A helper started in between was in no record at all.
  
  Teardown now also sweeps by session, which is the one relationship that survives the server exiting and its helpers being adopted by the system. The record is refreshed throughout startup as well, so the common case is caught before the sweep is needed.


- [`be2e7e4`](https://github.com/quantizor/devctl/commit/be2e7e4368c5bc2a8bda10f18c4da457165dc7ab) - A non-finite `--timeout` no longer crashes the command or the daemon. Passing `--timeout inf` (or a value large enough to overflow) to `ensure`, `wait`, `restart`, `up`, `switch`, or `lock` took the command down with a runtime error, and the same value sent on to the daemon crashed the daemon itself, which then respawned under launchd. The command now falls back to its normal response deadline, and the daemon clamps any timeout it receives over its socket to a safe bound before use, so a crafted request cannot bring it down either. This matters most for the agents and scripts that drive devctl with computed timeouts.

## 1.3.0
### Minor Changes



- [#8](https://github.com/quantizor/devctl/pull/8) [`e503e93`](https://github.com/quantizor/devctl/commit/e503e937766af58499f2ff108da04142b28a8ff1) - Ship a DMG installer that places the app in Applications and registers the Login Items agent, keep resource locks across a daemon crash so paused servers resume, and rebind the helper after ad-hoc upgrades so the daemon returns in seconds instead of stalling on a codesign throttle.

All notable changes to this project are documented here. Releases are tagged
`vX.Y.Z` on GitHub (same scheme Changesets uses for this root package).

## 1.2.0

### Minor Changes

- [#4](https://github.com/quantizor/devctl/pull/4) [`40d3e97`](https://github.com/quantizor/devctl/commit/40d3e9741f79b110e08d1ede6515c1ec4636e3c9) - Add Cursor sessionStart harness (`devctl hook install --harness cursor`) so Agent sessions get live `<devctl-servers>` context.
- [#6](https://github.com/quantizor/devctl/pull/6) [`d5ebe80`](https://github.com/quantizor/devctl/commit/d5ebe80704003103c90a8693a53ea5ae044ca840) - Open servers and run lifecycle verbs via `devctl://` URLs (menu bar app + `devctl link` / `devctl x-url`), with unified logging under subsystem `dev.quantizor.devctl`.

### Patch Changes

- [#6](https://github.com/quantizor/devctl/pull/6) [`46ab7b1`](https://github.com/quantizor/devctl/commit/46ab7b17bcf30cbbd336b7e3d7257b0b76586779) - Warn in `config check` when a host or url uses bare `localhost` / `127.0.0.1` instead of a `<slug>.localhost` origin.
- [#6](https://github.com/quantizor/devctl/pull/6) [`4695414`](https://github.com/quantizor/devctl/commit/4695414a2995b0d6f0d3413a1c09c8ecd4e24903) - After `hook install`, print a one-bullet CLAUDE.md / AGENTS.md discovery tip for the project (paste-only; never auto-edits those files).
- [#6](https://github.com/quantizor/devctl/pull/6) [`67d83e7`](https://github.com/quantizor/devctl/commit/67d83e7a569a55735f040ec20b2cf6cc5e3ad4c2) - Restore config-defined servers after reboot and `daemon install` upgrades (merged config+registry recover; install re-ensures like restart).
- [#6](https://github.com/quantizor/devctl/pull/6) [`631a50f`](https://github.com/quantizor/devctl/commit/631a50fe59a6b620eb31d084a6357026e7353354) - Spotlight entries use `<project> · <head>` titles with a `devctl · <url>` subtitle for clearer discovery.

## 1.1.0

### Patch Changes

- Fixed a health check issue with some dev servers that primarily communicate over IPv6.
- Many design improvements.
- Keyboard navigation.
- Sorting & Filtering.

## 1.0.0

Initial public release.
