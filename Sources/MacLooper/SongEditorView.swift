import SwiftUI
import JamCore
import UniformTypeIdentifiers

struct SongEditorView: View {
    @StateObject private var editor: SongEditorModel
    private var draft: SongDraft { editor.draft }
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmingDiscard = false
    @State private var exporting = false
    let close: () -> Void
    let save: (SongDraft) async throws -> Void
    init(draft: SongDraft, library: SongLibraryModel, close: @escaping () -> Void, save: @escaping (SongDraft) async throws -> Void) {
        _editor = StateObject(wrappedValue: SongEditorModel(draft: draft, library: library)); self.close = close; self.save = save
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit song").font(.headline)
                Spacer()
                Button("Export ChordPro…") { exporting = true }.disabled(saving)
                Button("Cancel") {
                    if draft.hasChanges { confirmingDiscard = true } else { close() }
                }.disabled(saving).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    saving = true; saveError = nil
                    Task {
                        do { try await save(draft); try await editor.clearRecovery(); close() }
                        catch { saveError = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || !draft.hasChanges || draft.validationError != nil)
            }.padding(18)
            VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        field("Song name", text: $editor.draft.title, prompt: "Song name")
                        field("Artist", text: $editor.draft.artist, prompt: "Artist name")
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 12) {
                        field("Song key", text: $editor.draft.key, prompt: "C, F# or Am")
                        field("BPM", text: $editor.draft.tempo, prompt: "120")
                        field("Time signature", text: $editor.draft.timeSignature, prompt: "4/4")
                        field("Length", text: $editor.draft.duration, prompt: "3:45")
                    }
            }.padding(.horizontal, 18).padding(.bottom, 14).disabled(saving)
            Divider()
            HStack {
                Text("ChordPro").font(.subheadline.weight(.semibold))
                Spacer()
                Text("Details above edit the ChordPro header. Use [C] before a word.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 10)
            ChordProTextEditor(text: $editor.draft.chordPro).disabled(saving).frame(maxWidth: .infinity, maxHeight: .infinity)
            if editor.recovered { Text("Recovered unsaved edits. Review them, then Save or Cancel.").font(.caption).foregroundStyle(.secondary).padding(8) }
            if let message = saveError ?? editor.recoveryError ?? draft.validationError {
                Text(message).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .disabled(editor.recovering)
        .task { await editor.restore() }
        .background(Color(red: 0.065, green: 0.075, blue: 0.085))
        .fileExporter(isPresented: $exporting, document: ChordProExport(text: draft.chordPro), contentType: .plainText,
                      defaultFilename: String(draft.title.map { $0 == "/" || $0 == ":" ? "-" : $0 }) + ".cho") { result in
            if case .failure(let error) = result { saveError = error.localizedDescription }
        }
        .confirmationDialog("Keep these unsaved edits?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Keep draft and close") {
                Task { do { try await editor.keepForLater(); close() } catch { saveError = error.localizedDescription } }
            }
            Button("Discard changes", role: .destructive) {
                Task { do { try await editor.clearRecovery(); close() } catch { saveError = error.localizedDescription } }
            }
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

private struct ChordProExport: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
