import DirectaDaemonCore
import DirectaKit
import Foundation
import IOKit
import IOKit.pwr_mgt

/** ddirecta: the daemon. Runs identically under launchd and --foreground; the only
    difference is who started it. Exits nonzero on startup failure so launchd's
    KeepAlive={SuccessfulExit:false} relaunches crashes but honors clean exits. */

/** The absolute path of the running executable image, symlinks resolved. Uses
    `Bundle.main.executableURL`, the image the kernel mapped, rather than argv[0],
    which a launcher can set to anything. */
func currentExecutablePath() -> String? {
    Bundle.main.executableURL?.resolvingSymlinksInPath().path
}

var socketOverride: String?
var dataDirOverride: String?
var logsDirOverride: String?
var foreground = false

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--foreground":
        foreground = true
    case "--socket":
        socketOverride = argIterator.next()
    case "--data-dir":
        dataDirOverride = argIterator.next()
    case "--logs-dir":
        logsDirOverride = argIterator.next()
    case "--version":
        print(DirectaVersion.version)
        exit(0)
    default:
        FileHandle.standardError.write(Data("ddirecta: unknown argument \(arg)\n".utf8))
        exit(2)
    }
}

/** Never keep the daemon's process image on a mounted volume. A DMG shares the
    installed app's bundle id, so Launch Services can spawn the daemon from the
    volume copy and pin the volume open (see DaemonImagePolicy). Re-exec the
    canonical installed binary before any lock or socket work, so the volume
    process never takes the single-instance lock. */
if let selfExecutable = currentExecutablePath() {
    let candidates = [
        URL(fileURLWithPath: SetupPlanner.applicationsAppPath)
            .appending(path: "Contents/Helpers/\(SetupPlanner.daemonBinaryName)").path,
        SetupPlanner.installedDaemonSiblingURL().path,
    ]
    let decision = DaemonImagePolicy.decide(
        currentExecutable: selfExecutable,
        candidates: candidates,
        alreadyReexeced: ProcessInfo.processInfo.environment["DIRECTA_DAEMON_REEXECED"] == "1",
        fileExists: { FileManager.default.fileExists(atPath: $0) })
    if case .reexec(let target) = decision {
        FileHandle.standardError.write(
            Data(
                "ddirecta: image is on a mounted volume (\(selfExecutable)); re-exec from \(target)\n"
                    .utf8))
        setenv("DIRECTA_DAEMON_REEXECED", "1", 1)
        var argv = CommandLine.arguments
        argv[0] = target
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        execv(target, cArgs)
        /** execv only returns on failure; fall through and run in place rather
            than exit into a KeepAlive respawn of the same volume image. */
        FileHandle.standardError.write(
            Data(
                "ddirecta: execv(\(target)) failed: \(String(cString: strerror(errno))); continuing in place\n"
                    .utf8))
    }
}

if let socketOverride {
    setenv("DIRECTA_SOCKET", socketOverride, 1)
}

let paths = DirectaPaths(
    dataDir: dataDirOverride.map { URL(fileURLWithPath: $0) },
    logsDir: logsDirOverride.map { URL(fileURLWithPath: $0) }
)

do {
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("ddirecta: cannot create data/logs dirs: \(error)\n".utf8))
    exit(1)
}

/** Checked before the lock, not after: an over-long `DIRECTA_SOCKET` reaches
    `NWListener` as a truncated `sockaddr_un` that binds nowhere, so the daemon
    printed its "listening on" line and held the single-instance lock forever
    over a socket nothing could ever connect to. `DaemonClient` already refuses
    this path with the same wording before ever calling `connect(2)`; failing
    here first means neither end pretends the daemon is reachable. */
guard DirectaPaths.fitsSunPath(paths.socketPath) else {
    FileHandle.standardError.write(
        Data("ddirecta: \(DirectaPaths.sunPathLimitMessage(paths.socketPath))\n".utf8))
    exit(1)
}

/** Single-instancing: an exclusive flock held for the daemon's lifetime. Only the
    lock holder may unlink and rebind the socket, so stale-socket takeover cannot
    race between two starting daemons. */
