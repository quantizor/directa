import Foundation

/** Structured log stream tags. `sys` carries lifecycle events (start/exit/
    rotation/drops); `mark` carries agent correlation markers. */
public enum LogStream: String, CaseIterable, Codable, Sendable {
    case err
    case mark
    case out
    case sys
}

/** Fixed `sys` payloads a reader matches exactly, shared by the writer and
    every reader so the two can never drift apart. */
public enum SysLineText {
    /** The first line of a fresh file after the log store rotates. */
    public static let rotated = "rotated"
}

/** One structured log line: `ISO8601\t<stream>\t<payload>`. The payload may
    contain tabs (parsers split on the first two only); it never contains raw
    newlines (line-split upstream). */
public struct LogRecord: Codable, Equatable, Sendable {
    public var at: Date
    public var stream: LogStream
    public var text: String

    public init(at: Date, stream: LogStream, text: String) {
        self.at = at
        self.stream = stream
        self.text = text
    }

    public func formatted() -> String {
        "\(JSONCoding.formatISO8601(at))\t\(stream.rawValue)\t\(text)"
    }

    /** Stream-tagged payload for a human or an agent reading a tail: the one
        spelling behind `directa why` evidence and `recentLogTail`. */
    public var contextLine: String {
        "\(stream.rawValue): \(text)"
    }
}

/** Payload sanitization for child output: lossy UTF-8 is applied upstream (the
    tailer decodes bytes), this strips what must never reach a terminal or an
    agent context: ANSI/OSC escape sequences (a terminal-injection surface), NULs,
    and carriage-return spinner rewrites (keep only the final rewrite). */
public enum LogSanitizer {
    public static func sanitize(_ raw: String) -> String {
        /** Nearly every line carries none of the three bytes the passes below
            act on, and one scan for them is far cheaper than the passes. */
        guard raw.utf8.contains(where: { $0 == 0x00 || $0 == 0x0D || $0 == 0x1B }) else { return raw }
        var text = raw
        /** Spinner rewrites: everything before the last CR is overdrawn output. */
        if let lastCR = text.lastIndex(of: "\r") {
            text = String(text[text.index(after: lastCR)...])
        }
        text = text.replacing("\u{0}", with: "")
        text = stripEscapes(text)
        return text
    }

    /** Removes CSI (ESC [ ... final-byte) and OSC (ESC ] ... BEL/ST) sequences
        plus stray lone escapes. */
    static func stripEscapes(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars[...]
        while let scalar = scalars.first {
            scalars.removeFirst()
            guard scalar.value == 0x1B else {
                result.append(scalar)
                continue
            }
            guard let kind = scalars.first else { break }
            if kind == "[" {
                scalars.removeFirst()
                /** CSI: parameter bytes 0x30-0x3F, intermediates 0x20-0x2F, one
                    final byte 0x40-0x7E. */
                while let b = scalars.first, (0x20...0x3F).contains(b.value) {
                    scalars.removeFirst()
                }
                if let final = scalars.first, (0x40...0x7E).contains(final.value) {
                    scalars.removeFirst()
                }
            } else if kind == "]" {
                scalars.removeFirst()
                /** OSC: runs to BEL or ESC-backslash. */
                while let b = scalars.first {
                    scalars.removeFirst()
                    if b.value == 0x07 { break }
                    if b.value == 0x1B, scalars.first == "\\" {
                        scalars.removeFirst()
                        break
                    }
                }
            } else {
                /** Two-byte escape (ESC c etc.): drop the pair. */
                scalars.removeFirst()
            }
        }
        return String(result)
    }

    /** `text` cut to at most `limit` characters, the last being `…` when
        anything was cut; unchanged when it fits or `limit` is below 1. */
    public static func truncated(_ text: String, toCharacters limit: Int) -> String {
        guard limit >= 1, let cut = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex),
            cut < text.endIndex
        else { return text }
        return String(text[..<text.index(before: cut)]) + "…"
    }
}
