import os

enum PlannerLog {
    static let persistence = Logger(subsystem: "com.rihscb.Planner", category: "persistence")
    static let outline = Logger(subsystem: "com.rihscb.Planner", category: "outline")
    static let calendar = Logger(subsystem: "com.rihscb.Planner", category: "calendar")
}
