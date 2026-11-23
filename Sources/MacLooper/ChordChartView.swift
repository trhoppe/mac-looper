import SwiftUI
import JamCore

// Persist typography outside the equatable chart: it must be an explicit input
// to equality and to every layout cache, rather than waiting for a song change.
struct ChordChartView: View {
    let song: LibrarySong?
    let edit: () -> Void
    let library: SongLibraryModel
    @AppStorage("chartFontSize") private var fontSize = 21.0
    @AppStorage("chartTwoColumns") private var twoColumns = true
    private let document: ChordProDocument?
    init(song: LibrarySong?, library: SongLibraryModel, edit: @escaping () -> Void = {}) {
        self.song = song; self.library = library; self.edit = edit
        document = song.map { ChordProDocument(source: $0.chordPro, transpose: $0.transposition, flats: $0.displayKey?.contains("b") == true) }
    }
    var body: some View {
        ChartPresentation(song: song, library: library, document: document, fontSize: fontSize, twoColumns: twoColumns,
                          changeFont: { fontSize = $0 }, toggleColumns: { twoColumns.toggle() }, edit: edit).equatable()
    }
}

private struct ChartPresentation: View, Equatable {
    let song: LibrarySong?
    let library: SongLibraryModel
    let document: ChordProDocument?
    let fontSize: Double
    let twoColumns: Bool
    let changeFont: (Double) -> Void
    let toggleColumns: () -> Void
    let edit: () -> Void
    @AppStorage("showChordDiagrams") private var showingDiagrams = true
    @State private var autoScrolling = false
    @Environment(\.scenePhase) private var scenePhase
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.song == rhs.song && lhs.fontSize == rhs.fontSize && lhs.twoColumns == rhs.twoColumns }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let song, let document {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        songTitle(song, document: document)
                        Spacer(minLength: 12)
                        chartControls(song)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        songTitle(song, document: document)
                        HStack { Spacer(minLength: 0); chartControls(song) }
                    }
                }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
                if !document.guitarChords.isEmpty {
                    HStack(alignment: .top, spacing: 0) {
                        if showingDiagrams {
                            GuitarChordStrip(library: library, song: song, chords: document.guitarChords)
                        } else { Spacer(minLength: 0) }
                        Button { withAnimation(.easeInOut(duration: 0.18)) { showingDiagrams.toggle() } } label: {
                            Image(systemName: showingDiagrams ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
                        }.buttonStyle(JamPlainButtonStyle())
                            .accessibilityLabel(showingDiagrams ? "Hide chord diagrams" : "Show chord diagrams")
                            .help(showingDiagrams ? "Hide chord diagrams" : "Show chord diagrams")
                            .padding(.top, 2).padding(.trailing, 18).padding(.bottom, 6)
                    }
                }
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
                            .background {
                                ChartAutoScroll(active: $autoScrolling, duration: ChartScrollTiming.duration(song.duration))
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
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
            .onChange(of: song?.id) { _, _ in autoScrolling = false }
            .onChange(of: song?.chordPro) { _, _ in autoScrolling = false }
            .onChange(of: scenePhase) { _, phase in if phase != .active { autoScrolling = false } }
            .onDisappear { autoScrolling = false }
    }
    private func songTitle(_ song: LibrarySong, document: ChordProDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            if !song.artist.isEmpty { Text(song.artist).foregroundStyle(.secondary) }
            if let subtitle = document.metadataValues["subtitle"]?.joined(separator: " · "), !subtitle.isEmpty {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private func chartControls(_ song: LibrarySong) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                Button { autoScrolling.toggle() } label: {
                    Image(systemName: autoScrolling ? "pause.fill" : "play.fill")
                        .foregroundStyle(autoScrolling ? accent : Color.primary)
                        .frame(width: 18, height: 14)
                }.overlay {
                    RoundedRectangle(cornerRadius: 6).fill(accent.opacity(autoScrolling ? 0.18 : 0)).allowsHitTesting(false)
                }.accessibilityLabel(autoScrolling ? "Pause chart auto-scroll" : "Start chart auto-scroll")
                    .accessibilityValue(autoScrolling ? "On" : "Off")
                    .help("Scroll chart over " + ChordProDocument.readableDuration(String(Int(ChartScrollTiming.duration(song.duration)))))
                Button(action: toggleColumns) {
                    ChartColumnsIcon(count: twoColumns ? 1 : 2).scaleEffect(0.8).frame(width: 18, height: 14)
                }.accessibilityLabel(twoColumns ? "Use one chart column" : "Use two chart columns")
                    .accessibilityValue(twoColumns ? "Two columns" : "One column")
                    .help(twoColumns ? "Switch to one column" : "Switch to two columns when space allows")
                Button { changeFont(max(12, fontSize - 1)) } label: {
                    Text("A−").font(.system(size: 12, weight: .medium)).frame(width: 18, height: 14)
                }.disabled(fontSize <= 12).accessibilityLabel("Smaller chart text").help("Smaller chart text and tighter lines")
                Button { changeFont(min(36, fontSize + 1)) } label: {
                    Text("A+").font(.system(size: 12, weight: .medium)).frame(width: 18, height: 14)
                }.disabled(fontSize >= 36).accessibilityLabel("Larger chart text").help("Larger chart text and wider lines")
                Button(action: edit) {
                    Image(systemName: "square.and.pencil").frame(width: 18, height: 14)
                }.accessibilityLabel("Edit song").help("Edit song")
            }.buttonStyle(JamButtonStyle()).controlSize(.regular)
            Text(songMetadata(song)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func songMetadata(_ song: LibrarySong) -> String {
        var values: [String] = []
        if let key = song.displayKey { values.append("Key " + key) }
        if let capo = song.capo, capo != "0" { values.append("Capo " + capo) }
        if let tempo = song.tempo, tempo.isFinite { values.append("\(Int(tempo)) BPM") }
        if let meter = song.timeSignature { values.append(meter) }
        if let duration = song.duration, !duration.isEmpty { values.append(ChordProDocument.readableDuration(duration)) }
        return values.joined(separator: " · ")
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
