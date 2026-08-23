import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.revealForRecovery()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        menuBar?.revealForRecovery()
    }
}
