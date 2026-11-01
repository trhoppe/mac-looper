import Foundation
struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
#if os(iOS)
struct AudioDevice: Identifiable, Equatable, Sendable {
    let id: UInt32
    let uid: String
    let name: String
    let inputs: Int
    let outputs: Int
    let rate: Double
    var isAM4: Bool { name.localizedCaseInsensitiveContains("AM4") }
}
#endif
