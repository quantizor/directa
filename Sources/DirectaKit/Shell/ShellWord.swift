import Foundation

/** The one home for putting a value into a command an agent or a person
    will paste into a shell. A server name comes from committed config and a
    path from the filesystem, so either can carry `;`, a quote, a space, or
    `$(...)`; a hint that interpolates one raw is a command injection waiting
    for someone to run it. */
public enum ShellWord {
    /** Long enough for any real server name, short enough that a pasted
        name never dominates the line it sits in. */
    public static let inertLengthLimit = 64

    /** True when `word` is safe to paste bare: non-empty, at most
        `inertLengthLimit` characters, and only ASCII letters, digits, `-`,
        `_`, and `.`. Nothing in that alphabet means anything to a POSIX
        shell, so the word reaches the command exactly as written. */
    public static func isInert(_ word: String) -> Bool {
        word.count <= inertLengthLimit && isPlain(word, allowingSlash: false)
    }

    /** `word` when it is inert, else `<name>`: for a hint that names a
        server, where a placeholder the reader fills in from the server list
        is safer than any quoting of a hostile name. */
    public static func inertOr(_ word: String) -> String {
        isInert(word) ? word : "<name>"
    }

    /** One argument of a literal hint command: bare when every character is
        an ASCII letter, digit, `-`, `_`, `.`, or `/` (a plain name or path
        reads as the person would type it), else single-quoted. */
    public static func argument(_ word: String) -> String {
        isPlain(word, allowingSlash: true) ? word : singleQuoted(word)
    }

    /** `word` in POSIX single quotes, each embedded `'` written as `'\''`:
        inside single quotes a shell expands nothing, so any path round-trips
        as one argument. */
    public static func singleQuoted(_ word: String) -> String {
        "'" + word.replacing("'", with: "'\\''") + "'"
    }

    private static func isPlain(_ word: String, allowingSlash: Bool) -> Bool {
        !word.isEmpty
            && word.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                    || $0 == "-" || $0 == "_" || $0 == "." || (allowingSlash && $0 == "/")
            }
    }
}
