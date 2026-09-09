# Changelog

## 2.0.0
### Major Changes



- [#32](https://github.com/quantizor/directa/pull/32) [`45caa88`](https://github.com/quantizor/directa/commit/45caa8884e38737cdc3b1c9e813991a3d210dcc5) - The product is now called directa. The CLI is `directa`, the daemon is `ddirecta`, the menu bar app is `directa.app`, and deep links use `directa://`. `devservers.json` is unchanged.


### Patch Changes



- [#32](https://github.com/quantizor/directa/pull/32) [`45caa88`](https://github.com/quantizor/directa/commit/45caa8884e38737cdc3b1c9e813991a3d210dcc5) - The menu bar app has a standard About panel (directa > About directa) showing the version, copyright, and MIT License.

## 1.5.3
### Patch Changes



- [#30](https://github.com/quantizor/directa/pull/30) [`34c9331`](https://github.com/quantizor/directa/commit/34c933123bbfb7ca82894b11640c34333ca8d19e) - The menu bar icon no longer quits itself as idle after macOS reclaims memory. The extra has no windows AppKit counts as "in use", so a memory-pressure pass was allowed to terminate it, and Start at Login only brings it back at the next login.

## 1.5.2
### Patch Changes



- [#28](https://github.com/quantizor/directa/pull/28) [`3e19c23`](https://github.com/quantizor/directa/commit/3e19c2382a45b43ded510a228eb079d8b8c3dfe4) - A memory-hungry dev server no longer takes the background daemon down with it. Under the menu bar agent, each server now runs as its own launchd job, so macOS can reclaim that server's memory without killing every other server the daemon is supervising.

## 1.5.1
### Patch Changes



- [#26](https://github.com/quantizor/directa/pull/26) [`13e293b`](https://github.com/quantizor/directa/commit/13e293b11fce8ab22d938049621d6adaed6d3528) - Grok Build sessions receive a live server snapshot. `directa hook install --harness grok` wires PreToolUse (the event Grok delivers into context, after the first tool of a turn) and UserPromptSubmit (the per-turn gate) alongside the existing home rule, and removes a leftover SessionStart or Stop registration of the same command. Re-run install to upgrade a SessionStart-only hook; `directa doctor` reports the old install as missing.



- [#26](https://github.com/quantizor/directa/pull/26) [`13e293b`](https://github.com/quantizor/directa/commit/13e293b11fce8ab22d938049621d6adaed6d3528) - A noisy dev server no longer drives the daemon's memory into the tens of gigabytes.



- [#26](https://github.com/quantizor/directa/pull/26) [`13e293b`](https://github.com/quantizor/directa/commit/13e293b11fce8ab22d938049621d6adaed6d3528) - `directa uninstall` now also removes Start at Login and the leftover background item in System Settings, so the app cannot launch itself after you remove it. A DMG-installed app is moved to the Trash; Homebrew's copy is left for brew to remove. `--purge` also deletes preferences and caches.

## 1.5.0
### Minor Changes



- [#25](https://github.com/quantizor/directa/pull/25) [`be1705a`](https://github.com/quantizor/directa/commit/be1705a9ce9d6d7f26bcc277d238373a4622ed92) - Servers in a linked git worktree keep the project's declared host instead of getting an ephemeral `worktree-<label>.<preferred>.localhost` origin. Every `*.localhost` name resolves to loopback, so the label never disambiguated a bind, while the third-level subdomain broke any auth config an app pins to one origin (an OAuth callback, a cookie domain, a CORS allow list, a trusted-origins check). Sibling worktrees of one repo are still told apart: the shared committed port auto-rebinds as before, and the worktree name surfaces as a display value (`worktree` and `mainProject` on status JSON, a `worktree: <label>` line in `directa status` human output and in `config check`, and a banner line in session context). The menu bar app and Spotlight show a worktree server under its project family (`myproj · review`), so searching for the project name still finds it.


### Patch Changes



- [#25](https://github.com/quantizor/directa/pull/25) [`557bc3c`](https://github.com/quantizor/directa/commit/557bc3c1ec0590a3bcd017a9904dd06218d134a5) - Antigravity sessions now rediscover running servers the way Claude Code and Cursor already do. `directa hook install --harness antigravity` (also offered at first run and in Settings when `~/.gemini` is present) wires a PreInvocation hook so a new session sees live `directa` status instead of spawning duplicates. `directa hook uninstall --harness antigravity` removes it.



- [`ef2adc7`](https://github.com/quantizor/directa/commit/ef2adc76f3e7a8d270bbad3b3899c0978950440b) - `directa doctor` now catches a second directa copy shadowing your Homebrew install, the failure where `brew upgrade` changes one copy while a bare `directa` (or the background daemon) keeps running an older one. It reports when a manual `~/.local/bin` install coexists with the Homebrew cask (whichever `~/.local/bin` or brew's bin comes first on your PATH is what actually runs), and when an `/Applications/directa.app` that Homebrew did not place is still present. Each finding names the exact cleanup command. Like doctor's other environment findings, it only reports, and only fires when a Homebrew install is present, so a plain `make install` is never flagged.



- [#25](https://github.com/quantizor/directa/pull/25) [`69232b8`](https://github.com/quantizor/directa/commit/69232b8e845a3a65eb9f4e6c70f1527e68c88bef) - Grok Build is a supported agent harness. `directa hook install --harness grok` (also offered at first run and in Settings when `~/.grok` is present) wires a session hook and a short home rule that tells Grok to run `directa context` before touching a server, so a new session does not spawn duplicates. `directa hook uninstall --harness grok` removes both.



- [#25](https://github.com/quantizor/directa/pull/25) [`b170109`](https://github.com/quantizor/directa/commit/b170109999d2b52039469ed4f7552d6dc8cde77b) - A server whose start command waits on an interactive credential prompt (a secrets CLI unlock, a biometric approval) can no longer crash-loop invisibly. When runs repeatedly exit on their own, nonzero, after tens of seconds, without ever passing a healthcheck, status surfaces `blockedOn: "interactive-auth"` with the remedy in human status, `directa why`, and the session-context block: start the server once in a terminal to surface the prompt, then `directa ensure`. The classification is a heuristic in directa's own words and clears the first time a run dies differently or a healthcheck passes.



- [#25](https://github.com/quantizor/directa/pull/25) [`3f8a7c2`](https://github.com/quantizor/directa/commit/3f8a7c28a6d07fcc8b3606de69e998477c335af8) - Servers under a discarded checkout now stop on their own within about a minute of the checkout disappearing, instead of waiting for a reboot or a machine-wide `directa status --all`. The daemon stats every registered project every 30 seconds and prunes a path only after it is missing on two consecutive sweeps, so one flaky stat (a network mount blip, a slow Finder move) never tears down a live project.



- [#25](https://github.com/quantizor/directa/pull/25) [`8409259`](https://github.com/quantizor/directa/commit/84092598c2f0e5fe91d0215e75436dec12f532ed) - OpenCode is a supported agent harness. `directa hook install --harness opencode` (also offered at first run and in Settings when `~/.config/opencode` is present) writes a managed `~/.config/opencode/directa.md` that tells OpenCode to run `directa context` before touching a server, wired through the `instructions` array of the winning global config file, so a new session discovers the servers without spawning duplicates. OpenCode has no session-start hook to inject live context into, so the standing instruction is the integration; instruction files already referenced by a losing `opencode.json` stay active after the entry lands in `opencode.jsonc`. `directa hook uninstall --harness opencode` removes both halves.



- [#25](https://github.com/quantizor/directa/pull/25) [`3f8a7c2`](https://github.com/quantizor/directa/commit/3f8a7c28a6d07fcc8b3606de69e998477c335af8) - `--project` now refuses anything that is not an existing directory (exit 2, `usage`). Passing a project's NAME instead of its path used to resolve to a nonexistent relative directory and answer an empty scoped view: `directa down --project myproj` reported success against a phantom project while the real server kept running.

## 1.4.1
### Patch Changes



- [`397a4b0`](https://github.com/quantizor/directa/commit/397a4b0e24955bb0d0b9cc58778c1e45ad0ea56e) - The Homebrew install now tells you what to do next. A fresh `brew install --cask quantizor/tap/directa` used to finish with a post-install message that mentioned only uninstall, so you were left with an app that had not started and no hint that the background agent only comes up once you open the app for the first time. The message now names the menu bar app and its agent, the one step to start it (`open -a directa`), the one-time macOS confirmation you will see on that first launch, and how to enable your coding-agent session hooks.

## 1.4.0
### Minor Changes



- [#12](https://github.com/quantizor/directa/pull/12) [`f5831ac`](https://github.com/quantizor/directa/commit/f5831ac3fa6c6d3db68082419d6580df22ebd7b4) - `directa config init` writes a devservers.json from the servers the daemon already knows, which is the way back from losing one. The file is routinely gitignored per machine and nothing could regenerate it, so a lost or destroyed config meant retyping every server by hand. What it writes is deliberately portable: an effective or rebound port, a worktree-derived host, a materialized url, an absolute icon path, and the port and host variables directa injects are all dropped, so a file recovered inside a linked worktree is still correct on someone else's machine. `--dry-run` shows the content without touching disk, and an existing file is refused unless `--force`. `directa register --write` appends one server to the file, leaving every other entry alone.
  
  `directa config check` now reports the host a start would actually use when it differs from the declared one. A linked worktree gets an ephemeral host, so any origin the app itself pins (an auth callback URL, a CORS allow list, an API key referrer restriction) was already wrong with nothing saying so until the app broke.
  
  `directa stop` on a server that declares a resource points at `directa lock`, which gets exclusive access without a bounce, and `ServerStatus` carries the server's `locks` so the same fact reaches `--json` consumers. The session context block names `directa lock` as the way to exclusive access, and its invitation to report directa friction now says to describe the problem generically rather than naming the project, since that backlog lives outside it.


- [#18](https://github.com/quantizor/directa/pull/18) [`0069434`](https://github.com/quantizor/directa/commit/0069434c7906828599c69061038a209bc89b4de9) - directa installs from Homebrew: `brew install --cask quantizor/tap/directa`. `brew upgrade` keeps it current, and when a newer version ships the menu bar popover shows a quiet notice with a one-click Upgrade button that runs the upgrade in Terminal (a Homebrew install) or links to the release notes (a direct download). A direct DMG download still works exactly as before.
  
  A new Settings window, opened from the gear at the bottom of the popover, is the way back to anything you skipped at first run: install or remove the Claude Code and Cursor session hooks per harness, toggle Start at login, and turn the update check on or off. directa still only edits a harness's settings when you click; it never changes them on its own.
  
  Removing directa is now a single command. `directa uninstall` unregisters the background agent, removes the agent hooks, and removes the CLI, keeping your data unless you pass `--purge`; running servers keep going. The Settings window offers the same as a button. `directa doctor` reports a harness whose hook is missing or points at a path that no longer exists, and names the command to fix it.


- [#13](https://github.com/quantizor/directa/pull/13) [`5f24f46`](https://github.com/quantizor/directa/commit/5f24f4634d3ac5ea4d72fc58286f89fe85f3976b) - `directa lock` can now tell you when a command changed the state it was guarding while a server still held that state open. A `locks` entry may name where the resource lives on disk (`{"name": "d1", "path": ".wrangler/state/v3/d1"}`, alongside the plain `"d1"` form, which keeps working unchanged). With a path declared, `lock` fingerprints that state before and after the command. Under `--no-pause` with a declaring server still running, a change is a `resource-mutated` failure naming the servers to stop and the command to re-run, because the running server holds the old state open and can write its cached pages back over what the command wrote. Under the default paused mode the same change is just a note.
  
  This closes a silent data loss: a migration run under `--no-pause` that wiped and rebuilt a local database reported success while the seeded rows were gone, and nothing in the output distinguished that from a clean run. The check is deliberately modest about its limits, and the contract states them: it flags the risk window rather than the damage, it cannot see state outside the declared path or divergence that never reaches disk, and above 8 MiB it samples a file rather than hashing it whole.


- [#13](https://github.com/quantizor/directa/pull/13) [`5f24f46`](https://github.com/quantizor/directa/commit/5f24f4634d3ac5ea4d72fc58286f89fe85f3976b) - `directa lock` no longer passes its own options to the guarded command. `directa lock d1 --timeout 300 -- cmd` ran `env --timeout 300 -- cmd` and died with `env: illegal option -- t`, because the resource name ended option parsing and everything after it was captured as the command. The command is now taken from after `--` verbatim, so a nested `--`, a dash option, and an empty string all survive, while a missing terminator or an unknown option is rejected instead of quietly passed through.
  
  A contended `directa lock` says who holds the resource instead of blocking silently for up to five minutes. It names the holder's pid, how long that run has been going, and which servers it paused or left running, then repeats a still-waiting line while it waits. Silence there reads as a hung gate, and the reflex it invites is killing the run that holds the lock, which is the one making progress. `--acquire-timeout 0` now makes exactly one attempt and fails immediately, which it could not do before: the wait loop never ran its body at a zero budget and failed with a message naming no holder. All of `lock`'s own output moved to stderr, so stdout carries only the guarded command's.


- [#11](https://github.com/quantizor/directa/pull/11) [`ae6a118`](https://github.com/quantizor/directa/commit/ae6a11804fae863f8b3aff02b0443df02c1a75b3) - Port conflicts now announce themselves at the first surface that can see them. `why` names the server and project holding a stopped server's port instead of answering only "not running (stopped)", and the machine-wide status sweep carries the same annotation, so the menu bar app and `doctor` see it too. `doctor` gains a `port-collision` finding for two unrelated projects that declare one port, which the host-keyed signature table could never report because the hostnames differ while the bind does not; sibling worktrees stay excluded since they rebind by design. A server whose healthcheck is answered by another supervised server now fails with `portConflict.state: "foreign"` rather than reporting healthy while serving nothing, and a port held by this server and a stranger at once is reported as `"shared"`. A listener outside the process tree that cannot be attributed to a managed server is annotated but left running, because a container-backed or daemonizing server keeps its socket in a process directa never parented. An unavailable `lsof` can never fail a healthy server, since an empty result is not treated as evidence.
  
  `config check` warns when a healthcheck declares `type: http` with no `url`, which silently falls back to a TCP probe: a mistyped key otherwise yields a server reporting healthy while its HTTP layer was never checked. `doctor` also stops calling a listener unmanaged when another supervised server is the one holding the port.
  
  `directa daemon status --json` now reports `reachable`. Every other command's hint points at this one, and it previously answered `{"launchd": "state = running"}` with exit 0 when nothing was listening, so a script or agent following the hint was told things were fine. `launchd: running` only means a job is loaded, never that the socket accepts.


- [#10](https://github.com/quantizor/directa/pull/10) [`b7bc910`](https://github.com/quantizor/directa/commit/b7bc91039cb34c077d51949d6a3cdcaac2a61e11) - Lock resume waits until claimed ports are free before re-ensuring, so a pause no longer races a dirty bind. Composite servers declare a port span or named subports so sibling worktrees rebind a whole claim block (relative offsets move, absolute ports stay singleton), and `directa why` keeps the refusal lines from the last run across ensure retries instead of going blank on exit 0.



- [#15](https://github.com/quantizor/directa/pull/15) [`aa209df`](https://github.com/quantizor/directa/commit/aa209dfdcf5011c2f00b40b7371fe5107ff31123) - `directa restart <name>` is a real command. Agents were writing `directa stop X && directa ensure X` by hand, and several assumed the verb already existed. That pair has two problems this fixes: another session's `ensure` can land between the two commands, and a refusal (a held resource, a paused server, a config that no longer parses) arrives only after the server is already down, leaving it down. A restart now refuses before it stops anything, and keeps the server's resume-on-boot intent, which a manual stop clears.
  
  A server can also list the config files it reads at boot but does not reload on its own, and directa restarts it when one changes. Without that, a long-lived supervised server keeps running the old config, so a correct fix looks like it did nothing and a test harness keeps checking stale behavior. A server whose framework already reloads its own config declares nothing and behaves exactly as before. A config a server writes during its own startup will not bounce it, one save touching several files is a single restart, and a server that rewrites its own watched file has its watch suspended with a log line naming the culprit rather than restarting forever.


- [#16](https://github.com/quantizor/directa/pull/16) [`22d5743`](https://github.com/quantizor/directa/commit/22d57430d486e1de39ba94dde8984b768d33131a) - A daemon that is coming back up no longer looks like one that is gone. While ddirecta restores supervised servers at boot it kept its socket closed, so every client got `daemon-unreachable`, which is the same answer a daemon that was never started gives. An agent polling across a `daemon install` or `daemon restart` read a busy daemon as a dead one and tried to start another.
  
  The daemon now accepts as soon as its listener is up and says which state it is in. `directa daemon status` reports `restoring` while it works, and any other command waits the window out instead of failing, saying on stderr what it is waiting for. Commands that reach the daemon mid-restore are refused with `daemon-starting` rather than served against half-restored state, so the ordering guarantee that made the socket closed in the first place is unchanged.


- [#10](https://github.com/quantizor/directa/pull/10) [`b7bc910`](https://github.com/quantizor/directa/commit/b7bc91039cb34c077d51949d6a3cdcaac2a61e11) - Two git worktrees of one repo can both run under supervision without editing `devservers.json`. When a sibling checkout already holds the committed port, `ensure` auto-rebinds to a free port, keeps the main origin on the declared host, and gives the worktree an ephemeral `worktree-*.<preferred>.localhost` URL; unrelated projects and unmanaged listeners still get a loud `port-held` naming the holder. Session context and ensure/status JSON warn about latent and rebound conflicts so agents use the live URL, and `lock --no-pause` lets a harness take the mutex without stopping the server it reuses. Discarding a worktree stops its servers and frees the ephemeral host without a manual doctor pass. Bad-state servers in the session-start block still lead with a `directa why` recommendation and a stderr line count, never the server's own output.


### Patch Changes



- [#16](https://github.com/quantizor/directa/pull/16) [`22d5743`](https://github.com/quantizor/directa/commit/22d57430d486e1de39ba94dde8984b768d33131a) - A number in devservers.json can no longer take the daemon down. Out-of-range ports were already caught, but the values beside them were not: a `ports` entry's `offset`, a `portSpan` that overflows when added to its port, and a healthcheck's `healthyAfter`, `intervalMs`, `timeoutMs` and `unhealthyAfter` all reached code that assumed they fit. `directa config check` now reports each of them by name with the range it expected, and refuses the start rather than letting it crash.
  
  The `offset` case was the one nothing could see. It was checked for being too small but never for being too large, so `config check` called the file clean and reported no errors at all, and the failure only arrived later as an unrelated-looking `daemon-unreachable`.
  
  One bad project no longer stops the others. Reading status across every project validated each one's config along the way, so a single unusable number anywhere on the machine took down the daemon supervising all of them, and the menu bar's polling brought it straight back to do it again.
  
  A damaged state file is no longer fatal either. A process id too large to be one was read back from disk and used directly, which crashed the daemon on startup, and starting again re-read the same file. Such a value is now treated the way an exited process already was.
  
  `directa lock` no longer reports success while protecting nothing. When a project's config could not be read, the lock found no servers declaring the resource, paused none of them, and said it had taken the hold, so the guarded command ran against a live server still holding the resource open. It now refuses.


- [#16](https://github.com/quantizor/directa/pull/16) [`22d5743`](https://github.com/quantizor/directa/commit/22d57430d486e1de39ba94dde8984b768d33131a) - A repo's devservers.json can no longer reach outside what it describes. A server name became a path component of the log directory verbatim, so a name containing `../` made the daemon create directories elsewhere on the machine and write that server's raw output into them. Names are now flattened to a single component, and two names that flatten alike keep separate homes.
  
  Session context is directa's own words again. A server name, url, or head went into the fenced block unescaped, and a JSON key legally holds a newline, so a pulled branch could close the fence and continue as though the harness were speaking. Those values are now kept to one line and the fence is left intact. The port-conflict warning also carried the squatting process's own command line, chosen by that process; it now says which port and what state, which is the part directa knows.
  
  A port a TCP port cannot hold took the daemon down. `config check` accepted `"port": 70000`, and the first probe against it crashed ddirecta, which under launchd came straight back, re-read the same config, and crashed again. Out-of-range ports, including a `portSpan` that runs past the end, are now config errors, and the probe answers that nothing is listening rather than failing.
  
  Logs no longer repeat themselves. A server writing while directa was reading its output had the overlap ingested twice, so lines appeared in duplicate and error tallies counted them twice.
  
  Two crashes in the same moment now raise two notifications. The menu bar tracked how far it had read using a value it advanced mid-pass, so when several servers went down together, only the first was announced.


- [#16](https://github.com/quantizor/directa/pull/16) [`22d5743`](https://github.com/quantizor/directa/commit/22d57430d486e1de39ba94dde8984b768d33131a) - `directa lock` now catches a change to a large database file that it used to miss. A lock resource above 8 MiB was fingerprinted by its head, its tail, its size, and its mtime, so a command that rewrote the middle while preserving all four was reported as no change at all. A local sqlite database is exactly the shape that happens to, and not noticing is the worst answer a check that exists to notice can give.
  
  A file is now hashed whole at any size, read in chunks so the cost is memory-flat, and the identity no longer claims to be exact when it is not. A directory keeps a byte budget, since its cost is the sum over the whole tree and the fingerprint is taken twice per guarded command.


- [#19](https://github.com/quantizor/directa/pull/19) [`73280a7`](https://github.com/quantizor/directa/commit/73280a7cc08c63345285fffec19619bc93c19c96) - A cloned repo's devservers.json can no longer start itself. directa's rule is that it never acts on a project's committed config until you approve it by running a server there once, but boot restore skipped that check: after a reboot it would bring back a committed server for a project that was never approved. It now honors the same gate every other path does, so an unapproved project's config stays inert until you start it by hand. An explicit `start`, `ensure`, or `up` still records that approval, exactly as before.
  
  `directa register` now screens a server the same way the config file is screened. Registering a server directly was the one way into the daemon that skipped validation, so a spec `directa config check` would reject (an out-of-range port, an empty command, a name containing the reserved `::`) could still be registered and then started. It is refused up front now.
  
  `directa switch` validates the branch's devservers.json before running that branch's lifecycle commands. A config the daemon would refuse to load no longer has its commands handed to the shell anyway, and an empty lifecycle command is now caught by `config check`.
  
  A bad `--grep` pattern can no longer hang the daemon. A regular expression that nests one unbounded repeat inside another (the classic `(a+)+`) makes the engine run for minutes on a single log line; `directa logs --grep` now rejects that shape before it runs, with a message that names the fix.
  
  directa no longer hangs waiting on a stuck daemon. A wedged daemon used to leave `directa` and the menu bar app blocked with no output and no way out; requests now fail in bounded time and point you at `directa daemon restart`, while a legitimately long `ensure`, `wait`, or group rollout is given the room it needs.
  
  Editing a project's config through the menu bar can only write to a project directa already tracks, closing a path where a crafted request could have dropped a devservers.json anywhere on disk.


- [#18](https://github.com/quantizor/directa/pull/18) [`0069434`](https://github.com/quantizor/directa/commit/0069434c7906828599c69061038a209bc89b4de9) - The installer no longer tells you to fix a PATH that is already fine. It asked the app's own process for its PATH, and the app is launched by Finder, so that was launchd's rather than your shell's: it can never contain `~/.local/bin`, so the warning appeared for everyone whatever their shell actually had.
  
  Asking a login shell was not enough either. `zsh -l` without `-i` runs `.zshenv`, `.zprofile` and `.zlogin` and skips `.zshrc`, which is where most tools put themselves. On the machine this was found, that meant directa handed every server it started a PATH missing `~/.local/bin`, pnpm, conda and gcloud, so a server script calling `directa` could not find it. Both the warning and the PATH your servers inherit now reflect what your shell really has.
  
  Reading that PATH means running your shell profile, which directa does not control, so it now gives up after a while and falls back rather than waiting forever. A profile that waits on the network or on a terminal that is not there used to hang the app at launch with nothing on screen. `DIRECTA_RESOLVING_ENVIRONMENT` is set while it runs, so a profile can skip whatever needs a real session.


- [`b87a4cc`](https://github.com/quantizor/directa/commit/b87a4cc5efac1ae2ebb99c2d54e62ce9910be10e) - Installing and upgrading directa from the DMG is clean, with none of the glitches that used to appear around the handoff to Applications.
  
  Installing no longer leaves two menu bar apps running. A second copy of the same app doubles everything you see: two icons, two pollers, and two notifications for one crash. Nothing prevented it, and the install hands off by asking macOS for a new instance by name, so any second trigger produced one, whether that was the relaunch button racing the automatic handoff, a squatting copy that would not quit, or opening the app in Finder while it was already running. A copy that finds the same app already running now steps aside on its own, whichever way it was launched.
  
  Upgrading no longer flashes two menu bar icons. Double-clicking the app in the disk image used to briefly show its icon next to the one for the copy already installed, before the handoff finished. The copy on the disk image now runs purely as an installer: it shows only its setup window and never adds a menu bar icon, so the single icon you see stays the installed one throughout. The disk image copy and the Applications copy still run side by side for the moment the handoff needs, since that pair is the one case where two is correct.
  
  The disk image ejects right after you install. The daemon could end up running its program straight from the mounted image instead of the copy in Applications, because the image and the installed app share an identity and macOS sometimes preferred the mounted one; while that lasted the disk reported itself in use and refused to eject until the daemon happened to restart. The daemon now notices at startup when it is running from a mounted volume and relaunches itself from the installed copy first, so the image is free to eject as soon as you have dragged the app to Applications.
  
  Confirming an upgrade now stops rather than replacing the app in Applications while an old copy is still running it, and says which app to quit. It used to try for a few seconds, give up quietly, and replace the bundle anyway, leaving that copy running code no longer on disk.


- [#16](https://github.com/quantizor/directa/pull/16) [`22d5743`](https://github.com/quantizor/directa/commit/22d57430d486e1de39ba94dde8984b768d33131a) - `directa hook install` can no longer erase your harness settings. It merges its session hook into a file it does not own, and it writes that whole file back, so it has to read everything already in it first. When that read failed, for a stray character mid-edit or anything else that stopped the file parsing, it treated the file as empty and wrote it back with only its own hook in it, taking every other hook, permission and setting along with it, then reported a successful install. It now leaves the file alone and says which file it could not read and why.
  
  The port shown for a server is the port it is actually on. When a server rebound to a different port to avoid a collision with a sibling checkout, the menu bar and the statusline still showed the port it had asked for, sending you somewhere nothing was listening, while the session context shown to agents had it right. All three now agree.
  
  A version mismatch between `directa` and a running daemon is reported rather than skipped. If the opening handshake failed partway, the connection was left half-open and every later request on it went out without the check ever running again.
  
  A timestamp before 1970 no longer comes out in a form directa cannot read back.


- [#12](https://github.com/quantizor/directa/pull/12) [`f5831ac`](https://github.com/quantizor/directa/commit/f5831ac3fa6c6d3db68082419d6580df22ebd7b4) - A server that loses its port to another supervised server now names that server the way a person reads it. The message carried directa's internal server id, so it read `managed server '/Users/me/code/proj::web'`, and it now says `'web' in /Users/me/code/proj` with a `directa stop` command that can be run as printed.



- [#21](https://github.com/quantizor/directa/pull/21) [`327fc60`](https://github.com/quantizor/directa/commit/327fc602701fe1a73eecd038553244dc3a98a698) - Server teardown is now safe against pid reuse. Every signal directa sends while stopping or cleaning up after a server is checked against the identity it recorded for that process while it was alive, so a pid the kernel has since handed to an unrelated process is never signaled. The deliberate-stop path and the crash-cleanup path now share one revalidated sweep, and the crash path, whose process is already gone, no longer directs a signal at its former process group at all.
  
  `directa stop` now also cleans up a descendant that escaped into the background. A server that spawns a helper which itself exits, leaving a grandchild reparented away, used to leave that grandchild running after a stop; the stop now sweeps the server's whole session, not only the processes still directly parented to it.
  
  The daemon refuses to start rather than erase its own records. If a saved store (the registry, run state, or resource locks) exists but cannot be read, from an I/O error or too many open file descriptors, ddirecta now exits and lets launchd retry instead of treating the data as absent and overwriting it on the next write. A missing file still starts clean, and an unparseable one is still quarantined and rebuilt.


- [#10](https://github.com/quantizor/directa/pull/10) [`b7bc910`](https://github.com/quantizor/directa/commit/b7bc91039cb34c077d51949d6a3cdcaac2a61e11) - Installing or restarting the daemon no longer floods the menu bar with false "server crashed" alerts for the expected bounce, and boot restore finishes before clients connect so upgrade re-ensure does not race and leave servers on a bad port. `directa why` also diagnoses file-backed projects correctly, and an unexpected server exit tears down leftover child processes so the next ensure is not blocked by stale locks.



- [#12](https://github.com/quantizor/directa/pull/12) [`f5831ac`](https://github.com/quantizor/directa/commit/f5831ac3fa6c6d3db68082419d6580df22ebd7b4) - A head or healthcheck url written as a path (`/admin`) now resolves against the server's own effective base, so it follows a rebind or a worktree host swap. It previously serialized as `//:33334/admin`, a value that reads as a URL in the menu bar, Spotlight, `directa open`, and agent context, and works in none of them. `config check` now rejects a head or healthcheck url that is neither an absolute URL nor a path, and one written as a path on a server that declares no port or url to resolve it against, so the mistake is caught while it is still cheap.
  
  `directa up` now spawns with the same spec `ensure` does. It prepared each server's spawn and then re-resolved the supervisor inside its dependency waves, which re-applied the committed config to anything not yet running and discarded the prepared spawn: the rebound port, the worktree host, the substituted `{port}` / `{host}` argv, and the injected environment. In a linked worktree that meant the child bound the committed port while directa reported the rebind, so `up` in two sibling checkouts left both servers stuck starting. Sibling worktrees now coexist under `up` exactly as they already did under `ensure`.


- [#16](https://github.com/quantizor/directa/pull/16) [`22d5743`](https://github.com/quantizor/directa/commit/22d57430d486e1de39ba94dde8984b768d33131a) - A crashed server no longer leaves its workers running. When a supervised server spawned a helper process and then crashed, that helper could survive forever, holding its port and its files while directa reported the server as gone. The next start would then fail on a port held by a process nothing was tracking.
  
  Two things had to line up, and both are common. A helper started through most process APIs lands in its own process group, so signalling the server's group never reaches it, leaving directa's record of live descendants as the only way to find it. That record was refreshed when the server started and then not again until its first healthcheck, which for a server declaring no healthcheck is a couple of seconds later. A helper started in between was in no record at all.
  
  Teardown now also sweeps by session, which is the one relationship that survives the server exiting and its helpers being adopted by the system. The record is refreshed throughout startup as well, so the common case is caught before the sweep is needed.


- [`be2e7e4`](https://github.com/quantizor/directa/commit/be2e7e4368c5bc2a8bda10f18c4da457165dc7ab) - A non-finite `--timeout` no longer crashes the command or the daemon. Passing `--timeout inf` (or a value large enough to overflow) to `ensure`, `wait`, `restart`, `up`, `switch`, or `lock` took the command down with a runtime error, and the same value sent on to the daemon crashed the daemon itself, which then respawned under launchd. The command now falls back to its normal response deadline, and the daemon clamps any timeout it receives over its socket to a safe bound before use, so a crafted request cannot bring it down either. This matters most for the agents and scripts that drive directa with computed timeouts.

## 1.3.0
### Minor Changes



- [#8](https://github.com/quantizor/directa/pull/8) [`e503e93`](https://github.com/quantizor/directa/commit/e503e937766af58499f2ff108da04142b28a8ff1) - Ship a DMG installer that places the app in Applications and registers the Login Items agent, keep resource locks across a daemon crash so paused servers resume, and rebind the helper after ad-hoc upgrades so the daemon returns in seconds instead of stalling on a codesign throttle.

All notable changes to this project are documented here. Releases are tagged
`vX.Y.Z` on GitHub (same scheme Changesets uses for this root package).

## 1.2.0

### Minor Changes

- [#4](https://github.com/quantizor/directa/pull/4) [`40d3e97`](https://github.com/quantizor/directa/commit/40d3e9741f79b110e08d1ede6515c1ec4636e3c9) - Add Cursor sessionStart harness (`directa hook install --harness cursor`) so Agent sessions get live `<directa-servers>` context.
- [#6](https://github.com/quantizor/directa/pull/6) [`d5ebe80`](https://github.com/quantizor/directa/commit/d5ebe80704003103c90a8693a53ea5ae044ca840) - Open servers and run lifecycle verbs via `directa://` URLs (menu bar app + `directa link` / `directa x-url`), with unified logging under subsystem `dev.quantizor.directa`.

### Patch Changes

- [#6](https://github.com/quantizor/directa/pull/6) [`46ab7b1`](https://github.com/quantizor/directa/commit/46ab7b17bcf30cbbd336b7e3d7257b0b76586779) - Warn in `config check` when a host or url uses bare `localhost` / `127.0.0.1` instead of a `<slug>.localhost` origin.
- [#6](https://github.com/quantizor/directa/pull/6) [`4695414`](https://github.com/quantizor/directa/commit/4695414a2995b0d6f0d3413a1c09c8ecd4e24903) - After `hook install`, print a one-bullet CLAUDE.md / AGENTS.md discovery tip for the project (paste-only; never auto-edits those files).
- [#6](https://github.com/quantizor/directa/pull/6) [`67d83e7`](https://github.com/quantizor/directa/commit/67d83e7a569a55735f040ec20b2cf6cc5e3ad4c2) - Restore config-defined servers after reboot and `daemon install` upgrades (merged config+registry recover; install re-ensures like restart).
- [#6](https://github.com/quantizor/directa/pull/6) [`631a50f`](https://github.com/quantizor/directa/commit/631a50fe59a6b620eb31d084a6357026e7353354) - Spotlight entries use `<project> · <head>` titles with a `directa · <url>` subtitle for clearer discovery.

## 1.1.0

### Patch Changes

- Fixed a health check issue with some dev servers that primarily communicate over IPv6.
- Many design improvements.
- Keyboard navigation.
- Sorting & Filtering.

## 1.0.0

Initial public release.
