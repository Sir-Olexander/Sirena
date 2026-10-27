import Foundation

/// The user's existing Apple Shortcuts, through the `shortcuts` command-line tool.
public enum AppleShortcuts {
    private static var cache: (names: [String], at: Date)?
    private static let lock = NSLock()

    /// Names of the user's shortcuts (cached for a minute).
    public static func names() -> [String] {
        lock.lock()
        if let c = cache, Date().timeIntervalSince(c.at) < 60 { lock.unlock(); return c.names }
        lock.unlock()
        let out = run(["list"], timeout: 8).output
        let names = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        lock.lock(); cache = (names, Date()); lock.unlock()
        return names
    }

    /// Best name match for a spoken shortcut name.
    public static func match(_ spoken: String) -> String? {
        let all = names()
        if let exact = all.first(where: { WakeWord.normalize($0) == WakeWord.normalize(spoken) }) { return exact }
        return Fuzzy.best(spoken, in: all, name: { $0 }, threshold: 0.78)?.item
    }

    /// Runs a shortcut by name. Returns its text output, if any.
    @discardableResult
    public static func runShortcut(_ name: String, input: String? = nil) throws -> String {
        var args = ["run", name]
        var inputFile: URL?
        if let input {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sirena-shortcut-input-\(UUID().uuidString).txt")
            try? input.write(to: url, atomically: true, encoding: .utf8)
            args += ["--input-path", url.path]
            inputFile = url
        }
        defer { if let f = inputFile { try? FileManager.default.removeItem(at: f) } }
        let r = run(args, timeout: 60)
        if r.status != 0 {
            throw ExecutionError.failed("Shortcut “\(name)” failed\(r.error.isEmpty ? "" : ": \(r.error.prefix(120))")")
        }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(_ args: [String], timeout: TimeInterval) -> (status: Int32, output: String, error: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return (-2, "", "timed out") }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, o, e)
    }
}
