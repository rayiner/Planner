import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Planner"
        window.contentView = NSView()
        window.setContentSize(NSSize(width: 1040, height: 660))
        window.contentMinSize = NSSize(width: 800, height: 500)
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
