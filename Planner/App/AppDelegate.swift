import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var persistence: PersistenceController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let persistence = PersistenceController()
        if let error = persistence.storeLoadError {
            let alert = NSAlert()
            alert.messageText = "Planner couldn’t open its library."
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.persistence = persistence

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Planner"
        window.contentViewController = MainSplitViewController()
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
