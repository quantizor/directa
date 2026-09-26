import Foundation

/** fixture-server: the test double for a real dev server. Modes compose:
    --listen-tcp PORT      accept TCP connections (healthcheck target)
    --exit-after SECONDS   terminate itself after a delay
    --code N               exit code to use with --exit-after
    --spawn-grandchild     spawn a `sleep 1000` child (group-kill verification).
                           Foundation's Process puts it in its OWN process group,
                           so a group-directed kill cannot reach it and only the
                           daemon's descendant snapshot can find it
    --grandchild-after S   delay that spawn (or the --setsid-listener spawn),
                           which is what puts it past the supervisor's early
                           snapshot and makes the teardown race deterministic
                           instead of load-dependent
    --setsid-listener PORT spawn a copy of this fixture listening on PORT in a
                           session of its own (POSIX_SPAWN_SETSID), so neither
                           the root's group nor its session can reach it and
                           only a descendant snapshot taken while the root
                           still parents it can. Prints `setsid listener pid N`
    --exit-after-spawn     exit with --code the moment the setsid listener is
                           spawned, so no snapshot refresh can land between the
                           spawn and the root's exit
    --orphan-grandchild    background a `sleep 1000` through a shell that then
                           exits, so the sleep reparents away from this process
                           but keeps its session. A parent-chain sweep can no
                           longer find it; only a session sweep can. Prints
                           `grandchild pid N` so a teardown test can verify it
    --orphan-grandchild-ignterm
                           same, but the shell traps SIGTERM to ignore, and the
                           backgrounded sleep inherits that ignore: it answers
                           the first SIGTERM pass by ignoring it, so only an
                           escalation pass can reach it
    --ignore-sigterm       install SIG_IGN for SIGTERM (escalation verification)
    --emit-binary          write raw non-UTF8 bytes into stdout once
    --err-lines N          write N lines to stderr at startup (error-tally fixture)
    --flood                write lines as fast as possible
    --print-file PATH      print `config: <first line>` of PATH once at startup,
                           which is how a watch test proves the RESTARTED process
                           read the new file rather than only that a pid changed
    --touch-file PATH      rewrite PATH every 300ms (self-write loop fixture)
    Default behavior: print a heartbeat line every 200ms. */

var listenPort: UInt16?
var exitAfter: Double?
var exitCode: Int32 = 0
var exitAfterSpawn = false
var spawnGrandchild = false
var grandchildAfter: Double?
var orphanGrandchild = false
var orphanGrandchildIgnoresTerm = false
var setsidListenerPort: UInt16?
var ignoreSigterm = false
var emitBinary = false
var errLines = 0
var flood = false
var printFile: String?
var touchFile: String?

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--listen-tcp":
        listenPort = argIterator.next().flatMap { UInt16($0) }
    case "--exit-after":
        exitAfter = argIterator.next().flatMap { Double($0) }
    case "--code":
        exitCode = argIterator.next().flatMap { Int32($0) } ?? 0
    case "--exit-after-spawn":
        exitAfterSpawn = true
    case "--spawn-grandchild":
        spawnGrandchild = true
    case "--grandchild-after":
        grandchildAfter = argIterator.next().flatMap { Double($0) }
    case "--orphan-grandchild":
        orphanGrandchild = true
    case "--orphan-grandchild-ignterm":
        orphanGrandchildIgnoresTerm = true
    case "--setsid-listener":
        setsidListenerPort = argIterator.next().flatMap { UInt16($0) }
    case "--ignore-sigterm":
        ignoreSigterm = true
    case "--emit-binary":
        emitBinary = true
    case "--err-lines":
        errLines = argIterator.next().flatMap { Int($0) } ?? 0
    case "--print-file":
        printFile = argIterator.next()
    case "--touch-file":
        touchFile = argIterator.next()
    case "--flood":
        flood = true
    default:
        FileHandle.standardError.write(Data("fixture-server: unknown argument \(arg)\n".utf8))
        exit(2)
    }
}

setbuf(stdout, nil)

if ignoreSigterm {
    signal(SIGTERM, SIG_IGN)
}

func launchGrandchild() {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["1000"]
    try? child.run()
    print("grandchild pid \(child.processIdentifier)")
}

