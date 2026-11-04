import SwiftUI
import JamCore

struct AudioSettingsView: View {
    @ObservedObject var model: LooperModel
    @ObservedObject var library: SongLibraryModel
    let dismiss: () -> Void
    let chooseFolder: () -> Void
    let recoverDraft: (SongDraft) -> Void
    @State private var reviewingConflicts = false
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    private var bufferSummary: String {
        #if os(macOS)
        return "32 samples"
        #else
        return model.running ? "\(model.audioCallbackFrames) samples" : "Requests 32 samples · iPadOS chooses buffer"
        #endif
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(JamPlainButtonStyle())
                }
                Text("Audio").font(.subheadline.weight(.semibold))
                VStack(spacing: 12) {
                    Picker("Input", selection: $model.inputUID) {
                        if model.input == nil { Text("Choose input…").tag(model.inputUID) }
                        ForEach(model.inputs) { Text($0.name).tag($0.uid) }
                    }.hoverHighlight()
                    Picker("Output", selection: $model.outputUID) {
                        if model.output == nil { Text("Choose output…").tag(model.outputUID) }
                        ForEach(model.outputs) { Text($0.name).tag($0.uid) }
                    }.hoverHighlight()
                    Picker("Capture", selection: $model.inputChannel) {
                        ForEach(Array(stride(from: 0, to: max(1, model.input?.inputs ?? 2), by: 2)), id: \.self) { ch in
                            Text((model.input?.inputs ?? 2) > ch + 1 ? "Inputs \(ch + 1)–\(ch + 2)" : "Input \(ch + 1)").tag(ch)
                        }
                    }.hoverHighlight()
                }.disabled(model.starting || model.hasLoop || model.busy)
                Text("\(Int(model.sampleRate / 1000)) kHz · " + bufferSummary + " · outputs 1–2 · AM4 live monitoring").font(.caption).foregroundStyle(.secondary)
                Text(model.starting ? "Connecting audio…" : model.running ? "Audio connected automatically" : "Waiting for an audio interface")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.running && !model.starting {
                    Button("Retry Connection") { Task { await model.retryAudio() } }
                        .disabled(model.input == nil || model.output == nil)
                }
                Divider()
                MIDIPedalSettings(midi: model.midi)
                Divider()
                Text("Chord Library").font(.subheadline.weight(.semibold))
                Text(library.status).font(.caption).foregroundStyle(.secondary)
                Text("Library folder: \(library.folderURL.lastPathComponent)").font(.caption).lineLimit(2)
                Button("Choose library folder…") { chooseFolder() }
                if !library.conflicts.isEmpty {
                    Button("Review iCloud versions…") { reviewingConflicts = true }
                }
                if !library.recoveredDrafts.isEmpty {
                    Text("Unsaved edits").font(.subheadline.weight(.semibold))
                    ForEach(library.recoveredDrafts) { recovery in
                        Button("Recover: " + recovery.draft.title) { recoverDraft(recovery.draft) }
                    }
                }
                Text("Mac Jams edits library.json in this folder. JustChords syncing is off. Each save keeps the previous JSON in Library Backups.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = library.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(20)
        }.frame(width: 430, height: 540).tint(accent)
        .sheet(isPresented: $reviewingConflicts) { LibraryConflictView(library: library) }
        .task { await library.refreshRecoveredDrafts() }
    }
}

private struct MIDIPedalSettings: View {
    @ObservedObject var midi: JamMIDIInput
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MIDI Pedals").font(.subheadline.weight(.semibold))
            Text(midi.status).font(.caption).foregroundStyle(.secondary)
            Text("CC22 Arm · CC23 Record / Finish · CC24 Play / Stop\nCC25 Clear · CC26 Drummer Play / Stop")
                .font(.caption).foregroundStyle(.secondary)
            Text("All MIDI inputs and channels · nonzero values trigger; zero releases are ignored")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
