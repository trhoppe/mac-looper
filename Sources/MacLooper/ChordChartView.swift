import SwiftUI
import JamCore

struct ChordChartView: View {
    let song: LibrarySong?
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    @AppStorage("chartFontSize") private var fontSize = 21.0
    private var document: ChordProDocument? {
        song.map { ChordProDocument(source: $0.chordPro, transpose: $0.transposition, flats: $0.displayKey?.contains("b") == true) }
    }
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
                        Button { fontSize = max(14, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                            .accessibilityLabel("Smaller chart text")
                        Button { fontSize = min(36, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                            .accessibilityLabel("Larger chart text")
                    }
                    HStack(spacing: 14) {
                        if let key = song.displayKey { Text("Key \(key)") }
                        if let capo = song.capo, capo != "0" { Text("Capo \(capo)") }
                        if let tempo = song.tempo { Text("\(Int(tempo)) BPM") }
                        if let meter = song.fields["timeSignature"]?.text { Text(meter) }
                    }.font(.caption).foregroundStyle(.secondary)

                }.padding(18)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(document.lines) { line in
                            switch line.kind {
                            case .blank: Color.clear.frame(height: fontSize * 0.55)
                            case .section: Text(line.text).font(.system(size: fontSize * 0.88, weight: .semibold)).foregroundStyle(accent).padding(.top, 9)
                            case .comment: Text(line.text).font(.system(size: fontSize * 0.82)).italic().foregroundStyle(.secondary)
                            case .tablature: Text(line.text).font(.system(size: fontSize * 0.78, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                            case .lyrics:
                                if line.fragments.allSatisfy({ $0.lyric.trimmingCharacters(in: .whitespaces).isEmpty }) {
                                    Text(line.fragments.map(\.chord).filter { !$0.isEmpty }.joined(separator: "   "))
                                        .font(.system(size: fontSize * 0.78, weight: .semibold)).foregroundStyle(accent)
                                } else if line.fragments.contains(where: { !$0.chord.isEmpty }) {
                                    ChordLineLayout {
                                        ForEach(Array(ChordProDocument.words(line.fragments).enumerated()), id: \.offset) { _, fragment in
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(fragment.chord.isEmpty ? " " : fragment.chord)
                                                    .font(.system(size: fontSize * 0.78, weight: .semibold)).foregroundStyle(accent)
                                                Text(fragment.lyric.isEmpty ? " " : fragment.lyric)
                                                    .font(.system(size: fontSize)).fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                } else {
                                    Text(line.fragments.map(\.lyric).joined()).font(.system(size: fontSize)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if !document.unsupportedDirectives.isEmpty {
                            Text("Additional chart directives are preserved in the library: " + document.unsupportedDirectives.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.id(song.id)
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
    struct Placement { let point: CGPoint; let size: CGSize }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (CGSize, [Placement]) {
        let width = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, result: [Placement] = []
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + 4; rowHeight = 0 }
            result.append(Placement(point: CGPoint(x: x, y: y), size: size))
            x += size.width; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), result)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 600).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = arrange(subviews, width: bounds.width).1
        for (index, item) in placements.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + item.point.x, y: bounds.minY + item.point.y), anchor: .topLeading,
                                 proposal: ProposedViewSize(item.size))
        }
    }
}
