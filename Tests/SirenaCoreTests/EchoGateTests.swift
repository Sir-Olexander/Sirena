import XCTest
@testable import SirenaCore

/// "When I listen to music or a video, she starts injecting it": the Mac's own sound must not reach the recognizer.
final class EchoGateTests: XCTestCase {
    struct LCG { var s: UInt64; mutating func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: s >> 11) % 2_000_001) / 1_000_000 - 1 } }
    static let sr = 24_000

    /// Music-like reference: chords that change every 300 ms, a beat, some noise, about -20 dBFS.
    static func music(seconds: Double) -> [Float] {
        var rng = LCG(s: 42)
        let n = Int(seconds * Double(sr))
        var out = [Float](repeating: 0, count: n)
        let roots: [Double] = [196, 220, 247, 262, 294, 330, 349, 392]
        for i in 0..<n {
            let t = Double(i) / Double(sr)
            let chord = roots[(i / 7200) % roots.count]
            var v = 0.0
            for (k, mult) in [1.0, 1.25, 1.5, 2.0, 3.0].enumerated() { v += sin(2 * .pi * chord * mult * t) / Double(k + 1) }
            let beat = 0.6 + 0.4 * sin(2 * .pi * 2 * t)
            out[i] = Float(v * beat * 0.06) + rng.next() * 0.01
        }
        return out
    }

    /// Voice-like burst: a 140 Hz pitch with harmonics to 3.5 kHz, formant-weighted.
    static func voice(seconds: Double, level: Float) -> [Float] {
        let n = Int(seconds * Double(sr))
        return (0..<n).map { i in
            let t = Double(i) / Double(sr)
            var v = 0.0
            for h in 1...25 {
                let f = 140.0 * Double(h)
                let w = exp(-pow((f - 700) / 400, 2)) + 0.7 * exp(-pow((f - 1800) / 500, 2)) + 0.4 * exp(-pow((f - 2600) / 500, 2))
                v += w * sin(2 * .pi * f * t + Double(h))
            }
            return Float(v) * level
        }
    }

    /// Runs reference and microphone through the gate in 80 ms steps; returns, per input chunk, whether it was sent.
    func run(reference: [Float]?, mic: [Float], gate: EchoGate = EchoGate()) -> [Bool] {
        let t0 = 5000.0
        let chunk = 1920
        var sent: [Bool] = []
        for c in 0..<(mic.count / chunk) {
            let t = t0 + Double(c) * 0.08
            if let r = reference { gate.addReference(Array(r[(c * chunk)..<min(r.count, (c + 1) * chunk)]), time: t) }
            let pcm = mic[(c * chunk)..<((c + 1) * chunk)].map { Int16(max(-32767, min(32767, $0 * 32767))) }
            let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
            for out in gate.filter(data, time: t) { sent.append(out.contains { $0 != 0 }) }
        }
        return sent
    }

    static func echo(of ref: [Float], delay: Int, gain: Float, noise: Float) -> [Float] {
        var rng = LCG(s: 7)
        return (0..<ref.count).map { i in
            let direct = i >= delay ? ref[i - delay] * gain : 0
            let tail = i >= delay + 2400 ? ref[i - delay - 2400] * gain * 0.3 : 0
            return direct + tail + rng.next() * noise
        }
    }

    func testMusicAloneIsSilencedAndAVoiceOverItPasses() {
        let ref = EchoGateTests.music(seconds: 7)
        var mic = EchoGateTests.echo(of: ref, delay: 1440, gain: 0.3, noise: 0.0005)   // 60 ms, about -30 dBFS
        let voice = EchoGateTests.voice(seconds: 0.8, level: 0.02)
        let start = 5 * EchoGateTests.sr
        for i in 0..<voice.count { mic[start + i] += voice[i] }
        let gate = EchoGate()
        let sent = run(reference: ref, mic: mic, gate: gate)
        XCTAssertTrue((5...7).contains(gate.delayFrames), "delay \(gate.delayFrames)")
        let chunkOf = { (s: Double) in Int(s / 0.08) }
        let musicOnly = Array(sent[chunkOf(1.5)..<chunkOf(4.8)])
        let gatedShare = Double(musicOnly.filter { !$0 }.count) / Double(musicOnly.count)
        XCTAssertGreaterThan(gatedShare, 0.9, "music alone should be silenced: \(gatedShare)")
        let overVoice = Array(sent[chunkOf(5.0)..<chunkOf(5.8)])
        let passedShare = Double(overVoice.filter { $0 }.count) / Double(overVoice.count)
        XCTAssertGreaterThan(passedShare, 0.8, "a voice over the music should pass: \(passedShare)")
    }

    func testLongerDelayIsLearned() {
        let ref = EchoGateTests.music(seconds: 6)
        let mic = EchoGateTests.echo(of: ref, delay: 4800, gain: 0.3, noise: 0.0005)   // 200 ms (Bluetooth speaker)
        let gate = EchoGate()
        let sent = run(reference: ref, mic: mic, gate: gate)
        XCTAssertTrue((19...21).contains(gate.delayFrames), "delay \(gate.delayFrames)")
        let tail = Array(sent[Int(2.5 / 0.08)...])
        XCTAssertGreaterThan(Double(tail.filter { !$0 }.count) / Double(tail.count), 0.9)
    }

    func testHeadphonesNoEchoTheVoicePasses() {
        let ref = EchoGateTests.music(seconds: 6)
        var rng = LCG(s: 3)
        var mic = (0..<ref.count).map { _ in rng.next() * 0.0005 }
        let voice = EchoGateTests.voice(seconds: 0.8, level: 0.01)
        let start = 4 * EchoGateTests.sr
        for i in 0..<voice.count { mic[start + i] += voice[i] }
        let sent = run(reference: ref, mic: mic)
        let overVoice = Array(sent[Int(4.1 / 0.08)..<Int(4.7 / 0.08)])
        XCTAssertTrue(overVoice.allSatisfy { $0 }, "\(overVoice)")
    }

    func testNothingPlayingPassesEverythingAtOnce() {
        let gate = EchoGate()
        let data = Data(repeating: 1, count: 3840)
        XCTAssertEqual(gate.filter(data, time: 100), [data])
        XCTAssertEqual(gate.filter(data, time: 100.08), [data])
        XCTAssertEqual(gate.status, .idle)
    }

    func testASongHeardAsTheWakePhraseOnlyWakes() {
        let waiting = RouterContext(state: .waiting)
        XCTAssertEqual(UtteranceRouter.route("Hey Sirena, to my party in the club I'm so and everybody knows I get off the chain baby", context: waiting), .wake)
        XCTAssertEqual(UtteranceRouter.route("Hey Sirena, switch to Chrome.", context: waiting), .wakeWithCommand("switch to Chrome."))
        XCTAssertEqual(UtteranceRouter.route("Hey Sirena, what is the weather like in Lisbon this afternoon please", context: waiting),
                       .wakeWithCommand("what is the weather like in Lisbon this afternoon please"))
    }
}

