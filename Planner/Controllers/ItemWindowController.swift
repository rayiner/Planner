import AppKit

/// A small window showing one task (with its note), one day's note, or one mail message.
///
/// Double-clicking a leaf task, a calendar day, or a message, and the MCP
/// `open_task` / `open_mail` tools, all land here. The window keeps its own
/// selection so paging the main outline does not retarget it. Already-open
/// subjects are brought forward instead of duplicated.
@MainActor
final class ItemWindowController: NSWindowController, NSWindowDelegate {
    enum Subject: Hashable {
        case task(UUID)
        case day(Date)
        case mail(Int64)
    }

    static let taskContentSize = NSSize(width: 420, height: 520)
    static let dayNoteContentSize = NSSize(width: 420, height: 520)
    static let mailContentSize = NSSize(width: 460, height: 560)

    private static var retained: [Subject: ItemWindowController] = [:]

    private let subject: Subject
    private let inspector: InspectorViewController?
    private let localSelection: SelectionModel

    static var openSubjects: Set<Subject> { Set(retained.keys) }

    @discardableResult
    static func flushAllNotes() -> Bool {
        retained.values.allSatisfy { $0.inspector?.flushPendingNote() ?? true }
    }

    static func closeAll() {
        for controller in Array(retained.values) {
            controller.close()
        }
    }

    static func openTask(
        uuid: UUID,
        persistence: PersistenceController,
        model: ModelController
    ) throws {
        if let existing = retained[.task(uuid)] {
            existing.show()
            return
        }
        guard let task = try model.task(uuid: uuid) else {
            throw MCPToolError("No task with that id.")
        }
        let controller = ItemWindowController(
            task: task,
            persistence: persistence,
            model: model
        )
        retained[.task(uuid)] = controller
        controller.show()
    }

    static func openDayNote(
        day: Date,
        persistence: PersistenceController,
        model: ModelController
    ) {
        let day = Calendar.current.startOfDay(for: day)
        if let existing = retained[.day(day)] {
            existing.show()
            return
        }
        let controller = ItemWindowController(
            day: day,
            persistence: persistence,
            model: model
        )
        retained[.day(day)] = controller
        controller.show()
    }

    static func openMail(id: Int64, mail: MailCoordinator) throws {
        if let existing = retained[.mail(id)] {
            existing.show()
            return
        }
        guard mail.message(id: id) != nil else {
            throw MCPToolError(
                "No mail with that id is loaded. Search or read it first, then open it."
            )
        }
        let controller = ItemWindowController(mailID: id, mail: mail)
        retained[.mail(id)] = controller
        controller.show()
    }

    private init(task: TaskItem, persistence: PersistenceController, model: ModelController) {
        subject = .task(task.uuid)
        localSelection = SelectionModel(
            defaults: UserDefaults(suiteName: "ItemWindow.\(UUID().uuidString)")!
        )
        localSelection.selectNode(uuid: task.uuid)
        let inspector = InspectorViewController(
            persistence: persistence,
            model: model,
            selection: localSelection,
            showsEmbeddedTitle: true
        )
        self.inspector = inspector
        let window = Self.makeWindow(
            title: task.title,
            size: Self.taskContentSize,
            content: inspector
        )
        super.init(window: window)
        window.delegate = self
    }

    private init(day: Date, persistence: PersistenceController, model: ModelController) {
        subject = .day(day)
        localSelection = SelectionModel(
            defaults: UserDefaults(suiteName: "ItemWindow.\(UUID().uuidString)")!
        )
        localSelection.selectDay(day)
        let inspector = InspectorViewController(
            persistence: persistence,
            model: model,
            selection: localSelection,
            showsEmbeddedTitle: true
        )
        self.inspector = inspector
        let window = Self.makeWindow(
            title: Self.dayNoteTitle(for: day),
            size: Self.dayNoteContentSize,
            content: inspector
        )
        super.init(window: window)
        window.delegate = self
    }

    private init(mailID: Int64, mail: MailCoordinator) {
        subject = .mail(mailID)
        inspector = nil
        localSelection = SelectionModel(
            defaults: UserDefaults(suiteName: "ItemWindow.\(UUID().uuidString)")!
        )
        localSelection.selectMessage(.recent(mailID))
        let reader = MailReaderViewController(selection: localSelection, mail: mail)
        let title = mail.message(id: mailID)?.subject
        let window = Self.makeWindow(
            title: (title?.isEmpty == false) ? title! : "Message",
            size: Self.mailContentSize,
            content: reader
        )
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeWindow(
        title: String,
        size: NSSize,
        content: NSViewController
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = content
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 320, height: 280)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        return window
    }

    private static func dayNoteTitle(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return formatter.string(from: day)
    }

    private func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        _ = inspector?.flushPendingNote()
        Self.retained[subject] = nil
    }
}
