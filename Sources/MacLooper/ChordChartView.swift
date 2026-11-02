import SwiftUI
import JamCore

// Persist typography outside the equatable chart: it must be an explicit input
// to equality and to every layout cache, rather than waiting for a song change.
struct ChordChartView: View {
    let song: LibrarySong?
    @AppStorage("chartFontSize") private var fontSize = 21.0
    private let document: ChordProDocument?
    init(song: LibrarySong?) {
        self.song = song
        document = song.map { ChordProDocument(source: $0.chordPro, transpose: $0.transposition, flats: $0.displayKey?.contains("b") == true) }
    }
    var body: some View {
        ChartPresentation(song: song, document: document, fontSize: fontSize,
                          changeFont: { fontSize = $0 }).equatable()
    }
}

private struct ChartPresentation: View, Equatable {
    let song: LibrarySong?
    let document: ChordProDocument?
    let fontSize: Double
    let changeFont: (Double) -> Void
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.song == rhs.song && lhs.fontSize == rhs.fontSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let song, let document {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(song.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                            if !song.artist.isEmpty { Text(song.artist).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 6) {
                            Button { changeFont(max(12, fontSize - 1)) } label: { Text("A−").font(.system(size: 16, weight: .medium)).frame(minWidth: 28) }
                                .disabled(fontSize <= 12).accessibilityLabel("Smaller chart text").help("Smaller chart text and tighter lines")
                            Button { changeFont(min(36, fontSize + 1)) } label: { Text("A+").font(.system(size: 16, weight: .medium)).frame(minWidth: 28) }
                                .disabled(fontSize >= 36).accessibilityLabel("Larger chart text").help("Larger chart text and wider lines")
                        }.buttonStyle(.bordered)

                    }
                    HStack(spacing: 14) {
                        if let key = song.displayKey { Text("Key \(key)") }
                        if let capo = song.capo, capo != "0" { Text("Capo \(capo)") }
                        if let tempo = song.tempo { Text("\(Int(tempo)) BPM") }
                        if let meter = song.fields["timeSignature"]?.text { Text(meter) }
                    }.font(.caption).foregroundStyle(.secondary)

                }.padding(18)
                Divider()
                GeometryReader { geo in
                    ScrollView {
                        // Measured, eager layout keeps scrolling stable and balances columns.
                        ChartFlowLayout(fontSize: fontSize) {
                            ForEach(document.blocks) { block in
                                Group {
                                    if block.isTablature {
                                        let columns = block.lines.map { $0.text.count }.max() ?? 1
                                        // The actual column width, not the entire chart width, fits tabs.
                                        let width = ChartColumnPlan.columnWidth(availableWidth: max(0, geo.size.width - 40), fontSize: fontSize)
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
                                        case .section: Text(line.text).font(.system(size: fontSize * 0.88, weight: .semibold, design: .monospaced)).foregroundStyle(accent).padding(.top, fontSize * 0.4)
                                        case .comment: Text(line.text).font(.system(size: fontSize * 0.82, design: .monospaced)).italic().foregroundStyle(.secondary)
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
                                .layoutValue(key: ChartBreakKey.self, value: block.lines.first?.kind == .section ? .section : block.lines.first?.kind == .blank ? .blank : .normal)
                            }
                            if !document.unsupportedDirectives.isEmpty {
                                Text("Additional chart directives are preserved in the library: " + document.unsupportedDirectives.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
                            }
                        }.lineSpacing(fontSize * 0.1).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }.id(song.id)
                }
            } else {
                GeometryReader { geo in
                    VStack(spacing: 22) {
                        Image("LooperArtwork").resizable().scaledToFit()
                            .frame(width: min(320, geo.size.width * 0.55), height: min(320, geo.size.height * 0.55))
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

private struct ChartBreakKey: LayoutValueKey {
    static let defaultValue = ChartColumnPlan.Break.normal
}

/// Vertical reading order, measured at the final column width. This never uses
/// lazy row-height estimates or modifies the underlying song/ChordPro content.
private struct ChartFlowLayout: Layout {
    let fontSize: Double
    struct Cache {
        var width: CGFloat?
        var fontSize: Double = 0
        var size = CGSize.zero
        var placements: [CGPoint] = []
        var columnWidth: CGFloat = 0
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }
    private func arrange(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        let width = width.isFinite ? max(1, width) : 600
        guard cache.width != width || cache.fontSize != fontSize else { return }
        let spacing = fontSize * 0.2
        var columnWidth = ChartColumnPlan.columnWidth(availableWidth: width, fontSize: fontSize)
        var heights = subviews.map { Double($0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height) }
        let split = ChartColumnPlan.split(heights: heights, breaks: subviews.map { $0[ChartBreakKey.self] },
                                          availableWidth: width, fontSize: fontSize)
        if split == nil, columnWidth != width {
            columnWidth = width
            heights = subviews.map { Double($0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height) }
        }
        var positions: [CGPoint] = [], y: Double = 0, leftHeight: Double = 0
        positions.reserveCapacity(subviews.count)
        for index in subviews.indices {
            if index == split { leftHeight = max(0, y - spacing); y = 0 }
            positions.append(CGPoint(x: split.map { index >= $0 ? columnWidth + ChartColumnPlan.gutter : 0 } ?? 0, y: y))
            y += heights[index] + spacing
        }
        cache.width = width; cache.fontSize = fontSize
        cache.size = CGSize(width: width, height: max(leftHeight, max(0, y - spacing)))
        cache.columnWidth = columnWidth; cache.placements = positions
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrange(width: proposal.width ?? 600, subviews: subviews, cache: &cache)
        return cache.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        arrange(width: bounds.width, subviews: subviews, cache: &cache)
        for (index, position) in cache.placements.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                 anchor: .topLeading, proposal: ProposedViewSize(width: cache.columnWidth, height: nil))
        }
    }
}
