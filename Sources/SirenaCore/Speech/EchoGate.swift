import Foundation
import Accelerate

/// Keeps what the Mac itself plays (music, videos, the other side of a call) out of speech recognition, while the
/// user can still talk over it.
///
/// Apple's voice processing only cancels audio played through Sirena's own engine, and it is off whenever the
/// microphone in use is not the system default. So the sound other apps play is captured as a reference
/// (`SystemAudioTap`). First `EchoCanceller` subtracts the predicted music from the microphone, sample by sample
/// (15–20 dB less echo once it has learned the room): a voice quieter than the music in the microphone survives.
/// Then what is left is compared with the reference every 10 ms, in five frequency bands:
/// * the delay from the reference to the microphone is estimated from their level envelopes;
/// * the coupling (how loud the speakers are in the microphone, per band) is learned as a low percentile of
///   microphone-minus-reference levels, since a voice only ever adds energy;
/// * a chunk where the microphone holds nothing more than the predicted echo (with a reverberation tail) is
///   replaced by silence before it reaches the recognizer. A voice over the music rises above the prediction
///   and passes, with the chunk before it (one chunk of lookahead) so the start of a word is not cut.
/// The recognizer gets the cleaned audio when the gate is open and silence otherwise. While music plays, chunks
/// wait for their stretch of the reference (it arrives up to ~100 ms after the microphone) and one chunk of
/// lookahead: about 160 ms more delay. Without a playing reference every chunk passes untouched and without delay.
public final class EchoGate {
    public static let sampleRate = 24_000.0
    static let frameLength = 240                    // 10 ms
    static let chunkFrames = 8                      // 80 ms, the recognizer's chunk
    static let bandEdges: [Double] = [150, 400, 800, 1600, 3200, 6000]
    static let speechBands = [1, 2, 3]              // 400–3200 Hz
    /// Reference loud enough to count as playing, and microphone loud enough to hold a voice (dB, analyzer scale).
    static let referenceFloor: Float = -70
    static let microphoneFloor: Float = -70
    /// After cancellation, a voice must exceed the predicted leftover echo and room noise by this much (dB, mean
    /// over the speech bands) for 50 ms of a chunk. The leftover is spikier than raw echo (1% of frames ~10 dB over
    /// its median), so the bar is higher than without the canceller; tuned on simulated music (ringtone + sung
    /// lyrics through a laptop speaker and room): no music let through, and a voice 12 dB quieter than the music's
    /// echo still passed 95% (without the canceller it was never heard below -9 dB).
    static let speechExcess: Float = 10
    /// Frames (10 ms) of voice a chunk needs to open the gate.
    static let voiceFramesToOpen = 5
    /// Reference frames ahead of the estimated delay also count (the delay jitters by a frame or two).
    static let leadFrames = 3
    static let tailFrames = 25                      // 250 ms of reverberation
    static let tailDecay: Float = 0.5               // dB per 10 ms
    static let hangoverFrames = 40                  // keep passing 400 ms after a voice (bridges the pause in "Sirena, scroll down")
    static let maxDelayFrames = 50                  // up to 500 ms (Bluetooth speakers)

    public enum Status: String, Equatable { case idle, learning, gating }

