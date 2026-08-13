import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var persistence: PersistenceController?
    private var model: ModelController?
    private var selection: SelectionModel?

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

        let model = ModelController(persistence: persistence)
        let selection = SelectionModel()
        self.persistence = persistence
        self.model = model
        self.selection = selection

        let split = MainSplitViewController(
            persistence: persistence,
            model: model,
            selection: selection
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Planner"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1040, height: 660))
        window.contentMinSize = NSSize(width: 800, height: 500)
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        model.presentingWindow = window
        self.window = window
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        persistence?.viewContext.undoManager
    }
}
