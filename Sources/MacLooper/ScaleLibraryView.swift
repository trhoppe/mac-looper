import JamDesignKit
import SwiftUI
import JamCore

struct ScaleLibraryView: View {
    let close: () -> Void
    @AppStorage("scaleLibraryRoot") private var root = "A"
    @AppStorage("scaleLibraryKind") private var kind = GuitarPentatonic.minor
    @AppStorage("scaleLibraryLearningStyle") private var learningStyle = GuitarScaleLearningStyle.full
    private let notes = ["C", "C#", "Db", "D", "D#", "Eb", "E", "F", "F#", "Gb", "G", "G#", "Ab", "A", "A#", "Bb", "B"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JamScreenHeader("Scales", icon: "music.note.list", close: close)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { filters }
                VStack(alignment: .leading, spacing: 12) { filters }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(GuitarScales.studies(root: root, kind: kind, style: learningStyle)) { study in
                        patternCard(study)
                    }
                }.padding(18)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(JamDesign.ground)
            .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private var filters: some View {
        HStack(spacing: 8) {
            Text("Root").font(.callout).foregroundStyle(.secondary)
            Picker("Scale root", selection: $root) {
                ForEach(notes, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().pickerStyle(.menu).fixedSize().hoverHighlight()
            Picker("Scale", selection: $kind) {
                ForEach(GuitarPentatonic.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.menu).fixedSize().hoverHighlight()
        }
        HStack(spacing: 8) {
            Text("Style").font(.callout).foregroundStyle(.secondary)
            Picker("Learning style", selection: $learningStyle) {
                ForEach(GuitarScaleLearningStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.menu).fixedSize().hoverHighlight()
        }
    }

    private func patternCard(_ study: GuitarScaleStudy) -> some View {
        let pattern = study.pattern, regions = study.regions
        let height = regions.isEmpty ? 252.0 : 320.0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(study.title).font(.headline)
                Spacer()
                Text("Frets \(pattern.firstFret)–\(pattern.lastFret)").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    ScaleFretboard(pattern: pattern, regions: regions, route: study.path)
                        .frame(width: max(geometry.size.width, CGFloat(pattern.lastFret - pattern.firstFret + 1) * 36 + 48), height: height)
                }
            }.frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(root) \(kind.title), \(study.title), frets \(pattern.firstFret) to \(pattern.lastFret)")
            .accessibilityValue((regions.map { "Position \($0.position), frets \($0.firstFret) to \($0.lastFret)" } + pattern.tones.map { "string \(6 - $0.string), fret \($0.fret), \($0.note), \($0.degree)\(pattern.extensionIDs.contains($0.id) ? ", connecting note" : "")" }).joined(separator: "; "))
        }.jamSurface()
    }
}

private struct ScaleFretboard: View {
    let pattern: GuitarScalePattern
    let regions: [GuitarScalePositionRegion]
    let route: [GuitarScaleTone]
    private let accent = JamDesign.accent

    var body: some View {
        Canvas { context, size in
            let left = 32.0, right = size.width - 16, top = regions.isEmpty ? 24.0 : 92.0, bottom = size.height - 38
            let count = pattern.lastFret - pattern.firstFret + 1
            let step = (right - left) / Double(count), strings = ["E", "A", "D", "G", "B", "e"]
            func x(_ fret: Int) -> Double { left + (Double(fret - pattern.firstFret) + 0.5) * step }
            func y(_ string: Int) -> Double { bottom - Double(string) * (bottom - top) / 5 }
            // Boxes overlap, so alternate bracket rows rather than implying
            // that each position occupies a separate strip of the neck.
            for (index, region) in regions.enumerated() {
                let start = x(region.firstFret) - step / 2 + 2
                let end = x(region.lastFret) + step / 2 - 2
                let row = Double(index % 2) * 34
                context.draw(Text("Position \(region.position)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary),
                             at: CGPoint(x: (start + end) / 2, y: row + 10))
                var bracket = Path()
                bracket.move(to: CGPoint(x: start, y: row + 31))
                bracket.addLine(to: CGPoint(x: start, y: row + 25))
                bracket.addLine(to: CGPoint(x: end, y: row + 25))
                bracket.addLine(to: CGPoint(x: end, y: row + 31))
                context.stroke(bracket, with: .color(.white.opacity(0.4)), lineWidth: 1)
            }
            for string in 0..<6 {
                var path = Path(); path.move(to: CGPoint(x: left, y: y(string))); path.addLine(to: CGPoint(x: right, y: y(string)))
                context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: string < 3 ? 1.5 : 1)
                context.draw(Text(strings[string]).font(.caption).foregroundStyle(.secondary), at: CGPoint(x: 10, y: y(string)))
            }
            for offset in 0...count {
                let fret = pattern.firstFret + offset
                let xpos = left + Double(offset) * step
                var path = Path(); path.move(to: CGPoint(x: xpos, y: top)); path.addLine(to: CGPoint(x: xpos, y: bottom))
                let nut = fret == 1 && pattern.firstFret == 0
                context.stroke(path, with: .color(.white.opacity(nut ? 0.8 : 0.18)), lineWidth: nut ? 3 : 1)
            }
            for fret in pattern.firstFret...pattern.lastFret {
                context.draw(Text(fret == 0 ? "Open" : String(fret)).font(.caption).foregroundStyle(.secondary), at: CGPoint(x: x(fret), y: bottom + 23))
            }
            if let first = route.first {
                var path = Path(); path.move(to: CGPoint(x: x(first.fret), y: y(first.string)))
                var previous = first
                for tone in route.dropFirst() {
                    let point = CGPoint(x: x(tone.fret), y: y(tone.string))
                    let distance = GuitarScales.tuning[tone.string] + tone.fret - GuitarScales.tuning[previous.string] - previous.fret
                    // A clipped note at either neck edge breaks the route.
                    if distance <= 3 { path.addLine(to: point) } else { path.move(to: point) }
                    previous = tone
                }
                context.stroke(path, with: .color(accent.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            for tone in pattern.tones {
                let point = CGPoint(x: x(tone.fret), y: y(tone.string)), radius = 13.0
                let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                let fill = tone.isRoot ? accent : pattern.extensionIDs.contains(tone.id) ? Color(red: 1, green: 0.76, blue: 0.48) : Color(white: 0.83)
                context.fill(circle, with: .color(fill))
                context.draw(Text(tone.degree).font(.system(size: 11, weight: .semibold)).foregroundStyle(.black), at: point)
            }
        }
    }
}
