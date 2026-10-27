import Foundation
import AVFoundation

/// Captures the microphone and delivers mono 16-bit PCM at 24 kHz in ~80 ms chunks (3840 bytes).
///
/// With `voiceProcessing` on (the default), Apple's voice-processing I/O cleans the signal before it reaches
/// speech recognition: background-noise suppression, automatic gain and echo cancellation. Audio played
/// through `playbackNode` (Sirena reading aloud) is cancelled from the microphone signal. If the device
/// refuses voice processing, capture falls back to the plain input.
public final class AudioCapture {
    public static let sampleRate: Double = 24_000
    public static let chunkBytes = 3840  // 80 ms at 24 kHz, 16-bit mono

    /// Called on an audio thread with each 80 ms chunk.
    public var onChunk: ((Data) -> Void)?
    /// Called on an audio thread with an RMS level in 0...1 (roughly) and the duration it covers, per capture buffer.
    public var onLevel: ((Float, Double) -> Void)?
    /// Called on an audio thread with the raw microphone buffer (native format), for on-device recognition.
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called on the main thread when capture had to restart (device change) or voice processing state changed.
    public var onStatus: ((String) -> Void)?

    /// Use voice processing (noise suppression + echo cancellation) on the next start.
    public var voiceProcessing = true
    public private(set) var voiceProcessingActive = false
    /// Player attached to the capture engine when voice processing is active: its output is echo-cancelled.
    public private(set) var playbackNode: AVAudioPlayerNode?
    public private(set) var playbackFormat: AVAudioFormat?

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pending = Data()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: true)!
    private var observer: NSObjectProtocol?
    private var startedAt = Date.distantPast
    private var restarts: [Date] = []
    public private(set) var isRunning = false
    public private(set) var inputDescription = ""

    public init() {}

    public func start() throws {
        guard !isRunning else { return }
        if voiceProcessing {
            do {
                try startEngine(withVoiceProcessing: true)
                return
            } catch {
                Log.speech.error("voice processing unavailable (\(error.localizedDescription, privacy: .public)); using the plain microphone")
                teardown()
            }
        }
        try startEngine(withVoiceProcessing: false)
    }

    private func startEngine(withVoiceProcessing vp: Bool) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        voiceProcessingActive = false
        if vp {
            try input.setVoiceProcessingEnabled(true)
            // Do not turn other apps (music, calls) down while Sirena listens.
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            input.isVoiceProcessingAGCEnabled = true
            voiceProcessingActive = true
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Sirena.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "Sirena.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot convert microphone format"])
        }
        conv.downmix = true
        converter = conv
        pending.removeAll()
        if vp {
            // Playback through the same voice-processing unit is removed from the microphone signal.
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            playbackNode = player
            playbackFormat = fmt
        } else {
            playbackNode = nil
            playbackFormat = nil
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
        startedAt = Date()
        inputDescription = "\(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch\(vp ? ", noise reduction on" : "")"
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restartAfterConfigChange()
        }
        Log.speech.notice("audio capture started: \(self.inputDescription, privacy: .public)")
    }

    public func stop() {
        guard isRunning else { return }
        teardown()
        Log.speech.notice("audio capture stopped")
    }

    private func teardown() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        engine.inputNode.removeTap(onBus: 0)
        playbackNode?.stop()
        engine.stop()
        if voiceProcessingActive { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        playbackNode = nil
        playbackFormat = nil
        voiceProcessingActive = false
        isRunning = false
    }

    private func restartAfterConfigChange() {
        // Voice processing reconfigures the device right after starting; ignore that, and never loop.
        guard isRunning, Date().timeIntervalSince(startedAt) > 1.5 else { return }
        restarts = restarts.filter { Date().timeIntervalSince($0) < 60 } + [Date()]
        if restarts.count > 3 {
            Log.speech.error("audio configuration keeps changing; restarting without voice processing")
            voiceProcessing = false
        }
        Log.speech.notice("audio configuration changed, restarting capture")
        teardown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            do {
                try self.start()
                self.onStatus?("Microphone changed: \(self.inputDescription)")
            } catch {
                self.onStatus?("Microphone error: \(error.localizedDescription)")
            }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        onBuffer?(buffer)
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let count = Int(out.frameLength)
        let samples = UnsafeBufferPointer(start: ch[0], count: count)
        // Level metering
        var sum: Float = 0
        for s in samples { let f = Float(s) / 32768; sum += f * f }
        let rms = sqrt(sum / Float(max(count, 1)))
        onLevel?(min(1, rms * 6), Double(count) / outFormat.sampleRate)
        // Chunking
        pending.append(UnsafeBufferPointer(start: ch[0], count: count))
        while pending.count >= AudioCapture.chunkBytes {
            let chunk = pending.prefix(AudioCapture.chunkBytes)
            onChunk?(Data(chunk))
            pending.removeFirst(AudioCapture.chunkBytes)
        }
    }
}

extension Data {
    mutating func append(_ samples: UnsafeBufferPointer<Int16>) {
        samples.withMemoryRebound(to: UInt8.self) { bytes in
            append(bytes)
        }
    }
}

/// Builds a 16-bit mono WAV file from raw PCM.
public enum WAV {
    public static func wrap(pcm: Data, sampleRate: Int = Int(AudioCapture.sampleRate)) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
