import Foundation
import Accelerate

/// Keeps what the Mac itself plays (music, videos, the other side of a call) out of speech recognition.
///
/// Apple's voice processing only cancels audio played through Sirena's own engine, and it is off whenever the
/// microphone in use is not the system default. So the sound other apps play is captured as a reference
/// (`SystemAudioTap`) and compared with the microphone every 10 ms, in five frequency bands:
/// * the delay from the reference to the microphone is estimated from their level envelopes;
/// * the coupling (how loud the speakers are in the microphone, per band) is learned as a low percentile of
///   microphone-minus-reference levels, since a voice only ever adds energy;
/// * a chunk where the microphone holds nothing more than the predicted echo (with a reverberation tail) is
///   replaced by silence before it reaches the recognizer. A voice over the music rises above the prediction
///   and passes, with the chunk before it (one chunk of lookahead) so the start of a word is not cut.
/// Without a playing reference every chunk passes untouched and without delay.
public final class EchoGate {
    public static let sampleRate = 24_000.0
    static let frameLength = 240                    // 10 ms
    static let chunkFrames = 8                      // 80 ms, the recognizer's chunk
    static let bandEdges: [Double] = [150, 400, 800, 1600, 3200, 6000]
    static let speechBands = [1, 2, 3]              // 400–3200 Hz
    /// Reference loud enough to count as playing, and microphone loud enough to hold a voice (dB, analyzer scale).
    static let referenceFloor: Float = -70
    static let microphoneFloor: Float = -70
    /// A voice must exceed the predicted echo and room noise by this much (dB, mean over the speech bands).
    /// Tuned on a real recording (MacBook Air speakers and microphone): 6 dB for 30 ms let no echo through and
    /// passed ~90% of a voice 10 dB over the echo (67% at 6 dB); 10 dB passed only 62% at 10 dB.
    static let speechExcess: Float = 6
    /// Frames (10 ms) of voice a chunk needs to open the gate.
    static let voiceFramesToOpen = 3
    /// Reference frames ahead of the estimated delay also count (the delay jitters by a frame or two).
    static let leadFrames = 3
    static let tailFrames = 25                      // 250 ms of reverberation
    static let tailDecay: Float = 0.5               // dB per 10 ms
    static let hangoverFrames = 40                  // keep passing 400 ms after a voice (bridges the pause in "Sirena, scroll down")
    static let maxDelayFrames = 50                  // up to 500 ms (Bluetooth speakers)

    public enum Status: String, Equatable { case idle, learning, gating }

