import Foundation

/// Decides what microphone audio goes to the Meta recognizer.
///
/// * `live`: every chunk is sent as captured.
/// * `private`: zeros are sent instead (the session stays open, so waking is instant), and the real audio of the
///   last few seconds is kept locally. When the on-device detector hears "Hey Sirena", `goLive(replay: true)`
///   sends that pre-roll first, so "Hey Sirena, switch to Chrome" said in one breath is transcribed in full.
///
/// Thread-safe: `process` runs on the audio thread, the rest on the main thread.
public final class StreamGate {
    private let lock = NSLock()
    private var isPrivate = false
    private var ring: [Data] = []
    private var pendingReplay: [Data] = []
    /// ~3 s of 80 ms chunks; well under the 5 s backlog limit of the realtime endpoint.
    private let maxRing = 38

    public init() {}

    public var privateMode: Bool { lock.lock(); defer { lock.unlock() }; return isPrivate }

    public func goPrivate() {
        lock.lock(); defer { lock.unlock() }
        isPrivate = true
        ring.removeAll()
        pendingReplay.removeAll()
    }

    public func goLive(replay: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isPrivate, replay { pendingReplay = ring }
        isPrivate = false
        ring.removeAll()
    }

    /// Returns the chunks to send for one captured chunk.
    public func process(_ pcm: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        if isPrivate {
            ring.append(pcm)
            if ring.count > maxRing { ring.removeFirst(ring.count - maxRing) }
            return [Data(count: pcm.count)]
        }
        if !pendingReplay.isEmpty {
            let out = pendingReplay + [pcm]
            pendingReplay.removeAll()
            return out
        }
        return [pcm]
    }
}
