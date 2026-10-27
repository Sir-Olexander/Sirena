import Foundation
import os

/// Unified logging. View with:
///   log stream --predicate 'subsystem == "ai.sirena.app"' --level debug
public enum Log {
    public static let subsystem = "ai.sirena.app"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let listening = Logger(subsystem: subsystem, category: "listening")
    public static let commands = Logger(subsystem: subsystem, category: "commands")
    public static let model = Logger(subsystem: subsystem, category: "model")
    public static let context = Logger(subsystem: subsystem, category: "context")
    public static let overlay = Logger(subsystem: subsystem, category: "overlay")
}
