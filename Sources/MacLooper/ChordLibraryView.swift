import JamDesignKit
import SwiftUI
import JamCore

struct ChordLibraryView: View {
    let close: () -> Void
    @State private var root = "C"
    @State private var quality = "major"
    @State private var bass = "hide"
    @State private var showingTriads = false
    @State private var triadQuality = "major"
    @State private var triadStrings: GuitarTriadStringSet? = .gbe
    @State private var triadInversion: GuitarTriadInversion? = nil
    private let catalogue = GuitarChordCatalogue.shared
    private let notes = ["C", "C#", "Db", "D", "D#", "Eb", "E", "F", "F#", "Gb", "G", "G#", "Ab", "A", "A#", "Bb", "B"]
    private let diagramScale = 1.2
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 112 * diagramScale + 24), spacing: 20)] }

    private struct Voicing: Identifiable {
        let group: GuitarChordCatalogue.Group
        let shape: GuitarChordShape
        var id: String { group.id + ":" + shape.id }
    }

    var body: some View {
        let groups = catalogue.filtered(root: root.isEmpty ? nil : root,
                                        quality: quality.isEmpty ? nil : quality,
                                        bass: bass.isEmpty || bass == "hide" ? nil : bass,
                                        includeSlashChords: bass != "hide")
        let voicings = groups.flatMap { group in group.shapes.map { Voicing(group: group, shape: $0) } }
        VStack(alignment: .leading, spacing: 0) {
            JamScreenHeader("Chord Library", icon: "guitars", close: close)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Picker("Chord library mode", selection: $showingTriads) {
                    Text("Chords").tag(false)
                    Text("Triads").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 200)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { filters }
                    VStack(alignment: .leading, spacing: 12) { filters }
                }
                if showingTriads {
                    Text("Cyan = root · Dots show chord tones · Standard tuning · Frets 0–22")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18)
            Divider()
            ScrollView {
                if showingTriads {
                    triadResults
                } else if groups.isEmpty {
                    Text("No matching chord diagrams").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(36)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(voicings) { voicing in
                            VStack(spacing: 8) {
                                Text(displayName(voicing.group)).font(.callout.weight(.semibold)).lineLimit(1)
                                    .foregroundStyle(JamDesign.accent)
                                GuitarChordDiagram(shape: voicing.shape).frame(width: 112, height: 134)
                                    .scaleEffect(diagramScale)
                                    .frame(width: 112 * diagramScale, height: 134 * diagramScale)
                        .offset(x: -6 * diagramScale)
                            }.frame(maxWidth: .infinity).jamSurface(padding: 12).hoverHighlight()
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(displayName(voicing.group)), base fret \(voicing.shape.baseFret), frets \(voicing.shape.frets.map(String.init).joined(separator: ", "))")
                        }
                    }
                    .padding(18)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(JamDesign.ground)
            .accessibilityAddTraits(.isModal)
    }
    @ViewBuilder private var filters: some View {
        filter("Chord", selection: $root, values: notes)
        if showingTriads {
            filter("Quality", selection: $triadQuality, values: GuitarTriadQuality.allCases.map(\.rawValue))
            HStack(spacing: 8) {
                Text("Strings").font(.callout).foregroundStyle(.secondary)
                Picker("Triad string set", selection: $triadStrings) {
                    Text("All").tag(GuitarTriadStringSet?.none)
                    ForEach(GuitarTriadStringSet.allCases, id: \.self) { value in Text(value.title).tag(Optional(value)) }
                }.labelsHidden().pickerStyle(.menu).fixedSize().hoverHighlight()
            }
            HStack(spacing: 8) {
                Text("Inversion").font(.callout).foregroundStyle(.secondary)
                Picker("Triad inversion", selection: $triadInversion) {
                    Text("All").tag(GuitarTriadInversion?.none)
                    ForEach(GuitarTriadInversion.allCases, id: \.self) { value in Text(value.title).tag(Optional(value)) }
                }.labelsHidden().pickerStyle(.menu).fixedSize().hoverHighlight()
            }
        } else {
            filter("Quality", selection: $quality, values: catalogue.qualities)
            filter("Slash bass", selection: $bass, values: notes, allowsHidingSlashChords: true)
        }
    }
    private var triads: [GuitarTriad] {
        let roots = root.isEmpty ? ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"] : [root]
        let qualities = triadQuality.isEmpty ? GuitarTriadQuality.allCases : GuitarTriadQuality(rawValue: triadQuality).map { [$0] } ?? []
        let stringSets = triadStrings.map { [$0] } ?? GuitarTriadStringSet.allCases
        let inversions = triadInversion.map { [$0] } ?? GuitarTriadInversion.allCases
        var result: [GuitarTriad] = []
        for name in roots {
            for quality in qualities {
                for strings in stringSets {
                    for inversion in inversions {
                        result += GuitarTriad.voicings(root: name, quality: quality, stringSet: strings, inversion: inversion)
                    }
                }
            }
        }
        return result
    }
    private var triadResults: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(triads) { triad in
                VStack(spacing: 5) {
                    VStack(spacing: 3) {
                        Text(triad.chordName).font(.callout.weight(.semibold))
                            .foregroundStyle(JamDesign.accent)
                        Text(triad.inversion.title).font(.caption).foregroundStyle(.secondary)
                        Text(triad.stringSet.title).font(.caption2).foregroundStyle(.secondary)
                    }
                    GuitarChordDiagram(shape: triad.shape, degreeLabels: triad.degrees, rootStrings: triad.rootStrings)
                        .frame(width: 112, height: 134).scaleEffect(diagramScale)
                        .frame(width: 112 * diagramScale, height: 134 * diagramScale)
                        .offset(x: -6 * diagramScale)
                    Text(triad.notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).jamSurface(padding: 12).hoverHighlight()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(triad.chordName), \(triad.inversion.title), \(triad.stringSet.title), notes \(triad.notes.joined(separator: ", ")), frets \(triad.absoluteFrets.map(String.init).joined(separator: ", "))")
            }
        }.padding(18)
    }
    private func filter(_ label: String, selection: Binding<String>, values: [String], allowsHidingSlashChords: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                if allowsHidingSlashChords {
                    Text("Hide").tag("hide")
                    Text("All").tag("")
                } else { Text("–").tag("") }
                ForEach(values, id: \.self) { value in Text(value == "69" ? "6/9" : value).tag(value) }
            }.labelsHidden().pickerStyle(.menu).fixedSize().hoverHighlight()
                .accessibilityLabel("Filter chord \(label.lowercased())")
        }
    }
    private func displayName(_ group: GuitarChordCatalogue.Group) -> String {
        let selectedRoot = root.isEmpty ? group.root : root
        let suffix = group.quality == "major" ? "" : group.quality == "minor" ? "m" : group.quality == "69" ? "6/9" : group.quality
        return selectedRoot + suffix + (group.bass.map { "/" + (bass.isEmpty ? $0 : bass) } ?? "")
    }
}
