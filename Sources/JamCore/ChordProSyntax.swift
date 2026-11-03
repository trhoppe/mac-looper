import Foundation

public enum ChordProSyntax {
    public enum Style: Equatable, Sendable { case chord, section, directive }
    public struct Span: Equatable, Sendable {
        public let range: NSRange
        public let style: Style
    }
    private static let chords = try! NSRegularExpression(pattern: #"\[[^\]\r\n]+\]"#)
    private static let tab = try! NSRegularExpression(pattern: #"^[A-Ga-g](?:#|b|♯|♭)?\|.*[-0-9xX]"#)
    /// Native text storage uses UTF-16 offsets, including when lyrics use emoji.
    public static func spans(in source: String) -> [Span] {
        var spans: [Span] = [], offset = 0, inTab = false
        for line in source.components(separatedBy: "\n") {
            let text = line as NSString, trim = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(location: 0, length: text.length)
            let full = NSRange(location: offset, length: text.length)
            defer { offset += text.length + 1 }
            let directive = ChordProDirective(line)
            if inTab {
                if directive?.isTabEnd == true {
                    inTab = false; spans.append(Span(range: full, style: .directive))
                }
                continue
            }
            if trim.hasPrefix("#") { continue }
            if let directive {
                if directive.isTabStart { inTab = true }
                spans.append(Span(range: full, style: .directive)); continue
            }
            if tab.firstMatch(in: line, range: range) != nil { continue }
            if trim.hasSuffix(":"), trim.count < 70, !trim.contains("[") {
                spans.append(Span(range: full, style: .section)); continue
            }
            for match in chords.matches(in: line, range: range) {
                var cursor = match.range.location, slashes = 0
                while cursor > 0 && text.character(at: cursor - 1) == 92 { slashes += 1; cursor -= 1 }
                guard slashes % 2 == 0 else { continue }
                spans.append(Span(range: NSRange(location: offset + match.range.location, length: match.range.length), style: .chord))
            }
        }
        return spans
    }
}
