#if os(iOS)
import Foundation
import AVFoundation

/// Own notifications at the session level, independently of chart/remote views.
@MainActor final class IPadAudioLifecycle {
    private var observers: [NSObjectProtocol] = []
    init(model: LooperModel, files: AudioFilePlayerModel) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak model, weak files] notification in
            let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor in
                guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { files?.pauseForInterruption(); model?.handleAudioLifecycle(.interruptionBegan) }
                else { model?.handleAudioLifecycle(.interruptionEnded(mayReconnect: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))) }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak model, weak files] _ in
            Task { @MainActor in files?.pauseForInterruption(); model?.handleAudioLifecycle(.mediaServicesReset) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak model, weak files] notification in
            let raw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            // Category/preferred-input changes caused by our own setup are not
            // disconnects. React only to physical route changes.
            guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
            Task { @MainActor in
                files?.pauseForInterruption(); model?.refreshDevices()
                model?.handleAudioLifecycle(.interruptionBegan)
                model?.handleAudioLifecycle(.interruptionEnded(mayReconnect: true))
            }
        })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
#endif
