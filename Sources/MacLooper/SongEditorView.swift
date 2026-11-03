import SwiftUI
import JamCore

struct SongEditorView: View {
    @State private var draft: SongDraft
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmingDiscard = false
    let close: () -> Void
    let save: (SongDraft) async throws -> Void
    init(draft: SongDraft, close: @escaping () -> Void, save: @escaping (SongDraft) async throws -> Void) {
        _draft = State(initialValue: draft); self.close = close; self.save = save
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit song").font(.headline)
                Spacer()
                Button("Cancel") {
                    if draft.hasChanges { confirmingDiscard = true } else { close() }
                }.disabled(saving).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    saving = true; saveError = nil
                    Task {
                        do { try await save(draft); close() }
                        catch { saveError = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || !draft.hasChanges || draft.validationError != nil)
            }.padding(18)
            VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        field("Song name", text: $draft.title, prompt: "Song name")
                        field("Artist", text: $draft.artist, prompt: "Artist name")
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 12) {
                        field("Song key", text: $draft.key, prompt: "C, F# or Am")
                        field("BPM", text: $draft.tempo, prompt: "120")
                        field("Time signature", text: $draft.timeSignature, prompt: "4/4")
                        field("Length", text: $draft.duration, prompt: "3:45")
                    }
            }.padding(.horizontal, 18).padding(.bottom, 14).disabled(saving)
            Divider()
            HStack {
                Text("ChordPro").font(.subheadline.weight(.semibold))
                Spacer()
                Text("Details above edit the ChordPro header. Use [C] before a word.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 10)
            ChordProTextEditor(text: $draft.chordPro).disabled(saving).frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = saveError ?? draft.validationError {
                Text(message).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .background(Color(red: 0.065, green: 0.075, blue: 0.085))
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { close() }
            Button("Keep editing", role: .cancel) { }
        }

    }
    private func field(_ name: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(name)
        }
    }
}
