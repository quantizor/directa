import DirectaKit
import Foundation

/** The rule-based diagnosis behind `directa why`: turn the data the daemon
    already holds (phase, forensics, health, spool evidence, the dependency
    graph) into a finding chain with a root-cause statement. */
enum WhyEngine {
    /** Diagnoses `target` and walks dependsOn to find the deepest broken
        dependency, which becomes the root cause. */
    static func diagnose(
        target: String,
        statuses: [String: ServerStatus],
        specs: [String: ServerSpec],
        /** Fallback evidence when status has no recentLogTail / terminalEvidence
            (structured-log window since last exit or start). */
        evidenceLines: (String) -> [String],
        /** The most recent `stopped` event's detail for a server, or nil when
            there is none. `ServerSupervisor` writes `ExternalSignalDetail`'s
            `"signal=N (external)"` shape there for a graceful external signal
            (SIGTERM/SIGINT/SIGHUP) and a plain reason clause (`"requested by
            stop"`, `"watch change in …"`) for a directa-requested one;
            `describe` reads `ExternalSignalDetail.matches`, an exact anchored
            check, never a bare `contains`, so a watch-change detail naming a
            path that happens to contain the literal substring "(external)" is
            never mistaken for the marker. */
        lastStopDetail: (String) -> String? = { _ in nil }
    ) -> WhyResult {
        var findings: [WhyFinding] = []
        var visited = Set<String>()
        var rootCause: String?
        var frontier = [target]
        while let name = frontier.popLast() {
            guard visited.insert(name).inserted, let status = statuses[name] else { continue }
            let finding = describe(
                status: status, evidenceLines: evidenceLines, lastStopDetail: lastStopDetail)
            findings.append(finding)
            let broken = status.phase != .running && status.phase != .stopped
            if broken || status.phase == .stopped {
                /** A broken or stopped dependency deeper in the chain supersedes
                    the target's own symptom as root cause. */
                if name != target || rootCause == nil {
                    rootCause = "\(name): \(finding.summary)"
                }
            }
            for dep in specs[name]?.dependsOn ?? [] {
                frontier.append(dep)
            }
        }
        /** The walk visits target first; if a dependency was broken it overwrote
            rootCause last, which is exactly the deepest-cause preference. */
        return WhyResult(findings: findings, rootCause: rootCause)
    }

    private static func describe(
        status: ServerStatus, evidenceLines: (String) -> [String],
        lastStopDetail: (String) -> String? = { _ in nil }
    ) -> WhyFinding {
        var evidence: [String] = []
        var summary: String
        switch status.phase {
        case .failed:
            summary = "spawn never succeeded: \(status.spawnError?.message ?? "unknown spawn error")"
            evidence.append("log: \(status.logPath)")
        case .crashed:
            let cause = status.lastExit?.causeDescription ?? "unknown cause"
            let when = status.lastExit.map { JSONCoding.formatISO8601($0.at) } ?? "unknown time"
            summary = "crashed (\(cause)) at \(when)"
            if status.blockedOn != nil {
                summary +=
                    "; the last runs exited on their own without binding, which looks like an interactive credential prompt the daemon context cannot answer; start the server once in a terminal to surface the prompt, then: directa ensure \(status.server)"
            } else if status.lastExit?.code == 0 {
                summary +=
                    "; exit 0 is often a controlled refusal (framework lock, bind failure), not a crash"
            }
        case .unhealthy:
            let since = status.lastHealthAt.map { JSONCoding.formatISO8601($0) } ?? "startup"
            summary = "healthcheck failing; last healthy \(since)"
        case .starting:
            summary = "still starting; healthcheck (\(status.healthcheck.rawValue)) has not passed yet"
        case .stopped:
            /** A directa-requested stop and a graceful external signal
                (SIGTERM/SIGINT/SIGHUP forwarded by an IDE, a Ctrl-C, another
                process manager) both land here; only the external one has
                nothing else in directa's own log explaining the exit, so it
                is the one worth naming instead of leaving `why` to read like
                nothing happened. */
            if let signal = status.lastExit?.signal,
                let detail = lastStopDetail(status.server), ExternalSignalDetail.matches(detail)
            {
                summary = "not running (stopped by signal \(signal) sent from outside directa)"
            } else {
                summary = "not running (stopped)"
            }
        case .stopping:
            summary = "shutting down"
        case .running:
            summary = "running and healthy"
        }
        switch status.phase {
        case .crashed, .failed, .unhealthy, .starting:
            if let tail = status.recentLogTail, !tail.isEmpty {
                evidence.append(contentsOf: tail)
            } else if let persisted = status.terminalEvidence, !persisted.isEmpty {
                evidence.append(contentsOf: persisted)
            } else {
                evidence.append(contentsOf: evidenceLines(status.server))
            }
        case .running, .stopped, .stopping:
            break
        }
        if let effective = status.effectivePort, let observed = status.observedPort,
            effective != observed
        {
            summary += "; NOTE: listening on \(observed), not the effective \(effective)"
            evidence.append("effective port \(effective), observed \(observed)")
        } else if let declared = status.declaredPort, let observed = status.observedPort,
            declared != observed
        {
            summary += "; NOTE: listening on \(observed), not the declared \(declared)"
            evidence.append("declared port \(declared), observed \(observed)")
        }
        /** A held port is the reason a down server cannot come back, so it belongs
            in the summary that becomes the root cause, not only in evidence the
            reader has to assemble. Phases that are up describe themselves. */
        var foldedIntoSummary = false
        if let conflict = status.portConflict, conflict.state == .held {
            switch status.phase {
            case .crashed, .failed, .stopped:
                summary += "; \(conflict.message)"
                foldedIntoSummary = true
            case .running, .starting, .stopping, .unhealthy:
                break
            }
        }
        /** Only when the summary did not already say it: the summary also
            becomes the root cause, so emitting it here too prints one fact three
            times. */
        if let conflict = status.portConflict, !foldedIntoSummary {
            evidence.append("port conflict (\(conflict.state.rawValue)): \(conflict.message)")
        }
        if let ports = status.ports, !ports.isEmpty {
            let rendered = ports.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            evidence.append("named ports: \(rendered)")
        }
        if status.specStale == true {
            evidence.append("config changed since this process started (restart to apply)")
        }
        return WhyFinding(
            evidence: evidence, phase: status.phase, server: status.server, summary: summary)
    }
}
