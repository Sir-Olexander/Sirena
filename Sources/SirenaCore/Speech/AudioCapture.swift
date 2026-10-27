import Foundation
import AVFoundation

/// Captures the microphone and delivers mono 16-bit PCM at 24 kHz in ~80 ms chunks (3840 bytes).
public final class AudioCapture {
    public static let sampleRate: Double = 24_000
    public static let chunkBytes = 3840  // 80 ms at 24 kHz, 16-bit mono

    /// Called on an audio thread with each 80 ms chunk.
    public var onChunk: ((Data) -> Void)?
    /// Called on an audio thread with an RMS level in 0...1 (roughly) per chunk.
    public var onLevel: ((Float) -> Void)?
    /// Called on an audio thread with the raw microphone buffer (native format), for on-device recognition.
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pending = Data()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: true)!
    private var observer: NSObjectProtocol?
    public private(set) var isRunning = false

    public init() {}

    public func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Sirena.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "Sirena.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot convert microphone format"])
        }
        converter = conv
        pending.removeAll()
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartAfterConfigChange()
        }
        Log.speech.info("audio capture started: \(inFormat.sampleRate, privacy: .public) Hz, \(inFormat.channelCount, privacy: .public) ch")
    }

    public func stop() {
        guard isRunning else { return }
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        Log.speech.info("audio capture stopped")
    }

    private func restartAfterConfigChange() {
        Log.speech.notice("audio configuration changed, restarting capture")
        let wasRunning = isRunning
        stop()
        if wasRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                try? self?.start()
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
        onLevel?(min(1, rms * 6))
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
