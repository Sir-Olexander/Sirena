import Foundation

/// Events coming out of the speech recognizer (realtime or one-shot fallback).
public enum TranscriptEvent: Equatable {
    case connected(sessionId: String)
    case speechStart(turnId: Int)
    /// Cumulative partial: the whole text so far for the active turn.
    case partial(text: String)
    case speechEnd(turnId: Int)
    /// Final text for a turn. `asrLatencyMs` = time from the end of speech audio to this event, when known.
    case final(text: String, turnId: Int, asrLatencyMs: Int?)
    case error(String)
    case disconnected(code: Int, reason: String)
    case reconnecting(attempt: Int)
    /// Realtime access is unavailable; the one-shot fallback took over.
    case fallbackActive
}