/** Backgrounds a sleep through a shell that exits immediately, so the sleep
    reparents to launchd while keeping this process's session (no setsid). Only a
    session sweep can find it afterward, which is what a deliberate-stop teardown
    test needs to distinguish from a parent-chain sweep. `$!` is the backgrounded
    pid, echoed to the inherited stdout so the test can read it from the spool.
    `ignoreTerm` makes the shell `trap "" TERM`, an ignored disposition the
    backgrounded sleep inherits: the escalation-verification shape. A plain
    Foundation Process cannot stand in for that, because posix_spawn resets
    inherited dispositions for the direct child. */
func launchOrphanGrandchild(ignoreTerm: Bool) {
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = [
        "-c", ignoreTerm ? "trap \"\" TERM; sleep 1000 & echo grandchild pid $!" : "sleep 1000 & echo grandchild pid $!",
    ]
    try? shell.run()
    shell.waitUntilExit()
}

/** posix_spawn rather than Foundation's `Process`, which cannot set
    POSIX_SPAWN_SETSID. The child inherits this process's stdout and stderr, so
    its own lines land in the same spool. */
func launchSetsidListener(port: UInt16) {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    let argv = [CommandLine.arguments[0], "--listen-tcp", String(port)]
    let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    defer { for arg in cArgs { free(arg) } }
    var child: pid_t = 0
    let status = posix_spawn(&child, argv[0], nil, &attr, cArgs, environ)
    guard status == 0 else {
        FileHandle.standardError.write(
            Data("fixture-server: setsid listener spawn failed: \(String(cString: strerror(status)))\n".utf8))
        return
    }
    print("setsid listener pid \(child)")
}

/** On a background queue so the heartbeat loop below still runs and the
    supervisor sees a normal, healthy-looking server for the whole delay. */
func launch(after delay: Double?, _ body: @escaping @Sendable () -> Void) {
    if let delay {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { body() }
    } else {
        body()
    }
}

if spawnGrandchild {
    launch(after: grandchildAfter) { launchGrandchild() }
}

if let port = setsidListenerPort {
    /** Captured for the same reason as `code` under --exit-after below. */
    let exitNow = exitAfterSpawn
    let code = exitCode
    launch(after: grandchildAfter) {
        launchSetsidListener(port: port)
        if exitNow { exit(code) }
    }
}

if orphanGrandchild {
    launchOrphanGrandchild(ignoreTerm: false)
}

if orphanGrandchildIgnoresTerm {
    launchOrphanGrandchild(ignoreTerm: true)
}

if emitBinary {
    let junk: [UInt8] = [0xFF, 0xFE, 0x00, 0x80, 0x0A]
    FileHandle.standardOutput.write(Data(junk))
}

/** Read once at startup, like a real server reading its config, so a watch test
    can tell "the process restarted" from "the restarted process read the new
    file", which is the difference the feature exists for. */
if let printFile {
    let contents = (try? String(contentsOfFile: printFile, encoding: .utf8)) ?? ""
    print("config: \(contents.split(separator: "\n").first.map(String.init) ?? "")")
}

if let touchFile {
    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
        try? Data("\(Date().timeIntervalSince1970)\n".utf8).write(
            to: URL(fileURLWithPath: touchFile))
    }
}

/** A distinctive token so a test can assert the raw child bytes never leak into
    the agent context block, while its count is still surfaced. */
for index in 0..<errLines {
    FileHandle.standardError.write(Data("FIXTURE-ERR-TOKEN line \(index)\n".utf8))
}

if let listenPort {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = listenPort.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(sock, 16) == 0 else {
        FileHandle.standardError.write(Data("fixture-server: cannot listen on \(listenPort)\n".utf8))
        exit(1)
    }
    print("listening on \(listenPort)")
    Thread {
        while true {
            let client = accept(sock, nil, nil)
            if client < 0 { continue }
            let banner = "hello from fixture-server\n"
            _ = banner.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }.start()
}

if let exitAfter {
    /** Captured here rather than read inside the closure: a top-level `var` is
        main-actor isolated, and the dispatch closure is not. Argument parsing is
        already done, so the value cannot change after this point. */
    let code = exitCode
    DispatchQueue.global().asyncAfter(deadline: .now() + exitAfter) {
        print("exiting with code \(code)")
        exit(code)
    }
}

var heartbeat = 0
while true {
    heartbeat += 1
    print("heartbeat \(heartbeat)")
    if !flood {
        usleep(200_000)
    }
}
