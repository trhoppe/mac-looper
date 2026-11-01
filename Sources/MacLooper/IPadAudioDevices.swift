#if os(iOS)
import Foundation
import AVFoundation

enum AudioDevices {
    static let bufferFrames: UInt32 = 32
    static func list() throws -> [AudioDevice] {
        let s = AVAudioSession.sharedInstance()
        let rate = s.sampleRate > 0 ? s.sampleRate : 48000
        let ports = s.availableInputs ?? s.currentRoute.inputs
        let usb = ports.first { $0.portType == .usbAudio }
        let preferred = usb
        var devices = [AudioDevice(id: 1, uid: "ios-default-input", name: preferred?.portName ?? "AM4 / USB input",
                                   inputs: max(1, preferred?.channels?.count ?? 2), outputs: 0, rate: rate)]
        devices += ports.enumerated().map { index, port in
            AudioDevice(id: UInt32(index + 2), uid: port.uid, name: port.portName, inputs: max(1, port.channels?.count ?? 1), outputs: 0, rate: rate)
        }
        devices.append(AudioDevice(id: 0, uid: "ios-system-output", name: s.currentRoute.outputs.map(\.portName).joined(separator: ", ").isEmpty ? "System output" : s.currentRoute.outputs.map(\.portName).joined(separator: ", "), inputs: 0, outputs: max(2, s.outputNumberOfChannels), rate: rate))
        return devices
    }
    static func alive(_ id: UInt32) -> Bool { !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty }
}
#endif
