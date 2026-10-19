import Foundation

/** Matching for the menu bar popover's filter. Every range comes back as an
    index into the text that was searched, so the view can mark the match in
    place. Positions are never mapped through a lowercased copy, because some
    characters change length when lowercased. */
public enum FuzzyMatch {
    /** Nil when the query does not match. A blank query matches with no ranges.
        A query that appears as a case-insensitive substring marks that one run.
        Otherwise each query character marks the next matching character in
        order (a subsequence match). */
    public static func ranges(in text: String, query: String) -> [Range<String.Index>]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if let whole = text.range(of: trimmed, options: .caseInsensitive) {
            return [whole]
        }
        var ranges: [Range<String.Index>] = []
        var queryIndex = trimmed.startIndex
        var textIndex = text.startIndex
        while textIndex < text.endIndex, queryIndex < trimmed.endIndex {
            let next = text.index(after: textIndex)
            let textCharacter = String(text[textIndex])
            let queryCharacter = String(trimmed[queryIndex])
            if textCharacter.compare(queryCharacter, options: .caseInsensitive) == .orderedSame {
                ranges.append(textIndex..<next)
                queryIndex = trimmed.index(after: queryIndex)
            }
            textIndex = next
        }
        return queryIndex == trimmed.endIndex ? ranges : nil
    }
}

/** The words a popover row shows, derived from a server's URL and port. The
    filter matches against these same strings, so a query can only mark text
    a reader sees. */
public enum PopoverLabel {
    /** The line a server row leads with: the URL's host and port, else the
        port the server is on, else the server's name. */
    public static func address(url: String?, displayPort: Int?, server: String) -> String {
        if let url, let parsed = URL(string: url), let host = parsed.host {
            let port = parsed.port.map { ":\($0)" } ?? ""
            return "\(host)\(port)"
        }
        if let displayPort {
            return "port \(displayPort)"
        }
        return server
    }

    /** The host-and-path a head row shows after its name. A head on the same
        host and port as its server shows only its path, and empty when it has
        none. A URL that does not parse shows as written. */
    public static func headHost(url: String, parentURL: String?) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else { return url }
        let headHostPort = parsed.port.map { "\(host):\($0)" } ?? host
        let headPath = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if let parentURL, let parentParsed = URL(string: parentURL), let parentHost = parentParsed.host {
            let parentHostPort = parentParsed.port.map { "\(parentHost):\($0)" } ?? parentHost
            if headHostPort == parentHostPort {
                return headPath.isEmpty ? "" : "/\(headPath)"
            }
        }
        return headPath.isEmpty ? headHostPort : "\(headHostPort)/\(headPath)"
    }
}
