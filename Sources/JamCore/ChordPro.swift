import Foundation

public struct ChordFragment: Equatable, Sendable {
    public let chord: String
    public let lyric: String
    public init(chord: String = "", lyric: String) { self.chord = chord; self.lyric = lyric }
    public var displayColumns: Int {
        max(lyric.count, chord.count + (!chord.isEmpty && lyric.trimmingCharacters(in: .whitespaces).isEmpty ? 1 : 0))
    }
}
public struct ChartLine: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case lyrics, section, comment, tablature, blank }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let fragments: [ChordFragment]
}
public struct ChartBlock: Identifiable, Equatable, Sendable {
    public let lines: [ChartLine]
    public var id: Int { lines[0].id }
    public var isTablature: Bool { lines[0].kind == .tablature }
}
public struct ChordProDocument: Sendable {
    public let lines: [ChartLine]
    public let metadata: [String: String]
    public let unsupportedDirectives: [String]
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
    private static func isPlainTab(_ text: String) -> Bool {
        guard let bar = text.firstIndex(of: "|") else { return false }
        let label = text[..<bar].trimmingCharacters(in: .whitespaces)
        guard let root = label.first, "ABCDEFGabcdefg".contains(root), label.count <= 2,
              label.count == 1 || ["#", "b", "♯", "♭"].contains(label.last!) else { return false }
        return text[bar...].contains { $0 == "-" || $0 == "x" || $0 == "X" || $0.isNumber }
    }
    public init(source: String, transpose: Int = 0, flats: Bool = false) {
        var result: [ChartLine] = [], metadata: [String: String] = [:], unsupported = Set<String>()
        var inTab = false
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.components(separatedBy: "\n") {
            let trim = raw.trimmingCharacters(in: .whitespaces)
            if trim.hasPrefix("#") { continue }
            func add(_ kind: ChartLine.Kind, text: String = raw, fragments: [ChordFragment] = []) {
                result.append(ChartLine(id: result.count, kind: kind, text: text, fragments: fragments))
            }
            if trim.hasPrefix("{"), trim.hasSuffix("}") {
                let content = String(trim.dropFirst().dropLast())
                let parts = content.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                switch name {
                case "title","t","subtitle","st","artist","key","capo","tempo","time": metadata[name == "t" ? "title" : name == "st" ? "subtitle" : name] = value
                case "start_of_tab","sot": inTab = true
                case "end_of_tab","eot": inTab = false
                case "start_of_chorus","soc": add(.section, text: value.isEmpty ? "Chorus" : value)
                case "start_of_verse","sov": add(.section, text: value.isEmpty ? "Verse" : value)
                case "start_of_bridge","sob": add(.section, text: value.isEmpty ? "Bridge" : value)
                case "end_of_chorus","eoc","end_of_verse","eov","end_of_bridge","eob": add(.blank, text: "")
                case "comment","c","comment_italic","ci","comment_box","cb": add(.comment, text: value)
                default: unsupported.insert(name)
                }
            } else if trim.isEmpty { add(.blank) }
            else if inTab || Self.isPlainTab(trim) { add(.tablature) }
            else if trim.hasSuffix(":"), trim.count < 70, !trim.contains("[") { add(.section, text: String(trim.dropLast())) }
            else {
                let fragments = Self.fragments(raw).map { ChordFragment(chord: ChordTransposition.transpose($0.chord, semitones: transpose, flats: flats), lyric: $0.lyric) }
                add(.lyrics, fragments: fragments)
            }
        }
        self.lines = result; self.metadata = metadata; self.unsupportedDirectives = unsupported.sorted()
    }
    public static func fragments(_ line: String) -> [ChordFragment] {
        let chars = Array(line)
        var i = 0, chord = "", lyric = "", output: [ChordFragment] = []
        func flush() { if !chord.isEmpty || !lyric.isEmpty { output.append(ChordFragment(chord: chord, lyric: lyric)) }; chord = ""; lyric = "" }
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, ["[","]","\\"].contains(chars[i + 1]) {
                lyric.append(chars[i + 1]); i += 2; continue
            }
            if chars[i] == "[", let end = chars[(i + 1)...].firstIndex(of: "]") {
                flush(); chord = String(chars[(i + 1)..<end]); i = end + 1
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
                if ch.isWhitespace { result.append(ChordFragment(chord: first ? fragment.chord : "", lyric: word)); word = ""; first = false }
            }
            if !word.isEmpty || result.isEmpty { result.append(ChordFragment(chord: first ? fragment.chord : "", lyric: word)) }
            return result
        }
    }
}
