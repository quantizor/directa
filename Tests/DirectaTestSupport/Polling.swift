import Darwin

/** The one home for waiting on a condition a test does not control the timing
    of. Each wait is bounded by a deadline and suspends between checks, so it
    never holds a cooperative-pool thread; work that must block its thread
    goes through `offPool` instead. */

/** The first non-nil `produce()` answer, asked every `interval` until
    `limit` elapses; nil when none arrived. `produce` runs once more at the
    deadline, so a condition that turns true during the final sleep counts. */
public func firstAnswer<Value>(
    within limit: Duration, every interval: Duration = .milliseconds(10),
    _ produce: () async throws -> Value?
) async throws -> Value? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while true {
        if let value = try await produce() { return value }
        guard clock.now < deadline else { return nil }
        try await Task.sleep(for: interval)
    }
}

/** Whether `condition` held at some check within `limit`. A test proving
    that something never happens asserts `!(await eventually(...))`, which
    watches the whole window. */
public func eventually(
    within limit: Duration, every interval: Duration = .milliseconds(10),
    _ condition: () async throws -> Bool
) async throws -> Bool {
    try await firstAnswer(within: limit, every: interval) { try await condition() ? true : nil } ?? false
}

/** Whether `pid` stopped answering `kill(pid, 0)` within `limit`. A zombie
    still answers, so the caller's process must be reaped by someone. */
public func awaitExit(_ pid: pid_t, within limit: Duration) async throws -> Bool {
    try await eventually(within: limit) { kill(pid, 0) != 0 }
}
