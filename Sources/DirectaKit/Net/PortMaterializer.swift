import Foundation

/** Materializes an effective port (and optional host) into a ServerSpec for spawn
    and status: injects PORT / portEnv, substitutes `{port}` / `{host}` tokens, and
    rewrites derived url / heads / healthcheck URLs. Pure; unit-tested. */
public enum PortMaterializer {
    /** The variable a spawned server reads its effective host from, injected
        beside its port. */
    public static let hostEnvironmentKey = "DIRECTA_HOST"

    /** The variable a spawned server reads its effective port from when its
        spec names no `portEnv`. */
    public static let portEnvironmentKey = "PORT"

    /** Apply `effectivePort` (and optional `effectiveHost`) to a committed/ad-hoc
        spec. `declaredPort` on status remains the pre-materialization `spec.port`.
        `matchHost` gates URL host replacement to URLs already printed with that
        host; when omitted, `spec.host` gates it. A head like
        `admin.app.localhost` keeps its subdomain when only the port moves. */
    public static func materialize(
        spec: ServerSpec, effectivePort: Int?, effectiveHost: String? = nil,
        matchHost: String? = nil
    ) -> ServerSpec {
        var next = spec
        let host = effectiveHost ?? spec.host
        if let host { next.host = host }
        let resolved = PortClaim.resolve(spec: spec, effectivePort: effectivePort)
        let claim =
            resolved.claim
            ?? PortClaim(primary: effectivePort, relative: effectivePort.map { [$0] } ?? [])
        if let effectivePort {
            next.port = effectivePort
        }
        if !claim.injections.isEmpty {
            var env = next.env ?? [:]
            for (key, value) in claim.injections {
                env[key] = String(value)
            }
            if let host {
                env[hostEnvironmentKey] = host
            }
            next.env = env
        } else if let effectivePort {
            let envKey = spec.portEnv ?? portEnvironmentKey
            var env = next.env ?? [:]
            env[envKey] = String(effectivePort)
            if let host {
                env[hostEnvironmentKey] = host
            }
            next.env = env
        }
        let portText = effectivePort.map(String.init)
        let hostText = host
        let previousHost = matchHost ?? spec.host
        next.command = next.command.map { substitute($0, port: portText, host: hostText) }
        if let url = next.url {
            next.url = rewriteURL(url, port: effectivePort, host: host, matchHost: previousHost)
                ?? substitute(url, port: portText, host: hostText)
        } else if let effectivePort, let host {
            next.url = "http://\(host):\(effectivePort)/"
        }
        if let heads = next.heads {
            var rewritten: [String: String] = [:]
            for (name, url) in heads {
                rewritten[name] =
                    rewriteURL(url, port: effectivePort, host: host, matchHost: previousHost)
                    ?? resolveRelative(
                        substitute(url, port: portText, host: hostText), base: next.url)
                    ?? substitute(url, port: portText, host: hostText)
            }
            next.heads = rewritten
        }
        if var health = next.healthcheck {
            if let healthURL = health.url {
                health.url =
                    rewriteURL(healthURL, port: effectivePort, host: host, matchHost: previousHost)
                    ?? resolveRelative(
                        substitute(healthURL, port: portText, host: hostText), base: next.url)
                    ?? substitute(healthURL, port: portText, host: hostText)
            }
            if let effectivePort, health.port != nil {
                health.port = effectivePort
            }
            next.healthcheck = health
        }
        return next
    }

    /** Replace `{port}` / `{host}` tokens in a single string. */
    public static func substitute(_ text: String, port: String?, host: String?) -> String {
        var out = text
        if let port {
            out = out.replacingOccurrences(of: "{port}", with: port)
        }
        if let host {
            out = out.replacingOccurrences(of: "{host}", with: host)
        }
        return out
    }

    /** Resolve a root-relative value (`/admin`) against the server's own base URL,
        which is the only reading that survives a rebind moving the port.
        Nil when the value is not root-relative or there is no base to resolve
        against, so the caller falls through to token substitution. */
    public static func resolveRelative(_ raw: String, base: String?) -> String? {
        guard raw.hasPrefix("/"), let base, let baseURL = URL(string: base),
            let resolved = URL(string: raw, relativeTo: baseURL)
        else { return nil }
        return resolved.absoluteString
    }

    /** Prefer structured URL rewrite so an explicit committed URL follows the
        effective port/host without requiring `{port}` tokens. Host is only
        replaced when the URL's host exactly matches `matchHost` (so a head like
        `admin.app.localhost` keeps its subdomain when only the port moves). */
    public static func rewriteURL(
        _ raw: String, port: Int?, host: String?, matchHost: String? = nil
    ) -> String? {
        /** A hostless component set (a bare path like `/admin`) must not be
            rewritten: stamping a port onto it forces an empty authority and
            serializes as `//:3000/admin`, a non-nil value that reads as success
            and reaches every heads consumer. Declining here hands the caller its
            relative-resolution and substitution fallbacks. */
        guard var components = URLComponents(string: raw), components.host != nil else {
            return nil
        }
        if let host {
            if let matchHost {
                if components.host == matchHost {
                    components.host = host
                }
            } else {
                components.host = host
            }
        }
        if let port { components.port = port }
        return components.string
    }
}