    private let lock = NSLock()
    private let analyzer = BandAnalyzer(bandEdges: EchoGate.bandEdges, sampleRate: EchoGate.sampleRate)
    private let canceller = EchoCanceller()
    /// The reference as a continuous stream, by absolute sample index (host time × 24 kHz), last 4 s.
    static let ringSize = 24_000 * 4
    private var ring = [Float](repeating: 0, count: EchoGate.ringSize)
    private var ringEnd: Int?
    /// Microphone chunks waiting for their stretch of the reference, then decided ones waiting for the lookahead.
    private var waiting: [(data: Data, time: Double)] = []
    private var decided: [(data: Data, open: Bool)] = []
    /// Reference band levels by 10 ms slot of host time.
    private var reference: [Int: [Float]] = [:]
    private var referenceRest: [Float] = []
    private var referenceRestTime: Double?
    private var lastReferenceSlot = Int.min
    /// Recent microphone frames (slot, band levels), for the delay estimate.
    private var micHistory: [(slot: Int, bands: [Float])] = []
    private var couplingSamples: [[Float]] = []
    private var coupling: [Float]?
    /// Room noise in the microphone per band (low percentile of recent levels): the echo of a quiet passage can be
    /// below it, and a voice has to stand out from both.
    private var noiseLevels: [[Float]] = []
    private var noiseFloor: [Float]?
    /// Recent frames with a prediction: microphone and reference speech-band levels, and microphone minus reference
    /// per band. Echo follows the reference, a voice does not.
    private var recent: [(mic: Float, ref: Float, diff: [Float])] = []
    /// Added to the learned coupling when louder echo than expected shows up (another source, the volume turned
    /// up); fades by 2 dB a second.
    private var couplingBoost: [Float] = Array(repeating: 0, count: EchoGate.bandEdges.count - 1)
    /// How much the canceller removes per band right now (dB), measured on loud playback without a voice:
    /// the leftover echo is the raw echo (reference + coupling) minus this.
    private var rawEnergy = [Float](repeating: 0, count: EchoGate.bandEdges.count - 1)
    private var residualEnergy = [Float](repeating: 0, count: EchoGate.bandEdges.count - 1)
    private var reduction = [Float](repeating: 0, count: EchoGate.bandEdges.count - 1)
    /// Microphone level that must follow the reference this closely to count as echo, not a voice.
    static let echoCorrelation: Float = 0.8
    private var framesSinceDelayCheck = 0
    private var openUntilSlot = Int.min
    public private(set) var delayFrames = 4
    /// Decision thresholds (tests tune them on recordings).
    var speechExcess = EchoGate.speechExcess
    var voiceFramesToOpen = EchoGate.voiceFramesToOpen
    var hangover = EchoGate.hangoverFrames
    /// Diagnostics: every microphone frame (slot, band levels, predicted echo with coupling, judged a voice).
    var onFrame: ((Int, [Float], [Float]?, Bool) -> Void)?
    public private(set) var gatedChunks = 0
    public private(set) var passedChunks = 0

    public init() {}

    static func slot(_ time: Double) -> Int { Int((time * 100).rounded(.down)) }

    public var status: Status {
        lock.lock(); defer { lock.unlock() }
        guard isReferenceRecent(atSlot: EchoGate.slot(Self.now())) else { return .idle }
        return coupling == nil ? .learning : .gating
    }

    /// Learned coupling per band (dB), for diagnostics.
    public var learnedCoupling: [Float]? { lock.lock(); defer { lock.unlock() }; return coupling }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// What was learned about a microphone and speaker pair, kept so the next playback is silenced from its start.
    public struct Learned: Codable, Equatable {
        public var delayFrames: Int
        public var coupling: [Float]
        /// Measured on a MacBook Air: built-in speakers into the built-in microphone.
        public static let builtInSpeakersAndMic = Learned(delayFrames: 3, coupling: [-30, -22, -23, -21, -30])
    }

    public var learned: Learned? {
        lock.lock(); defer { lock.unlock() }
        return coupling.map { Learned(delayFrames: delayFrames, coupling: zip($0, couplingBoost).map { $0 + $1 }) }
    }

    /// Starts from what was learned before (replaced as soon as enough of the current playback is heard).
    public func seed(_ l: Learned) {
        lock.lock(); defer { lock.unlock() }
        guard l.coupling.count == EchoGate.bandEdges.count - 1 else { return }
        delayFrames = l.delayFrames
        coupling = l.coupling
    }

