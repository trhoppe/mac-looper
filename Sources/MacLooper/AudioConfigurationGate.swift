import Foundation

/// FIFO ownership of graph mutations. Waiting yields the main actor; no polling
/// and no work is added to the audio callback. Cancelled waiters pass ownership on.
@MainActor final class AudioConfigurationGate {
    private var owned = false
    var waitingCount: Int { waiters.count }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async throws {
        if owned { await withCheckedContinuation { waiters.append($0) } }
        else { owned = true }
        if Task.isCancelled { release(); throw CancellationError() }
    }
    func release() {
        if waiters.isEmpty { owned = false }
        else { waiters.removeFirst().resume() }
    }
}
