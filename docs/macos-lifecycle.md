# macOS lifecycle notes

Hard-won platform behavior behind directa's process teardown, launchd supervision, SMAppService registration, and the ad-hoc-signature rebind path. Verified 2026; re-verify before building on any of it, since these are Apple internals that move between OS releases.

## Process sessions

- swift-subprocess `createSession = true` gives the child a fresh session, so `pgid == pid`. Group-directed teardown relies on this.

## Jetsam coalitions

posix_spawn inherits the parent's resource and jetsam coalitions. xnu's default is explicit: "Default is to inherit parent's coalition(s)." `POSIX_SPAWN_SETSID` / `createSession` is a session, not a coalition. Session-leader children of `ddirecta` still sit in the SMAppService agent's jetsam coalition.

SMAppService agents (and user LaunchAgents on macOS 26) get `jetsamproperties category = daemon`, jetsam priority 40, thread limit 32. KeepAlive respawns the job into the same coalition id.

Two different memorystatus paths showed up on 2026-09-02:

- Jetsam snapshot (10:00): posix_spawn children still sat in the agent's coalition. `node` pid 6751 had 221772 resident pages (~3.5 GB) in coalition 91632 with `ddirecta` pid 6616 (945 pages, ~15 MB). `largestProcess` was `node`. That is the inheritance `LaunchdJobLauncher` closes.
- `no_paging_space_action` (16:05, xnu-12377 `kern_proc.c`): compressor/swap exhaustion. The kernel walks every task's `internal_compressed` ledger (`get_task_compressed`), and if the largest process that has no pcontrol action holds more than half the compressor pool it SIGKILLs it and logs `memorystatus: killing largest compressed process %s [%d] %llu MB` (`npcs_max_size / (1024*1024)`, bytes of uncompressed-equivalent compressed anonymous memory, not RSS). Observed: `ddirecta` pid 94572, 176853 MB, and a new 1 GB swapfile at the same second. That figure cannot be resident RAM on a 32 GB Mac with 7 GB swap. The live successor (same binary, same coalition-split children, hours later) is ~19 MB `phys_footprint` / 139 MB lifetime peak, and its jetsam coalition contains only itself. `ps` VSZ of ~415 GB is the ARM64 address-space layout (zsh reports the same) and is not consumption.

Third-party spawn cannot pick a different coalition. `posix_spawnattr_setcoalition_np` is `EPERM` without `com.apple.private.coalition-spawn`. `coalition(COALITION_OP_CREATE)` is `EPERM`. `responsibility_spawnattrs_setdisclaim` (dlsym, pointer ABI, macOS 10.14+) starts a new TCC responsibility chain and does not change jetsam or resource coalition ids (ProcessTreeTests.disclaimDoesNotSplitJetsamCoalition).

The one userland spawn that does create a new jetsam coalition is launchd itself: `launchctl bootstrap` of a `KeepAlive=false` job in `gui/<uid>` yields a new coalition, `ppid=1`, `pgid=pid`. `launchctl submit` also splits, but implies KeepAlive, so a crashed server would be restarted by launchd beside the daemon's phase machine. A bootstrap'd job still gets daemon-category jetsam (prio 40, thread limit 32); `ProcessType=Interactive` on the child does not raise the band, so the child plist omits it. The split is the point (the agent is no longer billed).

`LaunchdJobLauncher` is that path: used only when `XPC_SERVICE_NAME` is the agent label. `ddirecta --foreground` and the unit suites keep posix_spawn. Spool paths come from the supervisor's spool URLs on `SpawnCapture` (`StandardOutPath` / `StandardErrorPath`); launchd opens those paths itself. The supervisor still waits on process death (kqueue `NOTE_EXIT`, because waitpid cannot reap a non-child) and still tears down with the three-source union; bootout unregisters the job after exit. `directa doctor` warns when a live server still shares the daemon's jetsam coalition.

Readout: `CoalitionIDs.read(of:)` via `proc_pidinfo` flavor 20 (`PROC_PIDCOALITIONINFO`, omitted from the public SDK).

## launchd

For the launchd phase:

- Jobs get a minimal PATH without Homebrew. The design captures the user's shell PATH at install time to work around this.
- `ThrottleInterval` defaults to 10s between respawns.
- `ExitTimeOut` (SIGTERM to SIGKILL) defaults to 20s per `launchd.plist(5)`. A sequential drain of many servers at 7s grace each can exceed it, so set it deliberately. 60 is the ceiling: launchd clamps anything larger and logs `ExitTimeOut is larger than the maximum allowed`.
- User agents live in domain `gui/<uid>`, never `system`. `launchctl list`/`print` answer differently depending on the calling context.

## Menu bar extra

`LSUIElement` launches the extra as an accessory app. Accessory apps can show windows, but they cannot become the focused app: the system menu bar stays with whoever was regular. `AppFocus` therefore promotes to `.regular` for the lifetime of a detail window (dashboard, settings, setup, About) so that window can own the directa menu, and demotes back to `.accessory` when the last one closes. The tally popover is not a detail window. Do not flip `LSUIElement` in the plist; the runtime policy is the lever.

The GUI app is a login item (`SMAppService.mainApp`), not a KeepAlive LaunchAgent. Jetsam priority in a 2026-09-02 JetsamEvent was 100 (background-app band) on its own coalition, while `ddirecta` was 40. A login item does not relaunch mid-session, so a kill leaves the tally gone until the next login or an explicit `open`.

