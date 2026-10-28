import Foundation
import AVFoundation

/// Microphone chunks and the Mac's own sound with their host times, saved so the echo gate can be tuned offline
/// on real acoustics (`--selftest echo` records, `--selftest echo-replay` and the tests replay).
public final class EchoRecording {
    private let lock = NSLock()
    public private(set) var mic: [(time: Double, pcm: Data)] = []
    public private(set) var reference: [(time: Double, samples: [Float])] = []

    public init() {}

    public func addMic(_ pcm: Data, time: Double) { lock.lock(); mic.append((time, pcm)); lock.unlock() }
    public func addReference(_ samples: [Float], time: Double) { lock.lock(); reference.append((time, samples)); lock.unlock() }

    public var micPCM: Data { mic.reduce(into: Data()) { $0.append($1.pcm) } }

    public var summary: String {
        lock.lock(); defer { lock.unlock() }
        let refSeconds = Double(reference.reduce(0) { $0 + $1.samples.count }) / EchoGate.sampleRate
        return "\(mic.count) microphone chunks, \(String(format: "%.1f", refSeconds)) s of reference"
    }

    public struct Replay { public var pcm: Data; public var marks: String; public var sent: [Bool] }

    /// Feeds both streams to the gate in time order; returns what the recognizer would get.
    public func replay(through gate: EchoGate) -> Replay {
        lock.lock(); let m = mic, r = reference; lock.unlock()
        var out = Data()
        var sent: [Bool] = []
        var marks = ""
        var ri = 0
        for (time, pcm) in m {
            // Reference delivered up to the end of this chunk (in real time it arrives about as fast).
            while ri < r.count, r[ri].time <= time + 0.08 { gate.addReference(r[ri].samples, time: r[ri].time); ri += 1 }
            let refActive = gate.status != .idle || ri > 0 && r[ri - 1].time > time - 1
            for piece in gate.filter(pcm, time: time) {
                out.append(piece)
                let isSent = piece.contains { $0 != 0 }
                sent.append(isSent)
                marks += !refActive ? "─" : (isSent ? "▮" : "·")
            }
        }
        return Replay(pcm: out, marks: marks, sent: sent)
    }

    /// A copy with `voice` (24 kHz floats) added to the microphone from sample `at`, scaled to `dB` over the
    /// microphone's level after the first two seconds (the echo): the user talking over the playback, digitally.
    public func mixingVoice(_ voice: [Float], at start: Int, overEchoDB dB: Float) -> EchoRecording {
        lock.lock(); let m = mic, r = reference; lock.unlock()
        var pcm: [Float] = m.flatMap { $0.pcm.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32768 } } }
        let tail = pcm.dropFirst(48_000)
        let echoRMS = (tail.reduce(0) { $0 + $1 * $1 } / Float(max(1, tail.count))).squareRoot()
        let voiceRMS = (voice.reduce(0) { $0 + $1 * $1 } / Float(max(1, voice.count))).squareRoot()
        let gain = voiceRMS > 0 ? echoRMS * pow(10, dB / 20) / voiceRMS : 0
        for i in 0..<voice.count where start + i < pcm.count { pcm[start + i] += voice[i] * gain }
        let out = EchoRecording()
        var offset = 0
        for (t, chunk) in m {
            let n = chunk.count / 2
            let samples = pcm[offset..<(offset + n)].map { Int16(max(-32767, min(32767, $0 * 32767))) }
            out.mic.append((t, samples.withUnsafeBufferPointer { Data(buffer: $0) }))
            offset += n
        }
        out.reference = r
        return out
    }

    /// An audio file as 24 kHz mono floats.
    public static func samples(of url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: EchoGate.sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: file.processingFormat, to: out),
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: inBuf)) != nil,
              let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(Double(file.length) * EchoGate.sampleRate / file.processingFormat.sampleRate) + 1024)
        else { return nil }
        var given = false
        conv.convert(to: outBuf, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }

    public func save(to dir: URL) {
        lock.lock(); let m = mic, r = reference; lock.unlock()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var micTimes = "", refTimes = ""
        var micData = Data(), refData = Data()
        for (t, pcm) in m { micTimes += "\(t) \(pcm.count)\n"; micData.append(pcm) }
        for (t, s) in r { refTimes += "\(t) \(s.count)\n"; s.withUnsafeBufferPointer { refData.append(Data(buffer: $0)) } }
        try? micData.write(to: dir.appendingPathComponent("mic.pcm"))
        try? refData.write(to: dir.appendingPathComponent("reference.f32"))
        try? micTimes.write(to: dir.appendingPathComponent("mic-times.txt"), atomically: true, encoding: .utf8)
        try? refTimes.write(to: dir.appendingPathComponent("reference-times.txt"), atomically: true, encoding: .utf8)
    }

    public static func load(from dir: URL) -> EchoRecording? {
        guard let micData = try? Data(contentsOf: dir.appendingPathComponent("mic.pcm")),
              let refData = try? Data(contentsOf: dir.appendingPathComponent("reference.f32")),
              let micTimes = try? String(contentsOf: dir.appendingPathComponent("mic-times.txt"), encoding: .utf8),
              let refTimes = try? String(contentsOf: dir.appendingPathComponent("reference-times.txt"), encoding: .utf8) else { return nil }
        let rec = EchoRecording()
        var offset = 0
        for line in micTimes.split(separator: "\n") {
            let p = line.split(separator: " ")
            guard p.count == 2, let t = Double(p[0]), let n = Int(p[1]), offset + n <= micData.count else { continue }
            rec.mic.append((t, micData.subdata(in: offset..<(offset + n)))); offset += n
        }
        let floats: [Float] = refData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var i = 0
        for line in refTimes.split(separator: "\n") {
            let p = line.split(separator: " ")
            guard p.count == 2, let t = Double(p[0]), let n = Int(p[1]), i + n <= floats.count else { continue }
            rec.reference.append((t, Array(floats[i..<(i + n)]))); i += n
        }
        return rec
    }
}
