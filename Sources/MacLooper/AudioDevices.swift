import Foundation
#if os(macOS)
import CoreAudio

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputs: Int
    let outputs: Int
    let rate: Double
    var isAM4: Bool { name.caseInsensitiveCompare("AM4") == .orderedSame }
}

// All discovery and configuration happens on the main actor, outside the audio callback.
enum AudioDevices {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw AudioFailure(message: "\(action) (Core Audio \(status)).") }
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr,
              let value else { return "" }
        return value.takeRetainedValue() as String
    }
    static func number<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, fallback: T) -> T {
        var a = address(selector), value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        _ = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        return value
    }
    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var a = address(selector), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size), "Read audio devices")
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if size > 0 { try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, &result), "Read audio devices") }
        return result
    }
    static func channels(_ id: AudioObjectID, input: Bool) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration,
                        input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, pointer) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func device(_ id: AudioObjectID) -> AudioDevice {
        AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID),
                    name: string(id, kAudioObjectPropertyName), inputs: channels(id, input: true),
                    outputs: channels(id, input: false),
                    rate: number(id, kAudioDevicePropertyNominalSampleRate, fallback: 0.0))
    }
    static func list() throws -> [AudioDevice] {
        try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
            .map(device).filter { !$0.uid.hasPrefix("local.maclooper.route.") && !$0.uid.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static let bufferFrames: UInt32 = 32
    static func require32Frames(_ id: AudioObjectID, name: String) throws {
        var a = address(kAudioDevicePropertyBufferFrameSizeRange)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, &range), "Read \(name) buffer limits")
        guard range.mMinimum <= Double(bufferFrames), range.mMaximum >= Double(bufferFrames) else {
            throw AudioFailure(message: "\(name) does not support a 32-sample buffer (range \(Int(range.mMinimum))–\(Int(range.mMaximum))).")
        }
        a.mSelector = kAudioDevicePropertyBufferFrameSize
        var frames = bufferFrames
        if number(id, kAudioDevicePropertyBufferFrameSize, fallback: UInt32(0)) != frames {
            try check(AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames), "Set \(name) to 32 samples")
        }
        guard number(id, kAudioDevicePropertyBufferFrameSize, fallback: UInt32(0)) == bufferFrames else {
            throw AudioFailure(message: "\(name) did not accept 32 samples. Audio was not started.")
        }
    }
    static func alive(_ id: AudioObjectID) -> Bool {
        number(id, kAudioDevicePropertyDeviceIsAlive, fallback: UInt32(0)) != 0
    }

    struct Route {
        let device: AudioDeviceID
        let aggregate: AudioDeviceID?
        let inputOffset: Int
        let outputOffset: Int
        let inputs: Int
        let outputs: Int
        let rate: Double
    }
    @MainActor static func route(input: AudioDevice, output: AudioDevice) async throws -> Route {
        guard alive(input.id), alive(output.id) else { throw AudioFailure(message: "The selected audio device is disconnected.") }
        guard input.rate >= 8000, input.rate <= 192000, abs(input.rate - output.rate) < 0.1 else {
            throw AudioFailure(message: "Set both devices to the same sample rate in Audio MIDI Setup, then try again. AM4 uses 48 kHz.")
        }
        try require32Frames(input.id, name: input.name)
        if input.id != output.id { try require32Frames(output.id, name: output.name) }
        if input.id == output.id {
            return Route(device: input.id, aggregate: nil, inputOffset: 0, outputOffset: 0,
                         inputs: input.inputs, outputs: output.outputs, rate: output.rate)
        }
        // Core Audio performs drift compensation between different hardware clocks.
        // Private aggregate is destroyed on route changes, errors, and app exit. No system default changes.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mac Jams Session",
            kAudioAggregateDeviceUIDKey: "local.maclooper.route.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: input.uid, kAudioSubDeviceDriftCompensationKey: 1,
                 kAudioSubDeviceDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality] as [String: Any],
                [kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceDriftCompensationKey: 0] as [String: Any]
            ]
        ]
        var aggregate: AudioDeviceID = 0
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "Connect input and output")
        do {
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                let active = (try? ids(aggregate, kAudioAggregateDevicePropertyActiveSubDeviceList)) ?? []
                if active.contains(input.id), active.contains(output.id) {
                    var inputOffset = 0, outputOffset = 0
                    for id in active.prefix(while: { $0 != input.id }) { inputOffset += channels(id, input: true) }
                    for id in active.prefix(while: { $0 != output.id }) { outputOffset += channels(id, input: false) }
                    let current = device(aggregate)
                    if current.inputs >= inputOffset + input.inputs,
                       current.outputs >= outputOffset + output.outputs,
                       abs(current.rate - output.rate) < 0.1 {
                        try require32Frames(aggregate, name: "Mac Jams audio route")
                        return Route(device: aggregate, aggregate: aggregate, inputOffset: inputOffset,
                                     outputOffset: outputOffset, inputs: current.inputs, outputs: current.outputs, rate: current.rate)
                    }
                }
            }
            throw AudioFailure(message: "The devices could not share an audio clock. Check Audio MIDI Setup and try again.")
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregate)
            throw error
        }
    }
}

#endif
