import SwiftUI
import JamCore

// Persist typography outside the equatable chart: it must be an explicit input
// to equality and to every layout cache, rather than waiting for a song change.
struct ChordChartView: View {
    let song: LibrarySong?
    let edit: () -> Void
    @AppStorage("chartFontSize") private var fontSize = 21.0
    @AppStorage("chartTwoColumns") private var twoColumns = true
    private let document: ChordProDocument?
    init(song: LibrarySong?, edit: @escaping () -> Void = {}) {
        self.song = song; self.edit = edit
        document = song.map { ChordProDocument(source: $0.chordPro, transpose: $0.transposition, flats: $0.displayKey?.contains("b") == true) }
    }
    var body: some View {
        ChartPresentation(song: song, document: document, fontSize: fontSize, twoColumns: twoColumns,
                          changeFont: { fontSize = $0 }, toggleColumns: { twoColumns.toggle() }, edit: edit).equatable()
    }
}

private struct ChartPresentation: View, Equatable {
    let song: LibrarySong?
    let document: ChordProDocument?
    let fontSize: Double
    let twoColumns: Bool
    let changeFont: (Double) -> Void
    let toggleColumns: () -> Void
    let edit: () -> Void
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.song == rhs.song && lhs.fontSize == rhs.fontSize && lhs.twoColumns == rhs.twoColumns }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let song, let document {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(song.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                            let artist = song.artist
                            if !artist.isEmpty { Text(artist).foregroundStyle(.secondary) }
                            if let subtitle = document.metadataValues["subtitle"]?.joined(separator: " · "), !subtitle.isEmpty {
                                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 8) {
                            HStack(spacing: 6) {
                                Button(action: toggleColumns) {
                                    ChartColumnsIcon(count: twoColumns ? 1 : 2).frame(minWidth: 28)
                                }.accessibilityLabel(twoColumns ? "Use one chart column" : "Use two chart columns")
                                    .accessibilityValue(twoColumns ? "Two columns" : "One column")
                                    .help(twoColumns ? "Switch to one column" : "Switch to two columns when space allows")
                                Button { changeFont(max(12, fontSize - 1)) } label: { Text("A−").font(.system(size: 16, weight: .medium)).frame(minWidth: 28) }
                                    .disabled(fontSize <= 12).accessibilityLabel("Smaller chart text").help("Smaller chart text and tighter lines")
                                Button { changeFont(min(36, fontSize + 1)) } label: { Text("A+").font(.system(size: 16, weight: .medium)).frame(minWidth: 28) }
                                    .disabled(fontSize >= 36).accessibilityLabel("Larger chart text").help("Larger chart text and wider lines")

                            }.buttonStyle(.bordered)
                            Button(action: edit) { Label("Edit", systemImage: "square.and.pencil") }
                                .buttonStyle(.bordered).accessibilityLabel("Edit song")
                        }

                    }
                    HStack(spacing: 14) {
                        if let key = song.displayKey { Text("Key \(key)") }
                        if let capo = song.capo, capo != "0" { Text("Capo \(capo)") }
                        if let tempo = song.tempo, tempo.isFinite { Text("\(Int(tempo)) BPM") }
                        if let meter = song.timeSignature { Text(meter) }
                        if let duration = song.duration, !duration.isEmpty {
                            Text(ChordProDocument.readableDuration(duration))
                        }
                    }.font(.caption).foregroundStyle(.secondary)

                }.padding(18)
                Divider()
                GeometryReader { geo in
                    ScrollView {
                        // Measured, eager rows preserve stable scrolling and left-to-right reading.
                        ChartFlowLayout(fontSize: fontSize, twoColumns: twoColumns) {
                            ForEach(document.blocks) { block in
                                Group {
                                    if block.isTablature {
                                        let columns = block.lines.map { $0.text.count }.max() ?? 1
                                        // Tablature always uses the full chart width, outside paired rows.
                                        let width = max(1, geo.size.width - 40)
                                        let tabSize = min(fontSize, max(12, width / (Double(max(1, columns)) * 0.61)))
                                        let tabSpacing = tabSize * 0.08
                                        ScrollView(.horizontal) {
                                            Text(block.lines.map(\.text).joined(separator: "\n"))
                                                .font(.system(size: tabSize, design: .monospaced)).lineSpacing(tabSpacing)
                                                .fixedSize(horizontal: true, vertical: true).textSelection(.enabled)
                                        }.frame(height: ceil(Double(block.lines.count) * tabSize * 1.35 + Double(max(0, block.lines.count - 1)) * tabSpacing))
                                    } else if let line = block.lines.first {
                                        switch line.kind {
                                        case .blank: Color.clear.frame(height: fontSize * 0.55)
                                        case .section: Text(line.text).font(.system(size: fontSize * 0.88, weight: .bold, design: .monospaced)).foregroundStyle(Color(white: 0.78)).padding(.top, fontSize * 0.4)
                                        case .comment:
                                            Text(line.text).font(.system(size: fontSize * 0.82, design: .monospaced))
                                                .italic(line.commentStyle == .italic).foregroundStyle(.secondary)
                                                .padding(line.commentStyle == .box ? 6 : 0)
                                                .overlay {
                                                    if line.commentStyle == .box { RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.5)) }
                                                }
                                        case .tablature: EmptyView()
                                        case .lyrics:
                                            if line.fragments.allSatisfy({ $0.lyric.trimmingCharacters(in: .whitespaces).isEmpty }) {
                                                Text(line.fragments.map(\.chord).filter { !$0.isEmpty }.joined(separator: " "))
                                                    .font(.system(size: fontSize, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                                            } else if line.fragments.contains(where: { !$0.chord.isEmpty }) {
                                                ChordLineLayout(fontSize: fontSize, rowSpacing: fontSize * 0.18) {
                                                    ForEach(Array(ChordProDocument.words(line.fragments).enumerated()), id: \.offset) { _, fragment in
                                                        VStack(alignment: .leading, spacing: fontSize * 0.05) {
                                                            Text(fragment.chord.isEmpty ? " " : fragment.chord)
                                                                .font(.system(size: fontSize, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                                                            Text(fragment.lyric.isEmpty ? " " : fragment.lyric)
                                                                .font(.system(size: fontSize, design: .monospaced))
                                                        }.fixedSize(horizontal: true, vertical: true)
                                                            .frame(minWidth: Double(fragment.displayColumns) * fontSize * 0.6, alignment: .leading)
                                                    }
                                                }
                                            } else {
                                                Text(line.fragments.map(\.lyric).joined()).font(.system(size: fontSize, design: .monospaced))
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                }
                                .layoutValue(key: ChartSpanKey.self, value: block.lines.first?.kind != .lyrics)
                            }
                            if !document.unsupportedDirectives.isEmpty {
                                Text("Not rendered: " + document.unsupportedDirectives.joined(separator: ", ") + ". Source is kept for editing.")
                                    .font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
                                    .layoutValue(key: ChartSpanKey.self, value: true)
                            }
                            ForEach(Array(document.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.caption).foregroundStyle(.secondary)
                                    .layoutValue(key: ChartSpanKey.self, value: true)
                            }
                        }.lineSpacing(fontSize * 0.1).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }.id(song.id)
                }
            } else {
                GeometryReader { geo in
                    let artworkSize = max(0, min(320, geo.size.width * 0.55, geo.size.height - 110))
                    VStack(spacing: min(22, max(8, geo.size.height * 0.03))) {
                        WelcomeArtwork()
                            .frame(width: artworkSize, height: artworkSize)
                            .opacity(0.14).accessibilityHidden(true)
                        Text("Choose a song").font(.title3).foregroundStyle(.secondary)
                        Text("Select a song from your library to open its chart.")
                            .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.015))
    }
}

private struct ChordLineLayout: Layout {
    let fontSize: Double
    let rowSpacing: CGFloat
    struct Placement { let point: CGPoint; let size: CGSize }
    struct Cache {
        var sizes: [CGSize]
        var typography: Double
        var width: CGFloat?
        var size = CGSize.zero
        var placements: [Placement] = []
    }
    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, typography: fontSize)
    }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = makeCache(subviews: subviews) }
    private func arrange(_ subviews: Subviews, width: CGFloat, cache: inout Cache) {
        if cache.typography != fontSize { cache = makeCache(subviews: subviews) }
        let width = width.isFinite ? max(1, width) : max(1, cache.sizes.reduce(0) { $0 + $1.width })
        guard cache.width != width else { return }
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, result: [Placement] = []
        result.reserveCapacity(subviews.count)
        for (index, view) in subviews.enumerated() {
            var size = cache.sizes[index]
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
            result.append(Placement(point: CGPoint(x: x, y: y), size: size))
            x += size.width; rowHeight = max(rowHeight, size.height)
        }
        cache.width = width; cache.size = CGSize(width: width, height: y + rowHeight); cache.placements = result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrange(subviews, width: proposal.width ?? 600, cache: &cache)
        return cache.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        arrange(subviews, width: bounds.width, cache: &cache)
        for (index, item) in cache.placements.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + item.point.x, y: bounds.minY + item.point.y), anchor: .topLeading,
                                 proposal: ProposedViewSize(item.size))
        }
    }
}