extension EchoGateTests {
    /// What was learned is kept per device pair: a seeded gate silences playback from its first chunks.
    func testASeededGateSilencesFromTheStart() {
        let ref = EchoGateTests.music(seconds: 3)
        let mic = EchoGateTests.echo(of: ref, delay: 1440, gain: 0.3, noise: 0.0005)
        let learner = EchoGate()
        _ = run(reference: ref, mic: mic, gate: learner)
        guard let learned = learner.learned else { return XCTFail("nothing learned") }
        let seeded = EchoGate()
        seeded.seed(learned)
        let sent = run(reference: ref, mic: mic, gate: seeded)
        // After the noise floor settles (0.5 s), nothing of the music goes out.
        let early = Array(sent[7..<20])
        XCTAssertTrue(early.allSatisfy { !$0 }, "\(early)")
        XCTAssertEqual(EchoGate.Learned.builtInSpeakersAndMic.coupling.count, EchoGate.bandEdges.count - 1)
    }
}

/// "When the music is playing, Sirena also doesn't listen to me": the music is subtracted, the voice is kept.
final class EchoCancellerTests: XCTestCase {
    func testCancelsTheEchoAndKeepsTheVoice() {
        let music = EchoGateTests.music(seconds: 5)
        // Speaker to microphone: 30 ms, two reflections, louder than the voice.
        let echo: [Float] = (0..<music.count).map { i in
            var v: Float = 0
            for (d, g) in [(720, 0.4), (1000, 0.15), (1300, 0.08)] as [(Int, Float)] where i >= d { v += music[i - d] * g }
            return v
        }
        let voice = EchoGateTests.voice(seconds: 0.8, level: 0.006)
        let start = 4 * 24_000
        let aec = EchoCanceller(partitions: 8)
        var out = [Float](), voiceOut = [Float](), voiceIn = [Float]()
        var b = 0
        while (b + 1) * 240 <= music.count {
            let r = (b * 240)..<((b + 1) * 240)
            let v = r.map { $0 >= start && $0 - start < voice.count ? voice[$0 - start] : Float(0) }
            let mic = (0..<240).map { echo[r.lowerBound + $0] + v[$0] }
            let e = aec.process(mic: mic, reference: Array(music[r]), adapt: r.lowerBound < start)
            out += e
            if r.lowerBound >= start, r.lowerBound + 240 <= start + voice.count { voiceOut += zip(e, mic).map { $0.0 }; voiceIn += v }
            b += 1
        }
        func db(_ x: ArraySlice<Float>) -> Float { 10 * log10(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)) + 1e-12) }
        let before = db(echo[(3 * 24_000)..<start]), after = db(out[(3 * 24_000)..<start])
        XCTAssertGreaterThan(before - after, 15, "echo reduced by \(before - after) dB")
        // During the voice, what is left is mostly the voice.
        let leftover = zip(voiceOut, voiceIn).map { $0 - $1 }
        XCTAssertGreaterThan(db(voiceIn[...]) - db(leftover[...]), 6)
        XCTAssertEqual(aec.resets, 0)
    }
}
