import CoreData
import XCTest
@testable import Planner

/// A throwaway defaults suite.
///
/// Mode, window length and divider positions all persist now, so a test that
/// used `.standard` would leak into the next one — and into whatever the
/// developer had the real app set to.
func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "PlannerTests.\(UUID().uuidString)")!
}

@MainActor
class PersistenceTestCase: XCTestCase {
    var persistence: PersistenceController!
    var model: ModelController!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true)
        XCTAssertNil(persistence.storeLoadError)
        model = ModelController(persistence: persistence)
    }

    override func tearDown() {
        model = nil
        persistence = nil
        super.tearDown()
    }

    var testCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }

    func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 15,
        minute: Int = 30,
        calendar: Calendar? = nil
    ) -> Date {
        let calendar = calendar ?? testCalendar
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    func fetchAllTasks() throws -> [TaskItem] {
        try persistence.viewContext.fetch(TaskItem.fetchRequest())
    }
}
