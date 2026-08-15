import os

/// `nonisolated`: `os.Logger` is thread-safe, and the Outlook source logs from
/// its own queue. The project's default `MainActor` isolation would otherwise
/// make these unreachable from anywhere but the main thread.
nonisolated enum PlannerLog {
    static let persistence = Logger(subsystem: "com.rihscb.Planner", category: "persistence")
    static let outline = Logger(subsystem: "com.rihscb.Planner", category: "outline")
    static let calendar = Logger(subsystem: "com.rihscb.Planner", category: "calendar")
    /// External calendar feed. Log counts, timings, and failures — never event
    /// subjects, locations, or organizers: that is someone else's calendar
    /// content, under the same rule as note bodies.
    static let events = Logger(subsystem: "com.rihscb.Planner", category: "events")
}