    /// Forget what was learned (another microphone or output device: the coupling is different).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        reference = [:]; referenceRest = []; referenceRestTime = nil; lastReferenceSlot = .min
        micHistory = []; couplingSamples = []; coupling = nil; delayFrames = 4; openUntilSlot = .min
        ring = [Float](repeating: 0, count: EchoGate.ringSize); ringEnd = nil; waiting = []; decided = []
        canceller.reset()
        noiseLevels = []; noiseFloor = nil; recent = []
        couplingBoost = Array(repeating: 0, count: EchoGate.bandEdges.count - 1)
        rawEnergy = couplingBoost; residualEnergy = couplingBoost; reduction = couplingBoost
    }

    // MARK: Reference

    /// Samples the Mac is playing (24 kHz mono, -1…1); `time` = host time in seconds of the first sample.
    public func addReference(_ samples: [Float], time: Double) {
        lock.lock(); defer { lock.unlock() }
        // Raw stream for the canceller: timestamps jitter by a few samples; only a real gap or jump moves it.
        let start0 = Int((time * EchoGate.sampleRate).rounded())
        var start = start0
        if let end = ringEnd {
            if abs(start0 - end) <= 96 { start = end }
            else if start0 > end, start0 - end < EchoGate.ringSize { for i in end..<start0 { ring[i % EchoGate.ringSize] = 0 } }
        }
        for (i, v) in samples.enumerated() { ring[(start + i) % EchoGate.ringSize] = v }
        ringEnd = start + samples.count
        let expected = referenceRestTime.map { $0 + Double(referenceRest.count) / EchoGate.sampleRate }
        if expected == nil || abs(expected! - time) > 0.05 {
            referenceRest = []
            referenceRestTime = time
        }
        referenceRest += samples
        while referenceRest.count >= EchoGate.frameLength, let t = referenceRestTime {
            let bands = analyzer.levels(referenceRest[0..<EchoGate.frameLength])
            let s = EchoGate.slot(t)
            reference[s] = bands
            lastReferenceSlot = max(lastReferenceSlot, s)
            referenceRest.removeFirst(EchoGate.frameLength)
            referenceRestTime = t + Double(EchoGate.frameLength) / EchoGate.sampleRate
        }
        if reference.count > 600 { reference = reference.filter { $0.key > lastReferenceSlot - 400 } }
    }

    private func isReferenceRecent(atSlot s: Int) -> Bool { lastReferenceSlot > s - delayFrames - 60 }

    /// The reference played over `count` samples from absolute index `start` (silence where it is missing).
    private func referenceSamples(from start: Int, count: Int) -> [Float] {
        guard let end = ringEnd else { return [Float](repeating: 0, count: count) }
        return (start..<(start + count)).map { i in i < end && i >= end - EchoGate.ringSize ? ring[i % EchoGate.ringSize] : 0 }
    }

    /// Drains what is still waiting (tests, or playback stopped).
    public func flush() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        var out: [Data] = []
        drain(into: &out)
        return out
    }

    private func drain(into out: inout [Data]) {
        while let w = waiting.first {
            waiting.removeFirst()
            decide(process(w.data, time: w.time))
        }
        while !decided.isEmpty { emit(decided.removeFirst(), into: &out) }
    }

    private func decide(_ r: (data: Data, open: Bool)) {
        // A voice starting now: the chunk before it goes too (the onset of the word).
        if r.open, let last = decided.indices.last, !decided[last].open { decided[last].open = true }
        decided.append(r)
    }

    private func emit(_ d: (data: Data, open: Bool), into out: inout [Data]) {
        out.append(d.open ? d.data : Data(count: d.data.count))
        if d.open { passedChunks += 1 } else { gatedChunks += 1 }
    }

    /// Learns the room noise from the microphone while nothing plays.
    private func trackNoise(_ chunk: Data) {
        let samples: [Float] = chunk.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
        for f in 0..<(samples.count / EchoGate.frameLength) {
            noiseLevels.append(analyzer.levels(samples[(f * EchoGate.frameLength)..<((f + 1) * EchoGate.frameLength)]))
        }
        if noiseLevels.count > 500 { noiseLevels.removeFirst(noiseLevels.count - 500) }
        if noiseLevels.count >= 10 { noiseFloor = EchoGate.percentile(noiseLevels, 0.1) }
    }

    // MARK: Microphone

    /// One recognizer chunk (Int16 PCM at 24 kHz) starting at host time `time`. Returns what to send, in order:
    /// usually one chunk (cleaned, or silence in place of echo), none or a few around the wait and the lookahead.
    public func filter(_ chunk: Data, time: Double) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        let active = isReferenceRecent(atSlot: EchoGate.slot(time))
        // Nothing playing: pass through at once (learning the room noise meanwhile).
        if !active, waiting.isEmpty, decided.isEmpty {
            micHistory.removeAll(keepingCapacity: true)
            trackNoise(chunk)
            return [chunk]
        }
        var out: [Data] = []
        guard active else {
            // Playback stopped: what is left goes out, then this chunk as is.
            drain(into: &out)
            out.append(chunk)
            return out
        }
        waiting.append((chunk, time))
        // Process the chunks whose stretch of the reference has arrived (or that cannot wait longer).
        while let w = waiting.first {
            let needed = Int((w.time * EchoGate.sampleRate).rounded()) + w.data.count / 2
            guard (ringEnd ?? .min) >= needed || waiting.count > 2 else { break }
            waiting.removeFirst()
            decide(process(w.data, time: w.time))
            while decided.count > 1 { emit(decided.removeFirst(), into: &out) }
        }
        return out
    }

    /// Cancels the echo in one chunk and decides whether it holds a voice.
    private func process(_ chunk: Data, time: Double) -> (data: Data, open: Bool) {
        let firstSlot = EchoGate.slot(time)
        let samples: [Float] = chunk.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
        let frames = samples.count / EchoGate.frameLength
        let base = Int((time * EchoGate.sampleRate).rounded())
        // The canceller learns only while nobody speaks (a voice would teach it to cancel the voice).
        let adapting = firstSlot > openUntilSlot
        var cleaned: [Float] = []
        cleaned.reserveCapacity(samples.count)
        var voiceFrames = 0
        for f in 0..<frames {
            let block = Array(samples[(f * EchoGate.frameLength)..<((f + 1) * EchoGate.frameLength)])
            let ref = referenceSamples(from: base + f * EchoGate.frameLength, count: EchoGate.frameLength)
            let e = canceller.process(mic: block, reference: ref, adapt: adapting)
            cleaned += e
            // The raw microphone gives the speaker-to-microphone coupling and the delay (stable for a device pair);
            // the cleaned signal is what is judged.
            let raw = analyzer.levels(block[...])
            let bands = analyzer.levels(e[...])
            let s = firstSlot + f
            micHistory.append((s, raw))
            let predicted = predictedEcho(atSlot: s)
            let refLevel = predicted.map { mean($0, EchoGate.speechBands) } ?? -200
            // Room noise only where the playback is silent; coupling and the canceller's reduction only on loud
            // playback without a voice.
            if refLevel < EchoGate.referenceFloor { noiseLevels.append(bands) }
            if let p = predicted, refLevel > EchoGate.referenceFloor + 15, coupling == nil || s > openUntilSlot {
                couplingSamples.append(zip(raw, p).map { $0 - $1 })
                for b in raw.indices {
                    rawEnergy[b] = 0.98 * rawEnergy[b] + 0.02 * pow(10, raw[b] / 10)
                    residualEnergy[b] = 0.98 * residualEnergy[b] + 0.02 * pow(10, bands[b] / 10)
                    reduction[b] = residualEnergy[b] > 0 ? max(0, min(30, 10 * log10(rawEnergy[b] / residualEnergy[b]))) : 0
                }
            }
            if let p = predicted {
                let diff = p.indices.map { bands[$0] - p[$0] + reduction[$0] }
                recent.append((mean(bands, EchoGate.speechBands), refLevel, diff))
                if recent.count > 30 { recent.removeFirst(recent.count - 30) }
            }
            couplingBoost = couplingBoost.map { max(0, $0 - 0.02) }
            var voice = isVoice(bands, predicted: predicted)
            if !voice, coupling != nil, s <= openUntilSlot + 30, isHiss(bands, predicted: predicted) {
                voice = true
                openUntilSlot = max(openUntilSlot, s + hangover)
            }
            if voice { voiceFrames += 1 }
            if let onFrame { onFrame(s, bands, predicted.flatMap { p in coupling.map { c in p.indices.map { p[$0] + c[$0] - reduction[$0] } } }, voice) }
        }
        if micHistory.count > 300 { micHistory.removeFirst(micHistory.count - 300) }
        if couplingSamples.count > 400 { couplingSamples.removeFirst(couplingSamples.count - 400) }
        if couplingSamples.count >= 40 { coupling = EchoGate.percentile(couplingSamples, 0.5) }
        if noiseLevels.count > 500 { noiseLevels.removeFirst(noiseLevels.count - 500) }
        if noiseLevels.count >= 10 { noiseFloor = EchoGate.percentile(noiseLevels, 0.1) }
        framesSinceDelayCheck += frames
        if framesSinceDelayCheck >= 50 { framesSinceDelayCheck = 0; updateDelay() }

        let lastSlot = firstSlot + max(frames, 1) - 1
        // Louder than the learned echo but closely following the playback (and no voice heard just before):
        // echo louder than expected (the volume went up), not a voice. Never while a voice is being heard.
        if voiceFrames >= voiceFramesToOpen, firstSlot > openUntilSlot, let base = coupling, recent.count >= 20,
           EchoGate.pearson(recent.map(\.mic), recent.map(\.ref)) > EchoGate.echoCorrelation {
            let observed = EchoGate.percentile(recent.map(\.diff), 0.75)
            let needed = EchoGate.speechBands.map { observed[$0] - base[$0] - couplingBoost[$0] }.reduce(0, +) / Float(EchoGate.speechBands.count)
            if needed <= 10 {
                couplingBoost = couplingBoost.indices.map { b in max(couplingBoost[b], min(12, observed[b] - base[b])) }
                voiceFrames = 0
            }
        }
        // Only a voice heard against a learned echo counts (while learning, everything looks like one, and it
        // must not stop the learning).
        if voiceFrames >= voiceFramesToOpen, coupling != nil { openUntilSlot = lastSlot + hangover }
        // Still learning the coupling: let everything through rather than risk cutting the user.
        let open = coupling == nil || lastSlot <= openUntilSlot
        let pcm = cleaned.map { Int16(max(-32767, min(32767, $0 * 32767))) }
        return (pcm.withUnsafeBufferPointer { Data(buffer: $0) }, open)
    }

    /// How much the canceller currently reduces the echo (dB), for diagnostics.
    public var cancellationDB: Float { lock.lock(); defer { lock.unlock() }; return canceller.enhancementDB }

    /// Echo the microphone would hear at slot `s` from the reference alone (no coupling), with a reverberation tail
    /// and a little slack ahead of the delay.
    private func predictedEcho(atSlot s: Int) -> [Float]? {
        var best: [Float]?
        for k in -EchoGate.leadFrames..<EchoGate.tailFrames {
            guard let r = reference[s - delayFrames - k] else { continue }
            let decayed = r.map { $0 - EchoGate.tailDecay * Float(max(0, k)) }
            best = best.map { zip($0, decayed).map(max) } ?? decayed
        }
        return best
    }

    private func isVoice(_ bands: [Float], predicted: [Float]?) -> Bool {
        guard mean(bands, EchoGate.speechBands) > EchoGate.microphoneFloor else { return false }
        guard let p = predicted, let c = coupling else { return true }
        // What the microphone would hear without a voice: the echo and the room noise together.
        let excess = EchoGate.speechBands.map { b -> Float in
            let echo = p[b] + c[b] + couplingBoost[b] - reduction[b]
            let expected = noiseFloor.map { EchoGate.powerSum(echo, $0[b]) } ?? echo
            return bands[b] - expected
        }
        return excess.reduce(0, +) / Float(excess.count) > speechExcess && excess.filter { $0 > speechExcess - 3 }.count >= 2
    }

    /// Hissing sounds ("s" of "scroll") live above the speech bands. A clear rise there keeps the gate open within a
    /// phrase (shortly after a voice), never opens it on its own: the playback's own "s" sounds would.
    private func isHiss(_ bands: [Float], predicted: [Float]?) -> Bool {
        guard let p = predicted, let c = coupling else { return false }
        let hiss = EchoGate.bandEdges.count - 2
        let hissEcho = p[hiss] + c[hiss] + couplingBoost[hiss] - reduction[hiss]
        let hissExpected = noiseFloor.map { EchoGate.powerSum(hissEcho, $0[hiss]) } ?? hissEcho
        return bands[hiss] - hissExpected > speechExcess + 4 && bands[hiss] > EchoGate.microphoneFloor
    }

    /// The delay (in frames) at which the microphone's level envelope follows the reference's best.
    private func updateDelay() {
        let env = micHistory.map { ($0.slot, mean($0.bands, EchoGate.speechBands)) }
        guard env.count >= 120 else { return }
        func correlation(_ d: Int) -> Float? {
            var xs: [Float] = [], ys: [Float] = []
            for (s, m) in env { if let r = reference[s - d] { xs.append(m); ys.append(mean(r, EchoGate.speechBands)) } }
            guard xs.count >= 100 else { return nil }
            return EchoGate.pearson(xs, ys)
        }
        var best: (d: Int, r: Float)?
        for d in 0...EchoGate.maxDelayFrames { if let r = correlation(d), best == nil || r > best!.r { best = (d, r) } }
        guard let b = best, b.r > 0.5 else { return }
        let current = correlation(delayFrames) ?? -1
        if b.d != delayFrames, b.r > current + 0.03 { delayFrames = b.d }
    }

    static func powerSum(_ a: Float, _ b: Float) -> Float { 10 * log10(pow(10, a / 10) + pow(10, b / 10)) }

    private func mean(_ v: [Float], _ idx: [Int]) -> Float { idx.map { v[$0] }.reduce(0, +) / Float(idx.count) }

    static func percentile(_ rows: [[Float]], _ q: Double) -> [Float] {
        guard let width = rows.first?.count else { return [] }
        return (0..<width).map { b in
            let col = rows.map { $0[b] }.sorted()
            return col[min(col.count - 1, Int(Double(col.count - 1) * q))]
        }
    }

    static func pearson(_ x: [Float], _ y: [Float]) -> Float {
        let n = Float(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for i in 0..<x.count { let a = x[i] - mx, b = y[i] - my; sxy += a * b; sxx += a * a; syy += b * b }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
    }
}

