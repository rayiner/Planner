import AppKit

/// Process entry point. `@main` on a MainActor-isolated `NSApplicationDelegate`
/// does not keep the (weak) `NSApplication.delegate` alive, so the window
/// never appears.
let plannerAppDelegate = AppDelegate()
NSApplication.shared.delegate = plannerAppDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
