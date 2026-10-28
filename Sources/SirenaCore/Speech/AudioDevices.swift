import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Audio input devices (Core Audio).
public enum AudioDevices {
    public struct Device: Equatable {
        public let id: AudioDeviceID
        public let uid: String
        public let name: String
        public let isBuiltIn: Bool
        public let isBluetooth: Bool
    }

    static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v = value
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : value
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &s) == noErr, let v = s?.takeRetainedValue() else { return "" }
        return v as String
    }

    /// All devices with input channels.
    public static func inputs() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            let transport: UInt32 = property(id, kAudioDevicePropertyTransportType, default: 0)
            return Device(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
                          isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                          isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }

    public static var defaultInput: Device? {
        let id: AudioDeviceID = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: 0)
        return inputs().first { $0.id == id }
    }

    public static func device(uid: String) -> Device? { inputs().first { $0.uid == uid } }

    /// Points an engine's input node at a specific device (before the engine starts).
    @discardableResult
    public static func use(_ device: Device, for engine: AVAudioEngine) -> Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { Log.speech.error("selecting input \(device.name, privacy: .public) failed: \(status)") }
        return status == noErr
    }
}
