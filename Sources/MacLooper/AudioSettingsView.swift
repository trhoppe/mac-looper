import JamDesignKit
import SwiftUI
import JamCore

struct AudioSettingsView: View {
    @ObservedObject var model: LooperModel
    @ObservedObject var library: SongLibraryModel
    let dismiss: () -> Void
    let chooseFolder: () -> Void
    let recoverDraft: (SongDraft) -> Void
    @State private var reviewingConflicts = false
    private let accent = JamDesign.accent
    private var bufferSummary: String {
        #if os(macOS)
        return "32 samples"
        #else
        return model.running ? "\(model.audioCallbackFrames) samples" : "Requests 32 samples · system chooses buffer"
        #endif
    }
    var body: some View {
        Group {
        #if os(iOS)
            NavigationStack {
                Form {
                    Section {
                        inputPicker.disabled(routingLocked)
                        capturePicker.disabled(routingLocked)
                        LabeledContent("Output", value: model.output?.name ?? "System output")
                        if !model.running && !model.starting { retryConnection }
                    } header: {
                        Text("Audio")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(audioSummary)
                            audioStatus
                        }
                    }
                    Section {
                        LabeledContent("Folder", value: library.folderURL.lastPathComponent)
                        Button("Choose library folder…", action: chooseFolder)
                        if !library.conflicts.isEmpty {
                            Button("Review iCloud versions…") { reviewingConflicts = true }
                        }
                    } header: {
                        Text("Song Library")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(library.status)
                            Text("Loops save in this library’s Loops folder. Choose the same iCloud Drive library folder on your devices.")
                            if let error = library.error { Text(error).foregroundStyle(.orange) }
                        }
                    }
                    Section("MIDI Pedals") {
                        MIDIPedalSettings(midi: model.midi, showTitle: false)
                    }
                    if !library.recoveredDrafts.isEmpty {
                        Section("Unsaved Edits") { recoveryButtons }
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: dismiss) }
                }
            }
            .tint(accent)
        #else
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Settings").font(.headline)
                        Spacer()
                        Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(JamPlainButtonStyle())
                    }
                    Text("Audio").font(.subheadline.weight(.semibold))
                    VStack(spacing: 12) {
                        inputPicker
                        Picker("Output", selection: $model.outputUID) {
                            if model.output == nil { Text("Choose output…").tag(model.outputUID) }
                            ForEach(model.outputs) { Text($0.name).tag($0.uid) }
                        }.hoverHighlight()
                        capturePicker
                    }.disabled(routingLocked)
                    Text(audioSummary).font(.caption).foregroundStyle(.secondary)
                    audioStatus
                    if !model.running && !model.starting { retryConnection }
                    Divider()
                    MIDIPedalSettings(midi: model.midi)
                    Divider()
                    Text("Chord Library").font(.subheadline.weight(.semibold))
                    Text(library.status).font(.caption).foregroundStyle(.secondary)
                    Text("Library folder: \(library.folderURL.lastPathComponent)").font(.caption).lineLimit(2)
                    Button("Choose library folder…") { chooseFolder() }
                    Text("Loops save in this library’s Loops folder. Choose the same iCloud Drive library folder on Mac and iPad.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !library.conflicts.isEmpty {
                        Button("Review iCloud versions…") { reviewingConflicts = true }
                    }
                    if !library.recoveredDrafts.isEmpty {
                        Text("Unsaved edits").font(.subheadline.weight(.semibold))
                        recoveryButtons
                    }
                    if let error = library.error { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(20)
            }.background(JamDesign.card).foregroundStyle(JamDesign.text).tint(accent)
        #endif
        }
        .sheet(isPresented: $reviewingConflicts) { LibraryConflictView(library: library) }
        .task { await library.refreshRecoveredDrafts() }
    }

    private var routingLocked: Bool { model.starting || model.hasLoop || model.busy }

    private var audioSummary: String {
        "\(Int(model.sampleRate / 1000)) kHz · " + bufferSummary + " · outputs 1–2 · AM4 live monitoring"
    }

    private var inputPicker: some View {
        Picker("Input", selection: $model.inputUID) {
            if model.input == nil { Text("Choose input…").tag(model.inputUID) }
            ForEach(model.inputs) { Text($0.name).tag($0.uid) }
        }.hoverHighlight()
    }

    private var capturePicker: some View {
        Picker("Capture Channels", selection: $model.inputChannel) {
            ForEach(Array(stride(from: 0, to: max(1, model.input?.inputs ?? 2), by: 2)), id: \.self) { ch in
                Text((model.input?.inputs ?? 2) > ch + 1 ? "Inputs \(ch + 1)–\(ch + 2)" : "Input \(ch + 1)").tag(ch)
            }
        }.hoverHighlight()
    }

    private var retryConnection: some View {
        Button("Retry Connection") { Task { await model.retryAudio() } }
            .disabled(model.input == nil || model.output == nil)
    }

    @ViewBuilder private var audioStatus: some View {
        if let error = model.error {
            Text(error).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityLabel("Audio error: \(error)")
        } else {
            Text(model.starting ? "Connecting audio…" : model.running ? "Audio connected automatically" : "Waiting for an audio interface")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var recoveryButtons: some View {
        ForEach(library.recoveredDrafts) { recovery in
            Button("Recover: " + recovery.draft.title) { recoverDraft(recovery.draft) }
        }
    }
}

private struct MIDIPedalSettings: View {
    @ObservedObject var midi: JamMIDIInput
    var showTitle = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showTitle { Text("MIDI Pedals").font(.subheadline.weight(.semibold)) }
            Text(midi.status).font(.caption).foregroundStyle(.secondary)
            Text("CC22 Arm · CC23 Record / Finish · CC24 Play / Stop\nCC25 Clear · CC26 Drummer Play / Stop")
                .font(.caption).foregroundStyle(.secondary)
            Text("All MIDI inputs and channels · nonzero values trigger; zero releases are ignored")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
