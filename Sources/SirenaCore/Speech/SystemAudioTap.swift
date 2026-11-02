import Foundation
import AppKit
import CoreAudio
import CoreMedia
import ScreenCaptureKit

/// The sound other apps are playing (music, videos, calls), captured with ScreenCaptureKit as 24 kHz mono floats
/// stamped with host time, as the reference for `EchoGate`. Sirena's own audio is left out. It uses the Screen
/// Recording permission the screenshot fallback already needs; no picture is kept (2×2 pixels, ignored).
public final class SystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the tap's queue: samples and the host time (seconds) of the first one.
    public var onSamples: (([Float], Double) -> Void)?
    public var onStopped: ((Error?) -> Void)?
    /// Diagnostics only: include Sirena's own sound.
    public var includeOwnAudio = false
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "ai.sirena.systemaudio", qos: .userInitiated)
    private let stateLock = NSLock()
    private var running = false
    private var starting = false

    public var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return running }
    public var isStarting: Bool { stateLock.lock(); defer { stateLock.unlock() }; return starting }

    public static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    public func start() async throws {
        stateLock.lock()
        if running || starting { stateLock.unlock(); return }
        starting = true
        stateLock.unlock()
        defer { stateLock.lock(); starting = false; stateLock.unlock() }
        guard SystemAudioTap.isPermitted else { throw ExecutionError.failed("Screen Recording permission is needed to tell the Mac's own sound apart") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ExecutionError.failed("No display")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = !includeOwnAudio
        config.sampleRate = Int(EchoGate.sampleRate)
        config.channelCount = 1
        // The picture is not used: as small and as rare as allowed.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stateLock.lock(); stream = s; running = true; stateLock.unlock()
        Log.speech.notice("system audio tap started")
    }

    public func stop() {
        stateLock.lock()
        let s = stream
        stream = nil
        running = false
        stateLock.unlock()
        guard let s else { return }
        s.stopCapture { _ in }
        Log.speech.notice("system audio tap stopped")
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        var samples: [Float] = []
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let first = list.first, let data = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let channels = max(1, Int(first.mNumberChannels))
            let p = data.assumingMemoryBound(to: Float.self)
            // Interleaved stereo (should not happen with channelCount 1): keep the left channel.
            samples = stride(from: 0, to: count, by: channels).map { p[$0] }
        }
        guard !samples.isEmpty, time.isFinite else { return }
        onSamples?(samples, time)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock(); running = false; self.stream = nil; stateLock.unlock()
        Log.speech.error("system audio tap stopped: \(error.localizedDescription, privacy: .public)")
        onStopped?(error)
    }
}

/// Whether other apps are playing sound right now (Core Audio's process objects; no permission needed).
public enum OtherAudio {
    public struct Player: Equatable {
        public let pid: pid_t
        public let name: String
        /// Core Audio's process object.
        public var object: AudioObjectID = 0
    }

    public struct OutputDevice: Equatable {
        public let id: AudioDeviceID
        public let name: String
        /// Loudspeakers the microphone can hear (built-in speakers, displays, AirPlay, speakers without a microphone),
        /// as opposed to headphones (Bluetooth headsets, the headphone jack).
        public let reachesMicrophone: Bool
    }

    /// The output devices an app is playing to.
    public static func outputDevices(of player: Player) -> [OutputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard player.object != 0, AudioObjectGetPropertyDataSize(player.object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(player.object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(describeOutput)
    }

    static func describeOutput(_ id: AudioDeviceID) -> OutputDevice {
        let name = AudioDevices.string(id, kAudioObjectPropertyName)
        let transport: UInt32 = AudioDevices.property(id, kAudioDevicePropertyTransportType, default: 0)
        var reaches: Bool
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // The built-in output is headphones while something is plugged into the jack.
            let source: UInt32 = AudioDevices.property(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, default: 0)
            reaches = source != 0x6864706E   // 'hdpn'
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            // A Bluetooth device with a microphone is a headset (AirPods, earbuds); without one, a speaker.
            reaches = !AudioDevices.inputs().contains { $0.id == id }
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            reaches = false
        default:
            reaches = true   // HDMI / DisplayPort, USB, AirPlay, Thunderbolt speakers
        }
        return OutputDevice(id: id, name: name, reachesMicrophone: reaches)
    }

    /// Processes other than Sirena with audio output running.
    public static func players() -> [Player] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        return ids.compactMap { id in
            let running: UInt32 = AudioDevices.property(id, kAudioProcessPropertyIsRunningOutput, default: 0)
            guard running != 0 else { return nil }
            let pid: pid_t = AudioDevices.property(id, kAudioProcessPropertyPID, default: 0)
            guard pid > 0, pid != me else { return nil }
            var name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? AudioDevices.string(id, kAudioProcessPropertyBundleID)
            // Helpers ("com.google.Chrome.helper") belong to their app.
            if let owner = NSWorkspace.shared.runningApplications.first(where: { app in
                guard let b = app.bundleIdentifier, app.activationPolicy == .regular else { return false }
                return name.hasPrefix(b + ".")
            }) { name = owner.localizedName ?? name }
            return Player(pid: pid, name: name.isEmpty ? "another app" : name, object: id)
        }
    }

    /// The default output device: (id, name, is built-in speakers).
    public static var defaultOutput: (id: AudioDeviceID, name: String, builtIn: Bool) {
        let id: AudioDeviceID = AudioDevices.property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: 0)
        let transport: UInt32 = AudioDevices.property(id, kAudioDevicePropertyTransportType, default: 0)
        return (id, AudioDevices.string(id, kAudioObjectPropertyName), transport == kAudioDeviceTransportTypeBuiltIn)
    }
}
