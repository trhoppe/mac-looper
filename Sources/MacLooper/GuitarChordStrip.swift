import SwiftUI
import JamCore

struct GuitarChordStrip: View {
    @ObservedObject var library: SongLibraryModel
    let song: LibrarySong
    let chords: [String]
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(chords, id: \.self) { chord in
                        let saved = song.chordVoicings[chord]
                        let shapes = positions(chord, saved: saved)
                        GuitarChordCard(chord: chord, shapes: shapes, selected: saved ?? shapes.first,
                                        enabled: !library.saving && !library.syncing && !library.editing) { shape in
                            Task {
                                do {
                                    try await library.saveChordVoicing(shape, chord: chord, songID: song.id)
                                    saveError = nil
                                } catch { saveError = "Couldn’t save \(chord): \(error.localizedDescription)" }
                            }
                        }
                    }
                }.padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 14)
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.orange).padding(.horizontal, 18).padding(.bottom, 8)
            }
        }
        .onChange(of: song.id) { _, _ in saveError = nil }
    }
    private func positions(_ chord: String, saved: GuitarChordShape?) -> [GuitarChordShape] {
        var shapes = GuitarChordCatalogue.shared.shapes(for: chord)
        if let saved, !shapes.contains(saved) { shapes.insert(saved, at: 0) }
        return shapes
    }
}

private struct GuitarChordCard: View {
    let chord: String
    let shapes: [GuitarChordShape]
    let selected: GuitarChordShape?
    let enabled: Bool
    let choose: (GuitarChordShape) -> Void
    @State private var hovering = false
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    private var controlsVisible: Bool {
        #if os(macOS)
        hovering
        #else
        true
        #endif
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                arrow("chevron.left", direction: -1)
                Text(chord).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                    .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
                arrow("chevron.right", direction: 1)
            }
            if let selected {
                GuitarChordDiagram(shape: selected).frame(height: 94)
                    // Balance the extra space reserved for fret numbers so the
                    // visible fretboard is centered beneath the chord name.
                    .offset(x: -6)
                    .accessibilityLabel("\(chord), frets from low E to high E: \(selected.frets.map { $0 < 0 ? "muted" : $0 == 0 ? "open" : String($0 + selected.baseFret - 1) }.joined(separator: ", "))")
                    .accessibilityAdjustableAction { direction in cycle(direction == .increment ? 1 : -1) }
            } else {
                Text("No diagram").font(.caption2).foregroundStyle(.secondary)
                    .frame(height: 94).frame(maxWidth: .infinity)
            }
        }.frame(width: 90)
            .contentShape(Rectangle()).onHover { hovering = $0 }
            .accessibilityElement(children: .contain).accessibilityLabel("\(chord) chord")
    }
    private func arrow(_ symbol: String, direction: Int) -> some View {
        Button { cycle(direction) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 20)
        }.buttonStyle(JamPlainButtonStyle())
            .opacity(controlsVisible && shapes.count > 1 ? 1 : 0)
            .disabled(!enabled || shapes.count < 2)
            .accessibilityHidden(!controlsVisible || shapes.count < 2)
            .accessibilityLabel("\(direction < 0 ? "Previous" : "Next") \(chord) fingering")
            .help("\(direction < 0 ? "Previous" : "Next") \(chord) fingering")
    }
    private func cycle(_ direction: Int) {
        guard enabled, shapes.count > 1 else { return }
        let index = selected.flatMap { shapes.firstIndex(of: $0) } ?? 0
        choose(shapes[(index + direction + shapes.count) % shapes.count])
    }
}

struct GuitarChordDiagram: View {
    let shape: GuitarChordShape
    var degreeLabels: [String]? = nil
    var rootStrings: Set<Int> = []
    var body: some View {
        Canvas { context, size in
            let left = 20.0, top = 18.0
            let width = size.width - left - 8
            let height = size.height - top - 5
            let rows = Double(max(4, shape.frets.max() ?? 4))
            let stringWidth = width / 5, fretHeight = height / rows
            var grid = Path()
            for string in 0..<6 {
                let x = left + Double(string) * stringWidth
                grid.move(to: CGPoint(x: x, y: top)); grid.addLine(to: CGPoint(x: x, y: top + height))
            }
            for fret in 0...Int(rows) {
                let y = top + Double(fret) * fretHeight
                grid.move(to: CGPoint(x: left, y: y)); grid.addLine(to: CGPoint(x: left + width, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.45)), lineWidth: 0.7)
            if shape.baseFret == 1 {
                let nut = CGRect(x: left - 0.5, y: top - 1, width: width + 1, height: 2.5)
                context.fill(Path(nut), with: .color(.white.opacity(0.8)))
            } else {
                context.draw(Text("\(shape.baseFret)").font(.system(size: 10)).foregroundStyle(.secondary),
                             at: CGPoint(x: left - 8, y: top + fretHeight / 2), anchor: .trailing)
            }
            for barre in shape.barres {
                // The database marks the strings actually fretted by this barre.
                let strings = shape.frets.indices.filter { shape.frets[$0] == barre }
                guard let start = strings.first, let end = strings.last, start != end else { continue }
                let rect = CGRect(x: left + Double(start) * stringWidth - 4,
                                  y: top + (Double(barre) - 0.5) * fretHeight - 4,
                                  width: Double(end - start) * stringWidth + 8, height: 8)
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.white.opacity(0.85)))
            }
            for string in 0..<6 {
                let fret = shape.frets[string], x = left + Double(string) * stringWidth
                let color: Color = rootStrings.contains(string) ? Color(red: 0.259, green: 0.788, blue: 0.961) : .white
                let degree = degreeLabels.flatMap { $0.indices.contains(string) ? $0[string] : nil }
                if fret <= 0 {
                    if fret == 0, let degree, !degree.isEmpty {
                        let point = CGPoint(x: x, y: top - 9)
                        context.stroke(Path(ellipseIn: CGRect(x: x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(color), lineWidth: 1)
                        context.draw(Text(degree).font(.system(size: degree.count > 1 ? 6 : 8, weight: .bold)).foregroundStyle(color), at: point)
                    } else {
                        context.draw(Text(fret < 0 ? "×" : "○").font(.system(size: 11)).foregroundStyle(.secondary),
                                     at: CGPoint(x: x, y: top - 9))
                    }
                } else {
                    let y = top + (Double(fret) - 0.5) * fretHeight
                    context.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)), with: .color(color))
                    let finger = shape.fingers[string]
                    if let degree, !degree.isEmpty {
                        context.draw(Text(degree).font(.system(size: degree.count > 1 ? 6 : 8, weight: .bold)).foregroundStyle(.black), at: CGPoint(x: x, y: y))
                    } else if finger > 0 {
                        context.draw(Text("\(finger)").font(.system(size: 8, weight: .bold)).foregroundStyle(.black), at: CGPoint(x: x, y: y))
                    }
                }
            }
        }
    }
}