let lockFD = open(paths.lockFile.path, O_WRONLY | O_CREAT, 0o600)
guard lockFD >= 0 else {
    FileHandle.standardError.write(Data("ddirecta: cannot open lock file: \(String(cString: strerror(errno)))\n".utf8))
    exit(1)
}
guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    FileHandle.standardError.write(Data("ddirecta: another ddirecta instance holds \(paths.lockFile.path); exiting\n".utf8))
    exit(0)
}

/** Raise the fd ceiling only when below the target: launchd jobs default to a
    256 soft limit, and a dozen servers plus log subscribers approaches it. Never
    lower an already-higher soft limit. */
var limit = rlimit()
if getrlimit(RLIMIT_NOFILE, &limit) == 0 {
    let target = min(limit.rlim_max, rlim_t(8192))
    if limit.rlim_cur < target {
        limit.rlim_cur = target
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            FileHandle.standardError.write(
                Data(
                    "ddirecta: setrlimit(RLIMIT_NOFILE) failed: \(String(cString: strerror(errno)))\n"
                        .utf8))
        }
    }
}

/** A running daemon is proof any prior deliberate-stop intent is spent. */
try? FileManager.default.removeItem(at: paths.stoppedIntentFile)

/** Merge the install-time login PATH before any child spawn so Homebrew tools
    stay findable under a sealed in-bundle LaunchAgent. */
LaunchdAdmin.applyAgentPathToProcess(paths: paths)

/** Refuse to start on a persisted store that exists but cannot be READ (EMFILE
    as the daemon nears its fd limit, an I/O error, a permission change): treating
    it as absent would let the next write erase real registry, state, or lock
    data. A missing file is fine (first run), and a corrupt one is quarantined by
    the load. Exiting non-zero here leaves the data intact and lets launchd retry
    after the throttle window, when a transient failure has likely cleared. */
do {
    _ = try AtomicFile.load(RegistryFile.self, from: paths.registryFile)
    _ = try AtomicFile.load(StateFile.self, from: paths.stateFile)
    _ = try AtomicFile.load(LocksFile.self, from: paths.locksFile)
} catch {
    FileHandle.standardError.write(
        Data(
            "ddirecta: a saved store exists but could not be read (\(error)); refusing to start so it is not overwritten. Free file descriptors or fix the file's permissions, then retry.\n"
                .utf8))
    exit(1)
}

let registry = Registry(paths: paths)
let launcher: any ProcessLauncher =
    LaunchdJobLauncher.runningAsAgent ? LaunchdJobLauncher() : SubprocessLauncher()
let router = Router(launcher: launcher, paths: paths, registry: registry)

/** Sleep/wake awareness: health probes pause during sleep and get a grace
    window on wake so lid-open does not flap every server unhealthy. IOKit
    message macros (`kIOMessageCanSystemSleep` et al.) do not bridge into Swift;
    these named values match IOMessage.h (`iokit_common_msg`). */
enum PowerMessage {
    static let canSystemSleep: natural_t = 0xE000_0270
    static let systemHasPoweredOn: natural_t = 0xE000_0300
    static let systemWillSleep: natural_t = 0xE000_0280
}
final class PowerContext {
    var rootPort: io_connect_t = 0
}
let powerContext = PowerContext()
var powerNotifier: io_object_t = 0
var powerPort: IONotificationPortRef?
powerContext.rootPort = IORegisterForSystemPower(
    Unmanaged.passUnretained(powerContext).toOpaque(),
    &powerPort,
    { refcon, _, messageType, argument in
        guard let refcon else { return }
        let context = Unmanaged<PowerContext>.fromOpaque(refcon).takeUnretainedValue()
        switch messageType {
        case PowerMessage.canSystemSleep, PowerMessage.systemWillSleep:
            if messageType == PowerMessage.systemWillSleep {
                Task { await PowerState.shared.recordSleep() }
            }
            /** Sleep is never vetoed; failing to acknowledge stalls the system. */
            IOAllowPowerChange(context.rootPort, Int(bitPattern: argument))
        case PowerMessage.systemHasPoweredOn:
            Task { await PowerState.shared.recordWake() }
        default:
            break
        }
    },
    &powerNotifier)
