import DirectaKit
import Foundation
import os

/** The one home for "has status changed": a random boot id plus a
    monotonic generation, whose pair is the opaque token `server.awaitChange`
    hands out. Every status-visible mutation calls `bump()`; a client holding
    the current token parks in `wait` until the next bump.

    The waiter list sits under its own lock because bumps arrive from every
    supervisor actor, the event store, and the router, so no single actor's
    isolation can guard it. */
public final class StatusChangeSignal: Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<AwaitChangeResult, Never>
        let timer: Task<Void, Never>
    }

    private struct State {
        var generation: UInt64 = 0
        var nextWaiterID: UInt64 = 0
        var waiters: [UInt64: Waiter] = [:]
    }

    /** Longest a request is held. `receiveLoop` never cancels a request when
        its connection closes, so this bounds how long a disconnected client's
        waiter lingers. */
    public static let maxWaitSeconds: Double = 60

    /** A random per-process value: opaque, never persisted or sorted. A token
        from another daemon process never equals this one's, even when the
        restarted daemon reuses the pid. */
    private let bootID = UUID().uuidString
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /** `seconds` as a wire-supplied timeout: bounded so `Duration.seconds`
        cannot trap, then capped at `maxWaitSeconds`. */
    static func clampedWaitSeconds(_ seconds: Double) -> Double {
        min(ServerSupervisor.boundedTimeoutSeconds(seconds), maxWaitSeconds)
    }

    public var token: String {
        state.withLock { token(generation: $0.generation) }
    }

    /** Moves the token and releases every parked waiter with `changed: true`. */
    public func bump() {
        let (released, generation) = state.withLock { state -> ([Waiter], UInt64) in
            state.generation &+= 1
            let released = Array(state.waiters.values)
            state.waiters.removeAll()
            return (released, state.generation)
        }
        guard !released.isEmpty else { return }

        let token = token(generation: generation)
        for waiter in released {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: AwaitChangeResult(changed: true, token: token))
        }
    }

    /** Parks only while `after` equals the current token. Any other value
        (nil, behind, ahead, from another boot, malformed) answers at once with
        `changed: true`. A parked waiter answers `changed: true` on the next
        bump, or `changed: false` with the same token at its deadline. */
    public func wait(after: String?, timeoutSeconds: Double) async -> AwaitChangeResult {
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.clampedWaitSeconds(timeoutSeconds)))
        return await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> AwaitChangeResult? in
                let current = token(generation: state.generation)
                guard after == current else { return AwaitChangeResult(changed: true, token: current) }
                state.nextWaiterID &+= 1
                let id = state.nextWaiterID
                /** Strong self: the waiter's continuation must always resume. */
                let timer = Task {
                    /** A cancelled sleep means a bump already released this waiter. */
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    expire(waiter: id)
                }
                state.waiters[id] = Waiter(continuation: continuation, timer: timer)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    private func expire(waiter id: UInt64) {
        let (waiter, token) = state.withLock { state in
            (state.waiters.removeValue(forKey: id), token(generation: state.generation))
        }
        waiter?.continuation.resume(returning: AwaitChangeResult(changed: false, token: token))
    }

    private func token(generation: UInt64) -> String {
        "\(bootID)-\(generation)"
    }
}
