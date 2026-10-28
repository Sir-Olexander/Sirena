import Foundation
import Accelerate

/// A realistic "music on the Mac while the user talks" scene, built offline (nothing is played): real music from a
/// system ringtone with sung-like "lyrics" from `say` as what the Mac plays; a laptop speaker (mild distortion)
/// and room (30 ms, reflections, 0.3 s reverberation) to the microphone; the user's command from `say`, at a chosen
/// level relative to the echo; room noise. Used by the tests and `--selftest echo-sim` to tune the echo handling.
public enum EchoSimulation {
    public static let musicFile = "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Journey-EncoreInfinitum.m4r"
    public static let lyrics = "Tonight we dance until the morning light, open the door and switch to the other side, scroll down the river, " +
        "send me a message when the stars are bright, we never stop, we never stop, take me to the city, close your eyes and fly."
    public static let command = "Sirena, scroll down."

    public struct Scene {
        public let recording: EchoRecording
        /// Microphone samples (24 kHz) where the user speaks.
        public let voiceRange: Range<Int>
        /// The raw signals: what the Mac played, the microphone, and the user's voice alone as it reaches it.
        public let played: [Float]
        public let mic: [Float]
        public let voice: [Float]
    }

    static func render(_ text: String, voice: String, to path: String) -> [Float]? {
        if !FileManager.default.fileExists(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", voice, "-o", path, text]
            try? p.run()
            p.waitUntilExit()
        }
        return EchoRecording.samples(of: URL(fileURLWithPath: path))
    }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &r, vDSP_Length($0.count)) }
        return r
    }

    static func scaled(_ x: [Float], toRMS target: Float) -> [Float] {
        let r = rms(x[...])
        return r > 0 ? x.map { $0 * target / r } : x
    }

    struct LCG { var s: UInt64; mutating func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: s >> 11) % 2_000_001) / 1_000_000 - 1 } }

    /// Speaker-to-microphone impulse response: delay, direct path, early reflections, decaying reverberation.
    static func roomResponse(delayMs: Double, reverbDB: Float, length: Int = 3600) -> [Float] {
        var h = [Float](repeating: 0, count: length)
        let d = Int(delayMs * 24)
        guard d < length else { return h }
        h[d] = 1
        for (ms, g) in [(3.0, 0.5), (7.0, 0.3), (12.0, 0.22)] where d + Int(ms * 24) < length { h[d + Int(ms * 24)] += Float(g) }
        var rng = LCG(s: 99)
        let tail = pow(10, reverbDB / 20)
        for i in (d + 360)..<length {
            let t = Float(i - d) / 24_000
            h[i] += rng.next() * tail * exp(-6.9 * t / 0.3)   // RT60 0.3 s
        }
        return h
    }

    static func convolve(_ x: [Float], _ h: [Float]) -> [Float] {
        let padded = [Float](repeating: 0, count: h.count - 1) + x
        var out = [Float](repeating: 0, count: x.count)
        let reversed = Array(h.reversed())
        vDSP_conv(padded, 1, reversed, 1, &out, 1, vDSP_Length(x.count), vDSP_Length(h.count))
        return out
    }

    /// - Parameters:
    ///   - voiceOverEchoDB: the user's level in the microphone relative to the echo of the music (nil: no user).
    ///   - echoDBFS: level of the music's echo in the microphone.
    public static func make(seconds: Double = 16, voiceOverEchoDB: Float?, echoDBFS: Float = -30, distortion: Float = 2.2, workDir: String = "/tmp") -> Scene? {
        guard FileManager.default.fileExists(atPath: musicFile),
              let music = EchoRecording.samples(of: URL(fileURLWithPath: musicFile)),
              let sung = render(lyrics, voice: "Samantha", to: workDir + "/sirena-sim-lyrics.aiff"),
              let user = render(command, voice: "Daniel", to: workDir + "/sirena-sim-command.aiff") else { return nil }
        let n = Int(seconds * 24_000)
        guard music.count >= n else { return nil }
        // What the Mac plays: music with a sung line on top, about -18 dBFS.
        var played = scaled(Array(music[(5 * 24_000)..<(5 * 24_000 + n)]), toRMS: 0.08)
        let vocal = scaled(sung, toRMS: 0.08)
        for i in 0..<min(n - 24_000, vocal.count) { played[24_000 + i] += vocal[i] }
        // The laptop speaker distorts a little; the room delays and reverberates.
        let speaker = distortion > 0 ? played.map { tanh(distortion * $0) / distortion } : played
        let echo = scaled(convolve(speaker, roomResponse(delayMs: 30, reverbDB: -14)), toRMS: pow(10, echoDBFS / 20))
        var mic = echo
        var voiceRange = 0..<0
        var voiceAlone = [Float](repeating: 0, count: n)
        if let v = voiceOverEchoDB {
            let near = convolve(user, roomResponse(delayMs: 2, reverbDB: -24, length: 2400))
            let voice = scaled(near, toRMS: pow(10, (echoDBFS + v) / 20) * 1.6)   // speech has pauses: RMS over the words
            let start = 8 * 24_000
            for i in 0..<voice.count where start + i < n { mic[start + i] += voice[i]; voiceAlone[start + i] = voice[i] }
            voiceRange = start..<min(n, start + voice.count)
        }
        var rng = LCG(s: 5)
        for i in 0..<n { mic[i] += rng.next() * 0.0006 }   // room noise, about -66 dBFS
        // Delivered like the app gets it: microphone in 80 ms chunks, reference in 10 ms buffers, same clock.
        let rec = EchoRecording()
        let t0 = 10_000.0
        var i = 0
        while i + 240 <= n { rec.addReference(Array(played[i..<(i + 240)]), time: t0 + Double(i) / 24_000); i += 240 }
        i = 0
        while i + 1920 <= n {
            let pcm = mic[i..<(i + 1920)].map { Int16(max(-32767, min(32767, $0 * 32767))) }
            rec.addMic(pcm.withUnsafeBufferPointer { Data(buffer: $0) }, time: t0 + Double(i) / 24_000)
            i += 1920
        }
        return Scene(recording: rec, voiceRange: voiceRange, played: played, mic: mic, voice: voiceAlone)
    }

    /// Share of echo-only chunks sent (after `settle` seconds) and of the user's chunks sent.
    public static func score(_ sent: [Bool], voiceRange: Range<Int>, settle: Double = 2) -> (leak: Double, voice: Double) {
        let voiceChunks = (voiceRange.lowerBound / 1920)..<max(voiceRange.lowerBound / 1920, voiceRange.upperBound / 1920)
        let echoChunks = (Int(settle / 0.08)..<sent.count).filter { !voiceChunks.contains($0) && !(voiceChunks.upperBound..<(voiceChunks.upperBound + 6)).contains($0) }
        let leak = Double(echoChunks.filter { sent[$0] }.count) / Double(max(1, echoChunks.count))
        let voice = voiceChunks.isEmpty ? 0 : Double(voiceChunks.filter { $0 < sent.count && sent[$0] }.count) / Double(voiceChunks.count)
        return (leak, voice)
    }
}
