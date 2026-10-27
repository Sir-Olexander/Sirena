import Foundation
import AVFoundation
import NaturalLanguage

/// Reads text aloud with on-device voices.
///
/// Speech is synthesized sentence by sentence (`AVSpeechSynthesizer.write`) and played through an
/// `AVAudioPlayerNode`. When the microphone runs with voice processing, that player lives in the capture engine,
/// so the echo canceller removes Sirena's own voice from the microphone signal. `isLikelyEcho` is a second
/// line of defence: transcripts that match the sentences being read are ignored.
public final class ReadAloud {
    public enum State: Equatable { case idle, reading, paused }

    public private(set) var state: State = .idle
    /// Main thread: state, title, progress 0…1.
    public var onChange: ((State, String?, Double) -> Void)?
    /// Echo-cancelled player and its format, when the capture engine provides one.
    public var playbackProvider: () -> (AVAudioPlayerNode, AVAudioFormat)? = { nil }

    private let synth = AVSpeechSynthesizer()
    private var ownEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var sentences: [String] = []
    private var playing = 0
    private var synthesized = 0
    private var synthesizing = false
    private var generation = 0
    private var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var voice: AVSpeechSynthesisVoice?
    private var title: String?
    private var stoppedAt = Date.distantPast
    private var converters: [String: AVAudioConverter] = [:]

    public init() {}

    public var isActive: Bool { state != .idle }
    /// Shortly after reading stops, the tail of Sirena's voice can still arrive as a transcript.
    public var recentlyActive: Bool { isActive || Date().timeIntervalSince(stoppedAt) < 3 }
    public var progress: Double { sentences.isEmpty ? 0 : Double(playing) / Double(sentences.count) }

    // MARK: - Control

    public func read(_ text: String, title: String? = nil) {
        stop(notify: false)
        let parts = ReadAloud.sentences(in: text)
        guard !parts.isEmpty else { return }
        sentences = parts
        self.title = title
        playing = 0
        synthesized = 0
        voice = ReadAloud.bestVoice(for: text)
        guard preparePlayer() else { Log.speech.error("read aloud: no audio output"); return }
        generation += 1
        state = .reading
        player?.play()
        notify()
        synthesizeNext()
        Log.speech.notice("reading \(parts.count) sentences, voice \(self.voice?.identifier ?? "default", privacy: .public)")
    }

    public func control(_ c: ReadingControl) {
        switch c {
        case .stop: stop()
        case .pause:
            guard state == .reading else { return }
            player?.pause()
            state = .paused
            notify()
        case .resume:
            guard state == .paused else { return }
            player?.play()
            state = .reading
            notify()
        case .faster: changeRate(by: 0.07)
        case .slower: changeRate(by: -0.07)
        }
    }

    public func stop() { stop(notify: true) }

    private func stop(notify shouldNotify: Bool) {
        guard state != .idle else { return }
        generation += 1
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        synthesizing = false
        state = .idle
        stoppedAt = Date()
        if let e = ownEngine { e.stop(); ownEngine = nil }
        if shouldNotify { notify() }
    }

    private func changeRate(by delta: Float) {
        rate = min(0.66, max(0.3, rate + delta))
        guard state != .idle else { return }
        // Restart the current sentence at the new speed.
        generation += 1
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        synthesizing = false
        synthesized = playing
        if state == .paused { state = .reading }
        player?.play()
        notify()
        synthesizeNext()
    }

    private func notify() { onChange?(state, title, progress) }

    // MARK: - Synthesis and playback

