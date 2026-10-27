import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