/// Band levels (dB) of a 10 ms frame through a 256-point FFT with a Hann window.
final class BandAnalyzer {
    private let setup: FFTSetup
    private let window: [Float]
    private let bins: [Range<Int>]
    static let log2n: vDSP_Length = 8
    static let size = 256

    init(bandEdges: [Double], sampleRate: Double) {
        setup = vDSP_create_fftsetup(BandAnalyzer.log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: EchoGate.frameLength)
        vDSP_hann_window(&w, vDSP_Length(w.count), Int32(vDSP_HANN_NORM))
        window = w
        let binHz = sampleRate / Double(BandAnalyzer.size)
        bins = zip(bandEdges, bandEdges.dropFirst()).map { lo, hi in max(1, Int(lo / binHz))..<min(BandAnalyzer.size / 2, max(Int(lo / binHz) + 1, Int(hi / binHz))) }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func levels(_ frame: ArraySlice<Float>) -> [Float] {
        var input = [Float](repeating: 0, count: BandAnalyzer.size)
        let n = min(frame.count, window.count)
        for i in 0..<n { input[i] = frame[frame.startIndex + i] * window[i] }
        var real = [Float](repeating: 0, count: BandAnalyzer.size / 2)
        var imag = [Float](repeating: 0, count: BandAnalyzer.size / 2)
        var power = [Float](repeating: 0, count: BandAnalyzer.size / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBufferPointer { inp in
                    inp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: BandAnalyzer.size / 2) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(BandAnalyzer.size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, BandAnalyzer.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(BandAnalyzer.size / 2))
            }
        }
        return bins.map { r in
            let sum = power[r].reduce(0, +) / Float(r.count)
            return 10 * log10(sum / Float(BandAnalyzer.size * BandAnalyzer.size) + 1e-12)
        }
    }
}
