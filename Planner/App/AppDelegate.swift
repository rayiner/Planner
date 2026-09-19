import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// `NSApplication.delegate` is weak. Swift 6 `@main` + MainActor isolation
    /// can drop the synthesized local before the run loop starts.
    private static var running: AppDelegate?

    private var window: NSWindow?
    /// Not private: `MCPAppBridge` lists and mutates tasks through it.
    private(set) var persistence: PersistenceController?
    /// Not private: `MCPAppBridge` lists and mutates tasks through it.
    private(set) var model: ModelController?
    /// Not private: `MCPAppBridge` reads the current mail selection.
    private(set) var selection: SelectionModel?
    private var events: EventCoordinator?
    /// Not private: `MCPAppBridge` searches and loads bodies through it.
    private(set) var mail: MailCoordinator?
    private var sync: CloudSyncController?

    override init() {
        super.init()
        Self.running = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The one place the real preference is read. Everywhere else — tests
        // included — gets `.disabled` unless it asks otherwise, so nothing
        // starts talking to iCloud by default.
        let persistence = PersistenceController(syncSettings: CloudSyncSettings(defaults: .standard))
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
        // Mail and calendar share one daemon and one derived index. The shared
        // session serializes their startup syncs; a missing helper/profile
        // leaves the corresponding feed in its ordinary failed state.
        let outlook = OlSyncOutlookSession()
        let events = EventCoordinator(source: OlSyncEventSource(session: outlook))
        let mail = MailCoordinator(source: OutlookMailSource(session: outlook))
        // Mirroring, the history drain behind it, and the repair pass that
        // follows an import. Inert when sync is off.
        let sync = CloudSyncController(persistence: persistence)
        sync.start()
        #if DEBUG
        persistence.initializeCloudKitSchemaIfRequested()
        #endif

        self.persistence = persistence
        self.sync = sync
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
        // Wider than either mode's panes need, so a mode switch never forces
        // the window to grow. See `windowContentMinimumWidth`.
        window.contentMinSize = NSSize(
            width: MainSplitViewController.windowContentMinimumWidth,
            height: 520
        )
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MainWindow.v2")
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        model.presentingWindow = window
        self.window = window

        // XCTest hosts the app; don't occupy the agent's port during tests.
        if NSClassFromString("XCTestCase") == nil {
            MCPServerController.shared.startIfEnabled()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPServerController.shared.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Notes are only ever edited in an item window now, so that is the only
        // place a pending one can be.
        if !ItemWindowController.flushAllNotes() {
            return .terminateCancel
        }
        guard let persistence else { return .terminateNow }
        return persistence.saveViewContext(presentingWindow: window) ? .terminateNow : .terminateCancel
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        persistence?.viewContext.undoManager
    }
}

// MARK: - iCloud sync menu

extension AppDelegate: NSMenuItemValidation {
    /// Flips the preference and says when it takes effect.
    ///
    /// It genuinely cannot take effect now: a loaded store cannot be re-pointed
    /// at a CloudKit container, and tearing the coordinator down mid-session
    /// would invalidate every managed object the outline, calendar and mail
    /// list are holding. Telling the user "next launch" is the honest
    /// version of that; silently doing nothing is not.
    @IBAction func toggleCloudSync(_ sender: Any?) {
        let settings = CloudSyncSettings(defaults: .standard)
        let enabling = !settings.isEnabled
        CloudSyncSettings.setEnabled(enabling, in: .standard)

        let alert = NSAlert()
        alert.messageText = enabling
            ? "Planner will sync with iCloud the next time it opens."
            : "Planner will stop syncing with iCloud the next time it opens."
        alert.informativeText = enabling
            ? """
            Your projects, tasks and day notes will be mirrored to \
            your private iCloud database and kept in step on every Mac signed \
            in to the same account. Nothing is uploaded until Planner reopens.
            """
            : """
            Everything stays on this Mac. What is already in iCloud is left \
            there; other Macs keep their copies.
            """
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// The status line. Disabled on purpose — it is a readout, not a command —
    /// but it still needs an action so that `validateMenuItem` is asked about
    /// it and can refresh the title on the way to returning false.
    @IBAction func showCloudSyncStatus(_ sender: Any?) {}

    // MARK: - MCP server

    /// Planner ▸ Turn On/Off MCP Server.
    @IBAction func toggleMCPServer(_ sender: Any?) {
        let controller = MCPServerController.shared
        controller.setEnabled(!controller.isEnabled)
    }

    /// Planner ▸ Copy MCP Server URL — the endpoint to paste into a client's
    /// configuration.
    @IBAction func copyMCPServerURL(_ sender: Any?) {
        guard let url = MCPServerController.shared.endpointURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// The status line. Disabled on purpose — it is a readout, not a command.
    @IBAction func showMCPServerStatus(_ sender: Any?) {}

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleCloudSync(_:)):
            // The checkmark tracks the *preference*, not the running state:
            // between switching it on and relaunching, the answer to "is
            // Planner set to sync?" is yes even though nothing is mirroring
            // yet. The status line below carries the running state.
            item.state = CloudSyncSettings(defaults: .standard).isEnabled ? .on : .off
            return true
        case #selector(showCloudSyncStatus(_:)):
            item.title = sync?.status.menuDescription ?? CloudSyncStatus.off.menuDescription
            return false
        case #selector(toggleMCPServer(_:)):
            item.title =
                MCPServerController.shared.isEnabled ? "Turn Off MCP Server" : "Turn On MCP Server"
            return true
        case #selector(copyMCPServerURL(_:)):
            return MCPServerController.shared.endpointURL != nil
        case #selector(showMCPServerStatus(_:)):
            item.title = MCPServerController.shared.statusSummary
            return false
        default:
            return true
        }
    }
}
