import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// `NSApplication.delegate` is weak. Swift 6 `@main` + MainActor isolation
    /// can drop the synthesized local before the run loop starts.
    private static var running: AppDelegate?

    private var window: NSWindow?
    private var persistence: PersistenceController?
    private var model: ModelController?
    private var selection: SelectionModel?
    private var events: EventCoordinator?
    private var mail: MailCoordinator?

    override init() {
        super.init()
        Self.running = self
    }

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
        // Outlook is read over Apple events, so a Mac without it (or without
        // consent) simply shows no events rather than failing to launch.
        let events = EventCoordinator(source: OutlookEventSource())
        // Same reasoning for mail: no Outlook, or no consent, simply means an
        // empty Recent Mail rather than a failure to launch.
        let mail = MailCoordinator(source: OutlookMailSource())
        self.persistence = persistence
        self.model = model
        self.selection = selection
        self.events = events
        self.mail = mail

        let split = MainSplitViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            events: events,
            mail: mail
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Planner"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 720))
        // Sidebar 240 + calendar 420; the trailing inspector collapses out of the
        // way rather than holding the window any wider than that.
        window.contentMinSize = NSSize(width: 880, height: 520)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MainWindow.v2")
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        model.presentingWindow = window
        self.window = window
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let split = window?.contentViewController as? MainSplitViewController,
           !split.flushInspectorNotes() {
            return .terminateCancel
        }
        guard let persistence else { return .terminateNow }
        return persistence.saveViewContext(presentingWindow: window) ? .terminateNow : .terminateCancel
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        persistence?.viewContext.undoManager
    }
}
