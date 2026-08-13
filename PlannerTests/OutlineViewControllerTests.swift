import CoreData
import XCTest
@testable import Planner

@MainActor
final class OutlineViewControllerTests: PersistenceTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "Planner.OutlineViewControllerTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCreateSaveRowForItemRemainsValidAfterProcessPendingChanges() throws {
        let outline = makeOutline()
        let project = try model.createProject()

        XCTAssertFalse(project.objectID.isTemporaryID)
        let row = outline.outlineView.row(forItem: project)
        XCTAssertGreaterThanOrEqual(row, 0)

        persistence.viewContext.processPendingChanges()
        XCTAssertEqual(outline.outlineView.row(forItem: project), row)

        let task = try model.createTask(in: project)
        XCTAssertFalse(task.objectID.isTemporaryID)
        outline.outlineView.expandItem(project)
        let taskRow = outline.outlineView.row(forItem: task)
        XCTAssertGreaterThanOrEqual(taskRow, 0)

        persistence.viewContext.processPendingChanges()
        XCTAssertEqual(outline.outlineView.row(forItem: task), taskRow)
    }

    func testSelectionModelNodeChangeRevealsRow() throws {
        let selection = SelectionModel()
        let outline = makeOutline(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)

        selection.selectNode(uuid: task.uuid)

        let row = outline.outlineView.row(forItem: task)
        XCTAssertGreaterThanOrEqual(row, 0)
        XCTAssertEqual(outline.outlineView.selectedRow, row)
        XCTAssertTrue(outline.outlineView.isItemExpanded(project))
    }

    private func makeOutline(selection: SelectionModel = SelectionModel()) -> OutlineViewController {
        let outline = OutlineViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            userDefaults: defaults
        )
        outline.loadViewIfNeeded()
        return outline
    }
}
