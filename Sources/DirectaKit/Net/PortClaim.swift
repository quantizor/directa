import Foundation

/** A named secondary listener relative to the effective primary, or an absolute
    machine-singleton port. Exactly one of `offset` or `port` must be set. */
public struct SecondaryPort: Codable, Equatable, Sendable {
    public var env: String?
    public var offset: Int?
    public var port: Int?

    public init(env: String? = nil, offset: Int? = nil, port: Int? = nil) {
        self.env = env
        self.offset = offset
        self.port = port
    }

    /** Nil when the entry is well-formed; otherwise a config-check message. */
    public func validationError(name: String) -> String? {
        switch (offset, port) {
        case (nil, nil):
            return "ports.\(name): set offset or port"
        case (.some, .some):
            return "ports.\(name): set offset or port, not both"
        case (.some(let value), nil) where !PortClaim.offsetRange.contains(value):
            /** Bounded above as well as below. With a floor only, an extreme
                offset produced no config error at all, so `directa config check`
                called the file clean and `primary + offset` then trapped on the
                spawn path, taking the daemon down with a message about the
                daemon being unreachable. */
            return "ports.\(name): offset must be 0...65534"
        case (nil, .some(let value)) where !PortClaim.portRange.contains(value):
            return "ports.\(name): port must be 1...65535"
        default:
            return nil
        }
    }
}

/** Every port a spawn claims: primary, optional consecutive span sugar, and
    named secondaries. Pure; allocate / settle / materialize all use this set. */
public struct PortClaim: Equatable, Sendable {
    /** What a TCP port can hold, and the widest offset from a primary that can
        still land inside it. One home, because these bounds were previously
        stated three times with three different answers: the primary was checked,
        a secondary port was checked, an offset had a floor but no ceiling, and a
        span had neither. Every check below reads them from here. */
    public static let offsetRange = 0...65_534
    public static let portRange = 1...65_535

    /** Fixed ports that never shift with sibling rebind. */
    public var absolute: [Int]
    /** Env key → resolved number for child injection (primary + named with env). */
    public var injections: [String: Int]
    /** Named secondary → resolved number (for status / agents). */
    public var named: [String: Int]
    public var primary: Int?
    /** Primary plus every relative member (span sugar and named offsets). */
    public var relative: [Int]

    public init(
        absolute: [Int] = [],
        injections: [String: Int] = [:],
        named: [String: Int] = [:],
        primary: Int? = nil,
        relative: [Int] = []
    ) {
        self.absolute = absolute
        self.injections = injections
        self.named = named
        self.primary = primary
        self.relative = relative
    }

    /** Unique sorted ports that must be free for this claim. */
    public var allPorts: [Int] {
        Array(Set(relative + absolute)).sorted()
    }

    /** Offsets from primary that must stay free when searching for a rebound
        base (excludes primary itself as offset 0). Absolute ports are not
        included: they never move. */
    public var relativeOffsets: [Int] {
        guard let primary else { return [] }
        return relative.compactMap { port in
            let offset = port - primary
            return offset >= 0 ? offset : nil
        }.sorted()
    }

    /** Build a claim from a materialized-ready spec and its effective primary.
        `error` is a config-shaped message when span and named offsets collide. */
    public static func resolve(spec: ServerSpec, effectivePort: Int?) -> (
        claim: PortClaim?, error: String?
    ) {
        var relative: Set<Int> = []
        var absolute: Set<Int> = []
        var named: [String: Int] = [:]
        var injections: [String: Int] = [:]
        if let primary = effectivePort {
            relative.insert(primary)
            let envKey = spec.portEnv ?? PortMaterializer.portEnvironmentKey
            injections[envKey] = primary
        }
        if let span = spec.portSpan {
            /** Bounded above too: `0..<span` below is both the loop bound and an
                operand of `primary + offset`, so an unbounded span is an
                unbounded allocation and an overflow at the same time. */
            guard portRange.contains(span) else {
                return (nil, "portSpan must be 1...65535")
            }
            guard let primary = effectivePort else {
                return (nil, "portSpan requires a primary port")
            }
            for offset in 0..<span {
                relative.insert(primary + offset)
            }
        }
        var spanOffsets: Set<Int> = []
        if let span = spec.portSpan, span > 1 {
            spanOffsets = Set(1..<span)
        }
        for (name, secondary) in (spec.ports ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let error = secondary.validationError(name: name) {
                return (nil, error)
            }
            if let offset = secondary.offset {
                if spanOffsets.contains(offset) {
                    return (
                        nil,
                        "ports.\(name) offset \(offset) overlaps portSpan; pick one declaration")
                }
                guard let primary = effectivePort else {
                    return (nil, "ports.\(name): offset requires a primary port")
                }
                let resolved = primary + offset
                relative.insert(resolved)
                named[name] = resolved
                if let env = secondary.env {
                    injections[env] = resolved
                }
            } else if let port = secondary.port {
                absolute.insert(port)
                named[name] = port
                if let env = secondary.env {
                    injections[env] = port
                }
            }
        }
        return (
            PortClaim(
                absolute: absolute.sorted(),
                injections: injections,
                named: named,
                primary: effectivePort,
                relative: relative.sorted()),
            nil)
    }