    private func preparePlayer() -> Bool {
        if let (p, f) = playbackProvider() {
            player = p; format = f
            return true
        }
        let engine = AVAudioEngine()
        let p = AVAudioPlayerNode()
        engine.attach(p)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let f = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1)!
        engine.connect(p, to: engine.mainMixerNode, format: f)
        do { try engine.start() } catch { return false }
        ownEngine = engine
        player = p; format = f
        return true
    }

    private func synthesizeNext() {
        guard state != .idle, !synthesizing, synthesized < sentences.count, synthesized - playing < 2 else { return }
        synthesizing = true
        let index = synthesized
        let gen = generation
        let utterance = AVSpeechUtterance(string: sentences[index])
        utterance.voice = voice
        utterance.rate = rate
        utterance.postUtteranceDelay = 0
        synth.write(utterance) { [weak self] buffer in
            DispatchQueue.main.async {
                guard let self, gen == self.generation, let player = self.player, let format = self.format,
                      let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // End of this sentence: a short pause, then report it finished.
                    let pauseFrames = AVAudioFrameCount(format.sampleRate * 0.18)
                    if let gap = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: pauseFrames) {
                        gap.frameLength = pauseFrames
                        player.scheduleBuffer(gap) { [weak self] in
                            DispatchQueue.main.async { self?.sentenceFinished(index, gen: gen) }
                        }
                    }
                    self.synthesizing = false
                    self.synthesized = index + 1
                    self.synthesizeNext()
                    return
                }
                if let converted = self.convert(pcm, to: format) { player.scheduleBuffer(converted) }
            }
        }
    }

    private func sentenceFinished(_ index: Int, gen: Int) {
        guard gen == generation, state != .idle else { return }
        playing = index + 1
        if playing >= sentences.count {
            stop()
            return
        }
        notify()
        synthesizeNext()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let key = "\(buffer.format.sampleRate)-\(buffer.format.channelCount)-\(buffer.format.commonFormat.rawValue)-\(buffer.format.isInterleaved)"
        let conv: AVAudioConverter
        if let c = converters[key] { conv = c }
        else {
            guard let c = AVAudioConverter(from: buffer.format, to: format) else { return nil }
            converters[key] = c
            conv = c
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : out
    }

    // MARK: - Echo filter

    /// True when `transcript` is most likely the microphone hearing Sirena read.
    public func isLikelyEcho(_ transcript: String) -> Bool {
        guard recentlyActive, !sentences.isEmpty else { return false }
        let lo = max(0, playing - 3), hi = min(sentences.count - 1, playing + 2)
        guard lo <= hi else { return false }
        let window = Set(WakeWord.normalize(sentences[lo...hi].joined(separator: " ")).split(separator: " ").map(String.init))
        let tokens = WakeWord.normalize(transcript).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return false }
        // The user addressing Sirena by name, when the text being read does not contain her name, is not an echo.
        if WakeWord.startsWithName(transcript), !window.contains(where: { WakeWord.nameVariants.contains($0) }) { return false }
        let matched = tokens.filter { window.contains($0) }.count
        if tokens.count <= 2 { return matched == tokens.count }
        return Double(matched) / Double(tokens.count) >= 0.6
    }

    // MARK: - Helpers

    static func sentences(in text: String) -> [String] {
        let cleaned = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleaned
        var out: [String] = []
        tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            let s = cleaned[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return true }
            // Split very long sentences at commas or semicolons so speed changes and stops react quickly.
            if s.count > 280 {
                var current = ""
                for part in s.components(separatedBy: CharacterSet(charactersIn: ",;")) {
                    if current.count + part.count > 200, !current.isEmpty { out.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                    current += (current.isEmpty ? "" : ",") + part
                }
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current.trimmingCharacters(in: .whitespaces)) }
            } else {
                out.append(s)
            }
            return true
        }
        return out
    }

    /// The best installed voice for the text's language (premium > enhanced > default), preferring the user's region.
    public static func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        let lang = recognizer.dominantLanguage?.rawValue ?? "en"
        let base = String(lang.prefix(2))
        let region = Locale.current.region?.identifier ?? "US"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(base) }
        guard !voices.isEmpty else { return AVSpeechSynthesisVoice(language: "en-US") }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            switch v.quality {
            case .premium: s += 300
            case .enhanced: s += 200
            default: s += 100
            }
            if v.language.hasSuffix(region) { s += 50 }
            if base == "en", v.language == "en-US" { s += 20 }
            if base == "pt", v.language == "pt-PT", region == "PT" { s += 20 }
            // Novelty voices sound wrong for reading articles.
            if v.identifier.contains("eloquence") || v.identifier.contains("speech.synthesis.voice") && !v.identifier.contains("compact") && v.quality == .default { s -= 30 }
            return s
        }
        return voices.max { score($0) < score($1) }
    }
}