MenuBarExtra is not a window AppKit's Transparent App Life-cycle counts as "in use". After the 16:05 daemon jetsam, `directa-app` pid 94113 survived, resurrected the agent (the designed inverse of KeepAlive), then logged `_updateToReflectAutomaticTerminationState` and vanished; kernel `memorystatus` never named it. `NSSupportsAutomaticTermination` / `NSSupportsSuddenTermination` are false and `applicationDidFinishLaunching` calls `disableAutomaticTermination` / `disableSuddenTermination` so AppKit is not invited to quit the extra as idle. A true jetsam of the GUI process is a different hole: this opt-out does not KeepAlive it. Putting the GUI binary itself under `SMAppService.agent` would move it to daemon-category jetsam (priority 40, thread limit 32), which is the wrong band for SwiftUI.

## SMAppService

- `SMAppService.Status` is `enabled = 1` and `requiresApproval = 2`, easy to misread from a raw value in a log.
- `enabled` means a registration exists, not that the job is loaded: after `launchctl bootout` or a replaced bundle the status still reads `enabled` while nothing runs, and `register()` on an already-registered service is a no-op, so the only way back is unregister + register.
- Expect launchd to log `Unknown key for plist importer (key: SHA256 type: data)` on every SMAppService submit. That key is Apple's, not ours.

## BTM launch constraint and the ad-hoc CDHash rebind saga

- The BTM (Background Task Management) launch constraint pins the Team ID when one is present, and a Team ID survives a rebuild, so a Developer ID signed upgrade spawns immediately. Ad-hoc has no Team ID, so the constraint pins the CDHash, which every rebuild changes: that is the whole reason the rebind path exists. `make app` and `make dmg` pick a Developer ID identity automatically, so this only bites a build made where the keychain has none.
- Replacing `Contents/Helpers/ddirecta` under an ad-hoc signature while the BTM item still exists binds the item to the old CDHash, and the next spawn dies with `SIGKILL (Code Signature Invalid)` / Launch Constraint Violation, recorded as a `ddirecta-*.ips` in `~/Library/Logs/DiagnosticReports`.
- Unregister does NOT clear this. `sfltool dumpbtm` (the store is `BackgroundItems-v16.btm` on macOS 26; `sfltool` needs neither sudo nor Full Disk Access) and the `registerLaunchItem: found existing item` log line both show the same item UUID across unregister+register, so re-registering only re-arms the same doomed constraint and burns another 10s `ThrottleInterval` per attempt.
- The constraint clears only when BTM invalidates the item, which xpcproxy triggers on the next spawn attempt rather than on a timed background sweep, and the item UUID changes when it does. Waiting longer for a spawn cannot help, because the job is killed on exec rather than running slowly.
- Diagnose an upgrade that comes up slowly by reading the BTM item UUID and the crash report, never by timing alone.
- DMG upgrades write `agent.rebind` and refuse to replace if the agent is still loaded. `AgentRebindPolicy` bounds how long the app waits before escalating; those waits only cover a job that is genuinely still spawning, not a constraint kill.

## DMG and /Applications share a bundle id

- DMG and `/Applications/directa.app` share a bundle id: never register the SMAppService agent from the volume copy, and never treat `openApplication` of Applications as success unless a different pid is actually running from that path (`createsNewApplicationInstance` plus a peer wait).
- Deep links for daemon control must be opened with `NSWorkspace.open(_:withApplicationAt:)` against the `/Applications/directa.app` path. `open -a` keys on bundle id, so a running DMG installer steals `directa://daemon/unregister`, `SMAppService` on the volume copy reads `notRegistered`, and the Applications-owned agent stays loaded. The volume copy also registers the GetURL handler and forwards any stolen daemon-control URL to that path.
- After a successful copy to `/Applications`, the volume copy always quits. Staying mapped from `/Volumes` pins the DMG ("disk in use") and, if the user ejects anyway, SIGBUS (`backing vnode was force unmounted`) on the next main-thread SwiftUI/accessibility call. Setup is already on disk; a missing menu bar extra is opened from Applications. `relaunchFromApplicationsAndQuit` launches the Applications copy when needed, then terminates (and `exit`s if AppKit ignores terminate).
- The volume copy runs as a headless installer, drawing no menu bar item. Without this an upgrade shows two tally items at once: the already-running Applications copy plus the just-launched DMG copy (they coexist through the handoff by design). The DMG copy is detected by its bundle path being under `/Volumes` (SetupPerformer.runningFromMountedVolume), presents its setup UI through an NSHostingController window from the app delegate rather than the menu bar, and hands off to `/Applications`, whose copy is the only one with a tally. The MenuBarExtra stays in the scene for both (SceneBuilder has no conditional) and the volume copy hides its item via `isInserted: false`.
- Registering from `/Applications` is not enough to keep the daemon off the volume. When the DMG is mounted, Launch Services can still resolve the agent (by shared bundle id) to the volume copy and spawn ddirecta from `/Volumes/directa/...`, even though the BTM registration URL is `/Applications`. The running image then pins the volume, so it cannot be ejected until the daemon cycles. The daemon defends itself: at boot, before taking the single-instance lock, `DaemonImagePolicy` re-execs the canonical installed binary (`/Applications/.../Helpers/ddirecta`, else `~/.local/bin/ddirecta`) whenever its own image (`Bundle.main.executableURL`, symlinks resolved) is under `/Volumes`. A re-exec sentinel and a "run in place when no canonical binary exists" fallback keep it out of a KeepAlive respawn loop.