    /** Config-time checks that do not need an effective (rebound) primary. */
    public static func configErrors(spec: ServerSpec) -> [String] {
        var errors: [String] = []
        /** The primary was unchecked while named secondaries were, so a value a
            TCP port cannot hold reached the socket layer, where narrowing it
            traps and takes the daemon down on every relaunch. Caught here, where
            `config check` reads it, rather than at the syscall. */
        let portInRange = spec.port.map { portRange.contains($0) } ?? true
        if !portInRange {
            errors.append("server '\(spec.name)': port must be 1...65535")
        }
        let spanInRange = spec.portSpan.map { portRange.contains($0) } ?? true
        if !spanInRange {
            errors.append("server '\(spec.name)': portSpan must be 1...65535")
        }
        /** Reached only once both operands are known to be in range. Every check
            here appends and falls through rather than returning, so computing
            the sum unconditionally trapped on a config holding Int.max: the
            exact crash the range check above exists to prevent, and a permanent
            one, since the daemon re-reads the same file on every relaunch. */
        if portInRange, spanInRange, let port = spec.port, let span = spec.portSpan,
            span > 1, port + span - 1 > 65_535
        {
            errors.append(
                "server '\(spec.name)': port \(port) with portSpan \(span) runs past 65535")
        }
        var spanOffsets: Set<Int> = []
        if spanInRange, let span = spec.portSpan, span > 1 {
            spanOffsets = Set(1..<span)
        }
        for (name, secondary) in spec.ports ?? [:] {
            if let error = secondary.validationError(name: name) {
                errors.append("server '\(spec.name)': \(error)")
            }
            if let offset = secondary.offset, spanOffsets.contains(offset) {
                errors.append(
                    "server '\(spec.name)': ports.\(name) offset \(offset) overlaps portSpan")
            }
        }
        return errors
    }
}

/** Where a linked worktree's server lands when the same server in another
    checkout of the repository already holds its declared ports. Pure: the
    caller gathers every port a live managed server holds and supplies the
    listen probe, so the whole search is testable without a socket. */
public enum SiblingRebind {
    /** How many candidates the search tries before giving up and handing back
        the next one, which then fails the ordinary port-held way. A bound
        rather than a budget: the search walks consecutive ports, so needing
        more than this many means the range is genuinely full and a wider
        search would only take longer to say so. */
    public static let attempts = 200

    /** The walk's bounds. The top stops short of the ephemeral range the
        kernel hands to outbound connections, which a listener cannot hold
        reliably; a walk past it wraps to the bottom, which stays clear of the
        low ports projects declare. A start below the bottom (a low declared
        port, `CheckoutIdentity.siblingPortCandidate`) walks up from where it
        is rather than jumping to the bottom. */
    public static let range = 10_000...65_000

    /** The first base port from `start` whose whole claim is disjoint from
        `reserved` and has no listener. `reserved` must hold every port a live
        managed server claims, not only the ones it listens on: a server
        declaring a span listens on its base alone until it needs the rest, and
        a block landing inside that span collides later. */
    public static func search(
        isListening: (Int) async -> Bool, reserved: Set<Int>, spec: ServerSpec, start: Int
    ) async -> Int {
        var candidate = start
        for _ in 0..<attempts {
            if let claim = PortClaim.resolve(spec: spec, effectivePort: candidate).claim,
                reserved.isDisjoint(with: claim.allPorts)
            {
                let busy = await anyListening(claim.allPorts, isListening: isListening)
                if !busy { return candidate }
            }
            candidate = candidate >= range.upperBound ? range.lowerBound : candidate + 1
        }
        return candidate
    }

    private static func anyListening(_ ports: [Int], isListening: (Int) async -> Bool) async -> Bool {
        for port in ports {
            let listening = await isListening(port)
            if listening { return true }
        }
        return false
    }
}
