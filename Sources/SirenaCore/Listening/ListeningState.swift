import Foundation

/// The three top-level listening states.
public enum ListeningState: String, Codable {
    /// Not listening, microphone closed.
    case off
    /// Streaming, but only "Hey Sirena" is acted on.
    case waiting
    /// Listening continuously; each pause ends an utterance.
    case awake
}