if powerContext.rootPort == 0 {
    FileHandle.standardError.write(
        Data("ddirecta: IORegisterForSystemPower failed; sleep/wake probes are unaware\n".utf8))
} else if let powerPort {
    IONotificationPortSetDispatchQueue(powerPort, DispatchQueue.main)
}

let server: ControlServer
do {
    server = try ControlServer(router: router, socketPath: paths.socketPath)
} catch {
    FileHandle.standardError.write(Data("ddirecta: cannot bind \(paths.socketPath): \(error)\n".utf8))
    exit(1)
}

/** Graceful termination: drain-stop every supervised server through the normal
    teardown path, unregister power notifications, then exit 0 (a deliberate
    stop must not trigger KeepAlive). */
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
terminationSource.setEventHandler {
    Task { @MainActor in
        await router.drainAll()
        if let port = powerPort {
            IONotificationPortSetDispatchQueue(port, nil)
        }
        if powerNotifier != 0 {
            IODeregisterForSystemPower(&powerNotifier)
            powerNotifier = 0
        }
        if powerContext.rootPort != 0 {
            IOServiceClose(powerContext.rootPort)
            powerContext.rootPort = 0
        }
        if let port = powerPort {
            IONotificationPortDestroy(port)
            powerPort = nil
        }
        exit(0)
    }
}
terminationSource.resume()

/** Accept before restore, but serve nothing but identity until restore is done.
    Refusing with a reason and finishing restore before any real work are both
    requirements: install/restart re-ensure must not race a half-finished
    restore, and a client that connects during it must be able to tell a busy
    daemon from a dead one. Closing the socket satisfied the first and defeated
    the second, since ENOENT is what a daemon that never started looks like. */
Task {
    await router.setRestoring(true)
    let socketPath = paths.socketPath
    /** Awaited rather than assumed: `NWListener.start` is asynchronous and the
        socket path does not exist until the listener reaches `.ready`, so
        proceeding on the next statement would leave a window that still answers
        ENOENT, which is the exact failure this ordering exists to remove. */
    do {
        try await server.startAccepting()
    } catch {
        FileHandle.standardError.write(
            Data("ddirecta: control listener never accepted on \(socketPath): \(error)\n".utf8))
        exit(1)
    }
    await router.recoverAtStartup()
    await router.setRestoring(false)
    /** Announced after restore, so the line still means the daemon is ready for
        work. Anything waiting on it (the smoke gate, `daemon install`) keeps the
        guarantee it always had. */
    FileHandle.standardError.write(
        Data(
            "ddirecta \(DirectaVersion.version) listening on \(socketPath) (pid \(getpid()))\n"
                .utf8))
    /** The watch sweep starts only after restore, so a boot-time spawn is never
        mistaken for a config change. Polling rather than an fd-based watcher:
        nearly every editor and build tool saves by writing a temp file and
        renaming it over the target, after which a held fd names an unlinked
        inode and goes deaf to the path it was watching. */
    Task {
        DirectaLog.daemon.info("watch sweep started")
        /** Exits on cancellation rather than looping on `while true`. Nothing
            cancels this today, but `try?` over a sleep turns a cancelled task
            into a tight spin that sweeps the process table as fast as the CPU
            allows, and the guard costs one comparison per half second. */
        while !Task.isCancelled {
            _ = await router.sweepWatches()
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                break
            }
        }
        DirectaLog.daemon.info("watch sweep stopped")
    }
    /** The missing-project sweep: one stat per registered project per interval,
        pruned only on the second consecutive miss. Also after restore for the
        same reason: pruning is destructive on the registry rows recovery
        replays, and the two must not race. */
    Task {
        DirectaLog.daemon.info("missing-project sweep started")
        while !Task.isCancelled {
            let pruned = await router.sweepMissingProjects()
            if pruned > 0 {
                DirectaLog.daemon.info("missing-project sweep pruned \(pruned)")
            }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                break
            }
        }
        DirectaLog.daemon.info("missing-project sweep stopped")
    }
}

dispatchMain()
