import SwiftUI
import UniformTypeIdentifiers
import JamCore

extension UTType {
    static let jamLoop = UTType(exportedAs: "com.thoppe.macjams.loop", conformingTo: .data)
}

struct LoopFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.jamLoop] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw LoopFileError.invalid }
        _ = try SavedLoop.decode(data); self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LoopExport: Identifiable {
    let id: UUID
    let document: LoopFileDocument
    let name: String
}

struct LoopRecall: Identifiable {
    let id = UUID()
    let loop: SavedLoop
    let name: String
}
