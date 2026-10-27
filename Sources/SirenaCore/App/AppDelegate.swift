import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-wake"), i + 2 < args.count {
            let audio = URL(fileURLWithPath: args[i + 1]), report = URL(fileURLWithPath: args[i + 2])
            Task {
                let text = await WakeWordSelfTest.run(audioURL: audio)
                try? text.write(to: report, atomically: true, encoding: .utf8)
                await MainActor.run { NSApp.terminate(nil) }
            }
            return
        }
        controller = AppController()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.onboarding.show()
        return false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controller?.listening.turnOff()
    }
}
