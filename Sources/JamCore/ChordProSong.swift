import Foundation

/// Song-level metadata lives in the ChordPro preamble. Later key/tempo changes
/// remain part of the musical body rather than replacing the song's initial key.
public struct ChordProSongSource: Equatable, Sendable {
    public static let names = ["title", "artist", "key", "tempo", "time", "duration", "capo"]
    public let source: String
    public let values: [String: [String]]
    public let body: String
    public init(_ source: String) {
        self.source = source
        var values: [String: [String]] = [:], body: [String] = [], preamble = true
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for line in lines {
            let trim = line.trimmingCharacters(in: .whitespaces)
            let d = ChordProDirective(line)
            if preamble, let item = Self.metadata(d), Self.names.contains(item.0) {
                values[item.0, default: []].append(item.1); continue
            }
            if !trim.isEmpty && !trim.hasPrefix("#") {
                if let d {
                    if d.name.hasPrefix("start_of_") || ["sov", "soc", "sob", "sot", "sog", "comment", "c", "ci", "cb", "comment_italic", "comment_box", "highlight", "chorus"].contains(d.name) { preamble = false }
                } else { preamble = false }
            }
            body.append(line)
        }
        self.values = values; self.body = body.joined(separator: "\n")
    }
    private static func metadata(_ d: ChordProDirective?) -> (String, String)? {
        guard let d else { return nil }
        if d.name == "meta" {
            let parts = d.value.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let name = parts.first else { return nil }
            return (String(name).lowercased(), parts.count > 1 ? String(parts[1]) : "")
        }
        return (d.name == "t" ? "title" : d.name, d.value)
    }
    public func first(_ name: String) -> String? { values[name]?.first }
    public func setting(_ name: String, to value: String) -> String {
        var updated = values
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { updated.removeValue(forKey: name) } else { updated[name] = [value] }
        return Self.render(updated, body: body)
    }
    public static func render(_ values: [String: [String]], body: String) -> String {
        let header = names.flatMap { name in (values[name] ?? []).map { "{\(name): \($0)}" } }.joined(separator: "\n")
        return header.isEmpty ? body : header + "\n" + body
    }
    /// Independent metadata edits merge by directive. Conflicting body edits
    /// keep the draft instead of replacing another device's chart changes.
    public static func merging(base: String, edited: String, latest: String) throws -> String {
        if edited == base { return latest }
        if latest == base || latest == edited { return edited }
        let a = Self(base), b = Self(edited), c = Self(latest)
        var merged = c.values
        for name in names where a.values[name] != b.values[name] {
            guard c.values[name] == a.values[name] || c.values[name] == b.values[name] else { throw SongEditError.conflict }
            merged[name] = b.values[name]
        }
        let changedBody = a.body != b.body
        if changedBody && c.body != a.body && c.body != b.body { throw SongEditError.conflict }
        return render(merged, body: changedBody ? b.body : c.body)
    }
    /// Existing directives win; only missing preamble metadata is backfilled.
    public static func seeded(from song: LibrarySong) -> String {
        let existing = Self(song.chordPro)
        var values = existing.values
        let legacy: [String: String?] = [
            "title": song.fields["title"]?.text ?? "Untitled", "artist": song.fields["artist"]?.text,
            "key": song.legacyKey, "tempo": song.fields["tempo"]?.text,
            "time": song.fields["timeSignature"]?.text, "duration": song.fields["duration"]?.text,
            "capo": song.fields["capo"]?.text
        ]
        for name in names where values[name] == nil {
            if let value = legacy[name] ?? nil, !value.isEmpty {
                values[name] = [value.components(separatedBy: .newlines).joined(separator: " ")]
            }
        }
        return render(values, body: existing.body)
    }
    /// Convert old plain-heading/tab conventions without altering their content.
    public static func standardizingLegacyBody(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var output: [String] = [], section: String?, tab = false, explicitTab = false, explicitSections = 0
        for (index, line) in lines.enumerated() {
            let trim = line.trimmingCharacters(in: .whitespaces)
            let d = ChordProDirective(line)
            if explicitTab {
                output.append(line)
                if d?.isTabEnd == true { explicitTab = false }
                continue
            }
            let tabRow = ChordProDocument.isPlainTab(trim)
            if tab && !tabRow {
                let next = lines.dropFirst(index + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if !trim.isEmpty || !ChordProDocument.isPlainTab(next?.trimmingCharacters(in: .whitespaces) ?? "") {
                    output.append("{end_of_tab}"); tab = false
                }
            }
            if d?.isTabStart == true { explicitTab = true; output.append(line); continue }
            if let d {
                if ["start_of_verse", "sov", "start_of_chorus", "soc", "start_of_bridge", "sob"].contains(d.name) {
                    if let active = section { output.append("{end_of_\(active)}"); section = nil }
                    explicitSections += 1
                }
                if ["end_of_verse", "eov", "end_of_chorus", "eoc", "end_of_bridge", "eob"].contains(d.name) { explicitSections = max(0, explicitSections - 1) }
                output.append(line); continue
            }
            if tabRow {
                if !tab { output.append("{start_of_tab}"); tab = true }
                output.append(line); continue
            }
            if explicitSections == 0, !trim.hasPrefix("#"), trim.hasSuffix(":"), trim.count < 70, !trim.contains("[") {
                if let section { output.append("{end_of_\(section)}") }
                let label = String(trim.dropLast()).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let lower = label.lowercased()
                section = lower.hasPrefix("chorus") ? "chorus" : lower.hasPrefix("bridge") ? "bridge" : "verse"
                output.append("{start_of_\(section!): label=\"\(label)\"}")
            } else { output.append(line) }
        }
        if tab { output.append("{end_of_tab}") }
        if let section { output.append("{end_of_\(section)}") }
        return output.joined(separator: "\n")
    }
}
