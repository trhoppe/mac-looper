import Foundation

/// A directive occupies a source line. Arguments may follow a colon or whitespace.
/// Kept shared with the editor so its tab highlighting follows the viewer's rules.
struct ChordProDirective {
    let name: String
    let value: String
    init?(_ line: String) {
        let trim = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trim.hasPrefix("{"), trim.hasSuffix("}") else { return nil }
        let content = trim.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        let boundary = content.firstIndex { $0 == ":" || $0.isWhitespace } ?? content.endIndex
        guard boundary != content.startIndex else { return nil }
        name = String(content[..<boundary]).lowercased()
        var argument = content[boundary...].drop(while: { $0.isWhitespace })
        if argument.first == ":" { argument = argument.dropFirst() }
        value = argument.trimmingCharacters(in: .whitespaces)
    }
    private static let labelPattern = try! NSRegularExpression(pattern: #"(?:^|\s)label\s*=\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|([^\s]+))"#)
    var label: String {
        let ns = value as NSString
        guard let match = Self.labelPattern.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { return value }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            let chars = Array(ns.substring(with: match.range(at: group)))
            var decoded = "", i = 0
            while i < chars.count {
                if chars[i] == "\\", i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "n" { decoded.append("\n"); i += 2; continue }
                    if ["\\", "\"", "'"].contains(next) { decoded.append(next); i += 2; continue }
                }
                decoded.append(chars[i]); i += 1
            }
            return decoded
        }
        return ""
    }
    var isTabStart: Bool { ["start_of_tab", "sot"].contains(name) }
    var isTabEnd: Bool { ["end_of_tab", "eot"].contains(name) }
}

