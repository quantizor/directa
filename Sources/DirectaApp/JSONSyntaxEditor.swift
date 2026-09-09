import AppKit
import SwiftUI

/** Lightweight JSON syntax colors that track the system appearance. No third-party
    highlighter: the only config format is devservers.json. */
enum JSONSyntaxPalette {
    static var plain: NSColor { .labelColor }
    static var punctuation: NSColor { .secondaryLabelColor }
    static var key: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.55, green: 0.82, blue: 0.95, alpha: 1)
                : NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.62, alpha: 1)
        }
    }
    static var string: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.93, green: 0.62, blue: 0.48, alpha: 1)
                : NSColor(calibratedRed: 0.72, green: 0.22, blue: 0.14, alpha: 1)
        }
    }
    static var number: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.72, green: 0.72, blue: 0.98, alpha: 1)
                : NSColor(calibratedRed: 0.28, green: 0.28, blue: 0.72, alpha: 1)
        }
    }
    static var keyword: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.86, green: 0.58, blue: 0.92, alpha: 1)
                : NSColor(calibratedRed: 0.55, green: 0.18, blue: 0.62, alpha: 1)
        }
    }
}

/** Token kind for a JSON span. Pure so it can be unit-tested without AppKit. */
enum JSONTokenKind: Equatable, Sendable {
    case key
    case keyword
    case number
    case plain
    case punctuation
    case string
}

/** UTF-16 range + kind; NSTextView attributes consume these directly. */
struct JSONToken: Equatable, Sendable {
    let kind: JSONTokenKind
    let utf16Range: Range<Int>
}

/** Scan-once JSON tokenizer. Handles strings (with escapes), numbers, true /
    false / null, and punctuation. Invalid JSON still gets best-effort coloring
    so a mid-edit document stays readable. */
enum JSONTokenizer {
    static func tokenize(_ text: String) -> [JSONToken] {
        let utf16 = Array(text.utf16)
        var tokens: [JSONToken] = []
        var i = 0
        let n = utf16.count

        func isWhitespace(_ u: UInt16) -> Bool {
            u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D
        }

        while i < n {
            let c = utf16[i]
            if isWhitespace(c) {
                i += 1
                continue
            }

            /** String: key if a colon follows after optional whitespace. */
            if c == 0x22 { /** " */
                let start = i
                i += 1
                while i < n {
                    let ch = utf16[i]
                    if ch == 0x5C { /** \ */
                        i += 1
                        if i < n { i += 1 }
                        continue
                    }
                    if ch == 0x22 {
                        i += 1
                        break
                    }
                    i += 1
                }
                let end = i
                var j = end
                while j < n && isWhitespace(utf16[j]) { j += 1 }
                let kind: JSONTokenKind = (j < n && utf16[j] == 0x3A) ? .key : .string
                tokens.append(JSONToken(kind: kind, utf16Range: start..<end))
                continue
            }

            /** Number: optional minus, digits, optional fraction/exponent. */
            if c == 0x2D || (c >= 0x30 && c <= 0x39) { /** - or digit */
                let start = i
                var j = i
                if utf16[j] == 0x2D { j += 1 }
                if j < n && utf16[j] >= 0x30 && utf16[j] <= 0x39 {
                    while j < n && utf16[j] >= 0x30 && utf16[j] <= 0x39 { j += 1 }
                    if j < n && utf16[j] == 0x2E { /** . */
                        j += 1
                        while j < n && utf16[j] >= 0x30 && utf16[j] <= 0x39 { j += 1 }
                    }
                    if j < n && (utf16[j] == 0x65 || utf16[j] == 0x45) { /** e/E */
                        j += 1
                        if j < n && (utf16[j] == 0x2B || utf16[j] == 0x2D) { j += 1 }
                        while j < n && utf16[j] >= 0x30 && utf16[j] <= 0x39 { j += 1 }
                    }
                    tokens.append(JSONToken(kind: .number, utf16Range: start..<j))
                    i = j
                    continue
                }
            }

            /** Keywords: true / false / null */
            if let word = ["false", "null", "true"].first(where: {
                matchKeyword(utf16, at: i, word: $0)
            }) {
                let end = i + word.utf16.count
                tokens.append(JSONToken(kind: .keyword, utf16Range: i..<end))
                i = end
                continue
            }

            /** Punctuation: {}[]:, */
            if "{}[]:,".utf16.contains(c) {
                tokens.append(JSONToken(kind: .punctuation, utf16Range: i..<(i + 1)))
                i += 1
                continue
            }

            /** Unknown run until a delimiter. */
            let start = i
            i += 1
            while i < n {
                let ch = utf16[i]
                if isWhitespace(ch) || ch == 0x22 || "{}[]:,".utf16.contains(ch) { break }
                i += 1
            }
            tokens.append(JSONToken(kind: .plain, utf16Range: start..<i))
        }
        return tokens
    }

    private static func matchKeyword(_ utf16: [UInt16], at i: Int, word: String) -> Bool {
        let chars = Array(word.utf16)
        guard i + chars.count <= utf16.count else { return false }
        for (offset, expected) in chars.enumerated() {
            if utf16[i + offset] != expected { return false }
        }
        let end = i + chars.count
        if end < utf16.count {
            let next = utf16[end]
            /** Word boundary: not letter/digit/_ */
            if (next >= 0x41 && next <= 0x5A)
                || (next >= 0x61 && next <= 0x7A)
                || (next >= 0x30 && next <= 0x39)
                || next == 0x5F
            {
                return false
            }
        }
        return true
    }

    static func color(for kind: JSONTokenKind) -> NSColor {
        switch kind {
        case .key: JSONSyntaxPalette.key
        case .keyword: JSONSyntaxPalette.keyword
        case .number: JSONSyntaxPalette.number
        case .plain: JSONSyntaxPalette.plain
        case .punctuation: JSONSyntaxPalette.punctuation
        case .string: JSONSyntaxPalette.string
        }
    }
}

/** NSTextView-backed JSON editor with live syntax coloring. SwiftUI TextEditor
    cannot carry attributed runs, so this is the AppKit bridge. */
struct JSONSyntaxEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true

        let textView = NSTextView()
        textView.allowsUndo = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.insertionPointColor = .labelColor
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isHorizontallyResizable = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.textColor = .labelColor
        textView.usesFindBar = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        context.coordinator.applyHighlight(to: textView)

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
            context.coordinator.applyHighlight(to: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        private var isApplyingHighlight = false

        init(text: Binding<String>) {
            self.text = text
            super.init()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingHighlight,
                let textView = notification.object as? NSTextView
            else { return }
            text.wrappedValue = textView.string
            applyHighlight(to: textView)
        }

        func applyHighlight(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            isApplyingHighlight = true
            defer { isApplyingHighlight = false }

            let full = NSRange(location: 0, length: storage.length)
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            storage.beginEditing()
            storage.setAttributes(
                [
                    .font: font,
                    .foregroundColor: JSONSyntaxPalette.plain,
                ], range: full)

            let string = storage.string
            for token in JSONTokenizer.tokenize(string) {
                let range = NSRange(
                    location: token.utf16Range.lowerBound,
                    length: token.utf16Range.count)
                guard range.location + range.length <= storage.length else { continue }
                storage.addAttributes(
                    [
                        .font: font,
                        .foregroundColor: JSONTokenizer.color(for: token.kind),
                    ], range: range)
            }
            storage.endEditing()
        }
    }
}
