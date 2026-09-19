import AppKit
import SwiftTerm

/// An embedded login shell whose working directory is a disposable assistant
/// workspace containing Planner's MCP instructions.
@MainActor
final class TerminalViewController: NSViewController {
    private let terminalView = LocalProcessTerminalView(frame: .zero)
    private let restartButton = NSButton()
    private let endpointURL: () -> URL

    private var clickMonitor: Any?
    private var workspace: AssistantWorkspace?
    private var processIsRunning = false
    private var isShuttingDown = false

    init(endpointURL: @escaping () -> URL) {
        self.endpointURL = endpointURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let background = TerminalBackgroundView()
        background.onAppearanceChange = { [weak self] in self?.applyColors() }
        view = background

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.processDelegate = self
        terminalView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.addSubview(terminalView)

        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartClicked)
        restartButton.isHidden = true
        restartButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(restartButton)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            restartButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            restartButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        applyColors()
        installClickToFocus()
    }

    private func installClickToFocus() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, let window = self.view.window, event.window === window else {
                return event
            }
            let point = self.terminalView.convert(event.locationInWindow, from: nil)
            if self.terminalView.bounds.contains(point),
               window.firstResponder !== self.terminalView
            {
                window.makeFirstResponder(self.terminalView)
            }
            return event
        }
    }

    private func applyColors() {
        let appearance = view.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            terminalView.nativeBackgroundColor = .textBackgroundColor
            terminalView.nativeForegroundColor = .textColor
            terminalView.caretColor = .controlAccentColor
            terminalView.selectedTextBackgroundColor = .selectedTextBackgroundColor
        }
    }

    // MARK: - Process

    /// Starts the first shell only when the user reveals the pane.
    func startIfNeeded() {
        guard !processIsRunning, !terminalView.process.running else { return }
        restart()
    }

    func restart() {
        isShuttingDown = false
        if terminalView.process.running {
            let pid = terminalView.process.shellPid
            terminalView.terminate()
            Self.hangUpShell(pid)
        }
        startShellWhenIdle()
    }

    func shutdown() {
        isShuttingDown = true
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if terminalView.process.running {
            let pid = terminalView.process.shellPid
            terminalView.terminate()
            Self.hangUpShell(pid)
        }
        processIsRunning = false
        workspace?.remove()
        workspace = nil
    }

    private static func hangUpShell(_ pid: pid_t) {
        guard pid > 0 else { return }
        kill(-pid, SIGHUP)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    private func startShellWhenIdle(attempt: Int = 0) {
        guard !isShuttingDown else { return }
        if terminalView.process.running {
            guard attempt < 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.startShellWhenIdle(attempt: attempt + 1)
            }
            return
        }
        startShell()
    }

    private func startShell() {
        do {
            if workspace == nil {
                workspace = try AssistantWorkspace(endpointURL: endpointURL())
            }
        } catch {
            restartButton.title = "Could not create assistant workspace — Retry"
            restartButton.isEnabled = true
            restartButton.isHidden = false
            return
        }
        guard let directory = workspace?.url else { return }

        restartButton.isHidden = true
        terminalView.getTerminal().resetToInitialState()

        let shell = Self.loginShell()
        let shellName = (shell as NSString).lastPathComponent
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("PLANNER_MCP_URL=\(endpointURL().absoluteString)")
        environment.append("PLANNER_ASSISTANT_WORKSPACE=\(directory.path(percentEncoded: false))")

        processIsRunning = true
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: environment,
            execName: "-\(shellName)",
            currentDirectory: directory.path(percentEncoded: false)
        )
    }

    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell)
        {
            return shell
        }
        return "/bin/zsh"
    }

    @objc private func restartClicked() {
        restart()
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(terminalView)
    }

    var test_processIsRunning: Bool { processIsRunning }
    var test_workspaceURL: URL? { workspace?.url }
}

extension TerminalViewController: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.processIsRunning = false
            guard !self.isShuttingDown else { return }
            self.restartButton.title =
                "Shell exited" + (exitCode.map { " (status \($0))" } ?? "") + " — Restart"
            self.restartButton.isEnabled = true
            self.restartButton.isHidden = false
        }
    }
}

@MainActor
private final class TerminalBackgroundView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
    }
}