public struct ChordFragment: Equatable, Sendable {
    public let chord: String
    public let lyric: String
    public let isAnnotation: Bool
    public init(chord: String = "", lyric: String, isAnnotation: Bool = false) {
        self.chord = chord; self.lyric = lyric; self.isAnnotation = isAnnotation
    }
    public var displayColumns: Int {
        max(lyric.count, chord.count + (!chord.isEmpty && lyric.trimmingCharacters(in: .whitespaces).isEmpty ? 1 : 0))
    }
}
public struct ChartLine: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case lyrics, section, comment, tablature, blank }
    public enum CommentStyle: Equatable, Sendable { case plain, italic, box }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let fragments: [ChordFragment]
    public var commentStyle: CommentStyle = .plain
}
public struct ChartBlock: Identifiable, Equatable, Sendable {
    public let lines: [ChartLine]
    public var id: Int { lines[0].id }
    public var isTablature: Bool { lines[0].kind == .tablature }
}
public struct ChordProDocument: Sendable {
    public let lines: [ChartLine]
    /// Last value, retained for existing clients. metadataValues preserves repeats.
    public let metadata: [String: String]
    public let metadataValues: [String: [String]]
    public let unsupportedDirectives: [String]
    public let warnings: [String]
    public var blocks: [ChartBlock] {
        var result: [ChartBlock] = [], tab: [ChartLine] = []
        for line in lines {
            if line.kind == .tablature { tab.append(line); continue }
            if !tab.isEmpty { result.append(ChartBlock(lines: tab)); tab = [] }
            result.append(ChartBlock(lines: [line]))
        }
        if !tab.isEmpty { result.append(ChartBlock(lines: tab)) }
        return result
    }
    private static let markupPattern = try! NSRegularExpression(pattern: #"</?(?:span|b|big|i|s|sub|sup|small|tt|u|strut|sym)(?:\s|/?>)"#)
    private static let metadataNames: Set<String> = [
        "title", "sorttitle", "subtitle", "artist", "sortartist", "composer", "lyricist", "arranger",
        "copyright", "album", "year", "key", "capo", "tempo", "time", "duration", "tag"
    ]
    static func isPlainTab(_ text: String) -> Bool {
        guard let bar = text.firstIndex(of: "|") else { return false }
        let label = text[..<bar].trimmingCharacters(in: .whitespaces)
        guard let root = label.first, "ABCDEFGabcdefg".contains(root), label.count <= 2,
              label.count == 1 || ["#", "b", "♯", "♭"].contains(label.last!) else { return false }
        return text[bar...].contains { $0 == "-" || $0 == "x" || $0 == "X" || $0.isNumber }
    }
    public init(source: String, transpose: Int = 0, flats: Bool = false) {
        var result: [ChartLine] = [], metadataValues: [String: [String]] = [:], unsupported = Set<String>(), warnings: [String] = []
        var inTab = false, chorusStart: Int?, lastChorus: [ChartLine] = []
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.components(separatedBy: "\n") {
            let trim = raw.trimmingCharacters(in: .whitespaces)
            let directive = ChordProDirective(raw)
            func add(_ kind: ChartLine.Kind, text: String = raw, fragments: [ChordFragment] = [], style: ChartLine.CommentStyle = .plain) {
                result.append(ChartLine(id: result.count, kind: kind, text: text, fragments: fragments, commentStyle: style))
            }
            // In a tab EVERYTHING is literal, including comments, brackets, blank
            // lines and directive-looking text, except the tab's closing directive.
            if inTab {
                if directive?.isTabEnd == true { inTab = false }
                else { add(.tablature) }
                continue
            }
            if trim.hasPrefix("#") { continue }
            if Self.markupPattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil,
               !warnings.contains("Inline markup is shown as source text; styling is not rendered.") {
                warnings.append("Inline markup is shown as source text; styling is not rendered.")
            }
            if raw.contains("%{"), !warnings.contains("Metadata substitutions are shown as source text; values are not expanded.") {
                warnings.append("Metadata substitutions are shown as source text; values are not expanded.")
            }
            if let d = directive {
                let name = d.name == "t" ? "title" : d.name == "st" ? "subtitle" : d.name
                func recordMetadata(_ name: String, _ value: String) {
                    metadataValues[name, default: []].append(value)
                    if result.contains(where: { $0.kind == .lyrics || $0.kind == .section }), ["key", "tempo", "time", "capo"].contains(name) {
                        let label = name == "tempo" ? "Tempo \(value) BPM" : name == "time" ? "Time \(value)" : name == "capo" ? "Capo \(value)" : "Key \(ChordTransposition.transpose(value, semitones: transpose, flats: flats))"
                        add(.comment, text: label)
                    }
                }
                if Self.metadataNames.contains(name) { recordMetadata(name, d.value); continue }
                switch name {
                case "meta":
                    let parts = d.value.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                    if let key = parts.first, !key.isEmpty {
                        recordMetadata(String(key).lowercased(), parts.count > 1 ? String(parts[1]) : "")
                    } else { warnings.append("A meta directive is missing its name.") }
                case "start_of_tab", "sot":
                    if !d.label.isEmpty { add(.section, text: d.label) }
                    inTab = true
                case "end_of_tab", "eot": warnings.append("A tab ends without a matching start.")
                case "start_of_chorus", "soc":
                    chorusStart = result.count
                    add(.section, text: d.label.isEmpty ? "Chorus" : d.label)
                case "start_of_verse", "sov": add(.section, text: d.label.isEmpty ? "Verse" : d.label)
                case "start_of_bridge", "sob": add(.section, text: d.label.isEmpty ? "Bridge" : d.label)
                case "end_of_chorus", "eoc":
                    if let start = chorusStart { lastChorus = Array(result[start...]); chorusStart = nil }
                    else { warnings.append("A chorus ends without a matching start.") }
                case "end_of_verse", "eov", "end_of_bridge", "eob": break
                case "chorus":
                    if lastChorus.isEmpty { warnings.append("A chorus is recalled before one has been defined.") }
                    else {
                        for (index, line) in lastChorus.enumerated() {
                            add(line.kind, text: index == 0 && !d.label.isEmpty ? d.label : line.text,
                                fragments: line.fragments, style: line.commentStyle)
                        }
                        add(.blank, text: "")
                    }
                case "comment", "c", "highlight": add(.comment, text: d.value)
                case "comment_italic", "ci": add(.comment, text: d.value, style: .italic)
                case "comment_box", "cb": add(.comment, text: d.value, style: .box)
                default:
                    // ChordPro reserves x_ for application extensions. Other
                    // unsupported directives are reported, never claimed rendered.
                    if !name.hasPrefix("x_") { unsupported.insert(name) }
                }
            } else if trim.isEmpty { add(.blank) }
            else if Self.isPlainTab(trim) { add(.tablature) }
            else if trim.hasSuffix(":"), trim.count < 70, !trim.contains("[") { add(.section, text: String(trim.dropLast())) }
            else {
                let fragments = Self.fragments(raw).map {
                    ChordFragment(chord: $0.isAnnotation ? $0.chord : ChordTransposition.transpose($0.chord, semitones: transpose, flats: flats),
                                  lyric: $0.lyric, isAnnotation: $0.isAnnotation)
                }
                add(.lyrics, fragments: fragments)
            }
        }
        if inTab { warnings.append("A tab is missing its end_of_tab directive.") }
        if chorusStart != nil { warnings.append("A chorus is missing its end_of_chorus directive.") }
        self.lines = result; self.metadataValues = metadataValues
        self.metadata = metadataValues.compactMapValues(\.last)
        self.unsupportedDirectives = unsupported.sorted(); self.warnings = warnings
    }
    /// ChordPro permits seconds as well as a readable time specification.
    public static func readableDuration(_ value: String) -> String {
        if let seconds = Int(value), seconds >= 0 { return "\(seconds / 60):" + String(format: "%02d", seconds % 60) }
        return value
    }
    public static func fragments(_ line: String) -> [ChordFragment] {
        let chars = Array(line)
        var i = 0, chord = "", lyric = "", annotation = false, output: [ChordFragment] = []
        func flush() {
            if !chord.isEmpty || !lyric.isEmpty { output.append(ChordFragment(chord: chord, lyric: lyric, isAnnotation: annotation)) }
            chord = ""; lyric = ""; annotation = false
        }
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, ["[", "]", "\\"].contains(chars[i + 1]) {
                lyric.append(chars[i + 1]); i += 2; continue
            }
            if chars[i] == "[", let end = chars[(i + 1)...].firstIndex(of: "]") {
                flush(); chord = String(chars[(i + 1)..<end]); annotation = chord.hasPrefix("*")
                if annotation { chord.removeFirst() }
                i = end + 1
            } else { lyric.append(chars[i]); i += 1 }
        }
        flush()
        return output.isEmpty ? [ChordFragment(lyric: line)] : output
    }
    public static func words(_ fragments: [ChordFragment]) -> [ChordFragment] {
        fragments.flatMap { fragment -> [ChordFragment] in
            var result: [ChordFragment] = [], word = "", first = true
            for ch in fragment.lyric {
                word.append(ch)
                if ch.isWhitespace {
                    result.append(ChordFragment(chord: first ? fragment.chord : "", lyric: word, isAnnotation: first && fragment.isAnnotation))
                    word = ""; first = false
                }
            }
            if !word.isEmpty || result.isEmpty {
                result.append(ChordFragment(chord: first ? fragment.chord : "", lyric: word, isAnnotation: first && fragment.isAnnotation))
            }
            return result
        }
    }
}
