import Foundation

public enum SirenaPaths {
    /// ~/Library/Application Support/Sirena, or $SIRENA_DATA_DIR (used by tests and the CLI simulator).
    public static var dataDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["SIRENA_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sirena", isDirectory: true)
    }
}
