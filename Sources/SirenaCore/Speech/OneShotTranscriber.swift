import Foundation

/// Fallback recognizer: detects speech start/end locally (energy-based VAD) and sends each utterance
/// as a WAV to POST /v1/asr/transcribe. Used only when the realtime endpoint is unavailable.
public final class OneShotTranscriber {
    public var onEvent: ((TranscriptEvent) -> Void)?
    public var keywordsProvider: () -> [String] = { [] }
    private let client: MetaAPIClient
    private let queue = DispatchQueue(label: "ai.sirena.oneshot")
    private var buffer = Data()
    private var speechFrames = 0
    private var silenceFrames = 0
    private var inSpeech = false
    private var noiseFloor: Float = 0.01
    private var turnId = 0
    private var preroll: [Data] = []

    public init(client: MetaAPIClient) { self.client = client }

    public func reset() {
        queue.async { [self] in buffer.removeAll(); inSpeech = false; speechFrames = 0; silenceFrames = 0; preroll.removeAll() }
    }

    /// Feed 80 ms PCM chunks.
    public func send(_ pcm: Data, level: Float) {
        queue.async { [self] in
            // adaptive noise floor
            if !inSpeech { noiseFloor = noiseFloor * 0.95 + level * 0.05 }
            let threshold = max(0.035, noiseFloor * 3)
            if level > threshold {
                speechFrames += 1; silenceFrames = 0
                if !inSpeech, speechFrames >= 2 {
                    inSpeech = true
                    turnId += 1
                    buffer = preroll.reduce(Data()) { $0 + $1 }
                    DispatchQueue.main.async { [self, turnId] in onEvent?(.speechStart(turnId: turnId)) }
                }
            } else {
                silenceFrames += 1
                if speechFrames > 0, !inSpeech { speechFrames = 0 }
            }
            if inSpeech {
                buffer.append(pcm)
                if silenceFrames >= 9 || buffer.count > 24_000 * 2 * 30 {   // ~0.7 s of silence or 30 s cap
                    finishUtterance()
                }
            } else {
                preroll.append(pcm)
                if preroll.count > 4 { preroll.removeFirst() }
            }
        }
    }

    private func finishUtterance() {
        let pcm = buffer
        let id = turnId
        buffer.removeAll(); inSpeech = false; speechFrames = 0; silenceFrames = 0
        DispatchQueue.main.async { [self] in onEvent?(.speechEnd(turnId: id)) }
        let endedAt = Date()
        let keywords = keywordsProvider()
        Task {
            do {
                let text = try await client.transcribe(wav: WAV.wrap(pcm: pcm), keywords: keywords)
                let latency = Int(Date().timeIntervalSince(endedAt) * 1000)
                await MainActor.run { onEvent?(.final(text: text, turnId: id, asrLatencyMs: latency)) }
            } catch {
                await MainActor.run { onEvent?(.error(error.localizedDescription)) }
            }
        }
    }
}