private struct ChartSpanKey: LayoutValueKey {
    static let defaultValue = false
}

/// Read across paired lines; headings and tablature use the full chart width.
/// Measurements are cached by width and typography, never by audio telemetry.
private struct ChartFlowLayout: Layout {
    let fontSize: Double
    let twoColumns: Bool
    struct Placement { let point: CGPoint; let size: CGSize }
    struct Cache {
        var width: CGFloat?
        var fontSize: Double = 0
        var twoColumns = false
        var size = CGSize.zero
        var placements: [Placement] = []
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }
    private func arrange(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        let width = width.isFinite ? max(1, width) : 600
        guard cache.width != width || cache.fontSize != fontSize || cache.twoColumns != twoColumns else { return }
        let spacing = fontSize * 0.2
        let columnWidth = ChartColumnPlan.columnWidth(availableWidth: width, fontSize: fontSize, twoColumns: twoColumns)
        let spanning = subviews.map { $0[ChartSpanKey.self] }
        let rows = ChartColumnPlan.rows(spanning: spanning, availableWidth: width, fontSize: fontSize, twoColumns: twoColumns)
        var placements: [Placement] = [], y: Double = 0
        placements.reserveCapacity(subviews.count)
        for row in rows {
            var height = 0.0
            for (column, index) in row.enumerated() {
                let itemWidth = spanning[index] ? width : columnWidth
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
                placements.append(Placement(point: CGPoint(x: Double(column) * (columnWidth + ChartColumnPlan.gutter), y: y),
                                            size: CGSize(width: itemWidth, height: size.height)))
                height = max(height, size.height)
            }
            y += height + spacing
        }
        cache.width = width; cache.fontSize = fontSize; cache.twoColumns = twoColumns
        cache.size = CGSize(width: width, height: max(0, y - spacing)); cache.placements = placements
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrange(width: proposal.width ?? 600, subviews: subviews, cache: &cache)
        return cache.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        arrange(width: bounds.width, subviews: subviews, cache: &cache)
        for (index, item) in cache.placements.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + item.point.x, y: bounds.minY + item.point.y),
                                 anchor: .topLeading, proposal: ProposedViewSize(item.size))
        }
    }
}

private struct ChartColumnsIcon: View {
    let count: Int
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<4) { line in
                        Rectangle().frame(width: (count == 1 ? 22.0 : 9.0) * (line == 3 ? 0.7 : 1), height: 1.5)
                    }
                }
            }
        }.frame(width: 24, height: 16).accessibilityHidden(true)
    }
}
