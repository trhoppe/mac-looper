import SwiftUI
import UniformTypeIdentifiers
import JamCore

extension UTType {
    static let jamLoop = UTType(exportedAs: "com.thoppe.macjams.loop", conformingTo: .data)
}

struct LoopSaveRequest: Identifiable {
    let id: UUID
    let loop: SavedLoop
    let name: String
    let libraryFolder: URL
}

struct LoopRecall: Identifiable {
    let id = UUID()
    let loop: SavedLoop
    let name: String
    var url: URL? = nil
}
