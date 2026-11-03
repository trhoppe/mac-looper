/// iPad policy: backgrounding/interruption pauses all transports; reconnecting
/// audio never resumes a song, guitar loop, or drums without a new Play request.
public struct AudioLifecyclePolicy: Sendable {
    public enum Event { case background, foreground, interruptionBegan, interruptionEnded(mayReconnect: Bool), mediaServicesReset, retry }
    public enum Action: Equatable { case none, suspend, reconnect, reset }
    public private(set) var background = false
    public private(set) var interrupted = false
    public private(set) var requiresRetry = false
    public var mayConnect: Bool { !background && !interrupted && !requiresRetry }
    public init() { }
    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .background:
            guard !background else { return .none }
            background = true; return .suspend
        case .foreground:
            background = false; return mayConnect ? .reconnect : .none
        case .interruptionBegan:
            interrupted = true; return .suspend
        case .interruptionEnded(let allowed):
            interrupted = false; requiresRetry = !allowed
            return mayConnect ? .reconnect : .none
        case .mediaServicesReset:
            interrupted = false; requiresRetry = true; return .reset
        case .retry:
            guard !background && !interrupted else { return .none }
            requiresRetry = false; return .reconnect
        }
    }
}