    private let lock = NSLock()
    private let analyzer = BandAnalyzer(bandEdges: EchoGate.bandEdges, sampleRate: EchoGate.sampleRate)
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
    /// Microphone level that must follow the reference this closely to count as echo, not a voice.
    static let echoCorrelation: Float = 0.6
    private var framesSinceDelayCheck = 0
    private var openUntilSlot = Int.min
    private var held: (data: Data, open: Bool)?
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
        micHistory = []; couplingSamples = []; coupling = nil; delayFrames = 4; held = nil; openUntilSlot = .min
        noiseLevels = []; noiseFloor = nil; recent = []
        couplingBoost = Array(repeating: 0, count: EchoGate.bandEdges.count - 1)
    }

    // MARK: Reference

    /// Samples the Mac is playing (24 kHz mono, -1…1); `time` = host time in seconds of the first sample.
    public func addReference(_ samples: [Float], time: Double) {
        lock.lock(); defer { lock.unlock() }
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

    // MARK: Microphone

    /// One recognizer chunk (Int16 PCM at 24 kHz) starting at host time `time`. Returns what to send: usually one
    /// chunk, silence in place of echo, none or two around the one-chunk lookahead.
    public func filter(_ chunk: Data, time: Double) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        let firstSlot = EchoGate.slot(time)
        // Nothing playing: pass through (the held chunk first, if any).
        guard isReferenceRecent(atSlot: firstSlot) else {
            micHistory.removeAll(keepingCapacity: true)
            var out: [Data] = []
            if let h = held { out.append(h.open ? h.data : Data(count: h.data.count)); held = nil }
            out.append(chunk)
            return out
        }
        let samples: [Float] = chunk.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
        let frames = samples.count / EchoGate.frameLength
        var voiceFrames = 0
        for f in 0..<frames {
            let bands = analyzer.levels(samples[(f * EchoGate.frameLength)..<((f + 1) * EchoGate.frameLength)])
            let s = firstSlot + f
            micHistory.append((s, bands))
            noiseLevels.append(bands)
            let predicted = predictedEcho(atSlot: s)
            if let p = predicted, mean(p, EchoGate.speechBands) > EchoGate.referenceFloor + 15 {
                couplingSamples.append(zip(bands, p).map { $0 - $1 })
            }
            if let p = predicted {
                recent.append((mean(bands, EchoGate.speechBands), mean(p, EchoGate.speechBands), zip(bands, p).map { $0 - $1 }))
                if recent.count > 30 { recent.removeFirst(recent.count - 30) }
            }
            couplingBoost = couplingBoost.map { max(0, $0 - 0.02) }
            var voice = isVoice(bands, predicted: predicted)
            if !voice, s <= openUntilSlot + 30, isHiss(bands, predicted: predicted) {
                voice = true
                openUntilSlot = max(openUntilSlot, s + hangover)
            }
            if voice { voiceFrames += 1 }
            if let onFrame { onFrame(s, bands, predicted.flatMap { p in coupling.map { c in zip(p, c).map { $0 + $1 } } }, voice) }
        }
        if micHistory.count > 300 { micHistory.removeFirst(micHistory.count - 300) }
        if couplingSamples.count > 400 { couplingSamples.removeFirst(couplingSamples.count - 400) }
        if couplingSamples.count >= 40 { coupling = EchoGate.percentile(couplingSamples, 0.5) }
        if noiseLevels.count > 500 { noiseLevels.removeFirst(noiseLevels.count - 500) }
        if noiseLevels.count >= 10 { noiseFloor = EchoGate.percentile(noiseLevels, 0.1) }
        framesSinceDelayCheck += frames
        if framesSinceDelayCheck >= 50 { framesSinceDelayCheck = 0; updateDelay() }

        let lastSlot = firstSlot + max(frames, 1) - 1
        if voiceFrames >= voiceFramesToOpen, let base = coupling, recent.count >= 15,
           EchoGate.pearson(recent.map(\.mic), recent.map(\.ref)) > EchoGate.echoCorrelation {
            // Louder than the learned echo, but rising and falling with the playback: echo, not a voice, as long as
            // the speakers would not have to be implausibly louder than learned (headphones: a voice over a beat).
            let observed = EchoGate.percentile(recent.map(\.diff), 0.75)
            let needed = EchoGate.speechBands.map { observed[$0] - base[$0] - couplingBoost[$0] }.reduce(0, +) / Float(EchoGate.speechBands.count)
            if needed <= 15 {
                couplingBoost = couplingBoost.indices.map { b in max(couplingBoost[b], min(20, observed[b] - base[b])) }
                voiceFrames = 0
            }
        }
        if voiceFrames >= voiceFramesToOpen { openUntilSlot = lastSlot + hangover }
        // Still learning the coupling: let everything through rather than risk cutting the user.
        let open = coupling == nil || lastSlot <= openUntilSlot
        var out: [Data] = []
        if let h = held {
            // A voice starting now: the chunk before it goes too (the onset of the word).
            let send = h.open || open
            out.append(send ? h.data : Data(count: h.data.count))
            if send { passedChunks += 1 } else { gatedChunks += 1 }
        }
        held = (chunk, open)
        return out
    }

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
            let echo = p[b] + c[b] + couplingBoost[b]
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
        let hissEcho = p[hiss] + c[hiss] + couplingBoost[hiss]
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
