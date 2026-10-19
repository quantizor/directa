import DirectaKit
import Foundation

/** The listener lookup that tells an answer from a failure. `PortGuard.listenerPids`
    folds "lsof found nothing" and "lsof could not run" into one empty list, which
    is right for a diagnostic that only annotates, and wrong for the one caller
    that treats an empty answer as evidence (the post-healthy scan's note that
    nothing was listening). */
extension PortGuard {
    /** Every pid listening on `port`, or nil when lsof did not answer: it could
        not start, outlived its deadline, wrote past the output cap, or exited
        with a status that is neither "found" (0) nor "found nothing" (1). An
        empty array is an answer. */
    public static func answeredListenerPids(port: Int) -> [Int]? {
        let path = "/usr/sbin/lsof"
        let arguments = ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]
        let outcome = HelperCommand.run(
            path, arguments, includeStderr: false,
            timeoutSeconds: HelperCommand.defaultTimeoutSeconds(executable: path, arguments: arguments)
                ?? HelperCommand.lsofTimeoutSeconds)
        guard case .exited(let status, let output) = outcome, status == 0 || status == 1 else {
            return nil
        }
        var pids: [Int] = []
        for line in output.split(separator: "\n") {
            guard let pid = Int(line.trimmingCharacters(in: .whitespaces)) else { continue }
            if !pids.contains(pid) { pids.append(pid) }
        }
        return pids
    }

    public static func answeredListenerPids(port: Int) async -> [Int]? {
        await BlockingLane.system.run { answeredListenerPids(port: port) }
    }
}
