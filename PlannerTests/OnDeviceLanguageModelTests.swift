import XCTest
@testable import Planner

final class OnDeviceLanguageModelTests: XCTestCase {
    func testUnavailableModelRefusesEveryRequest() async {
        let model = UnavailableOnDeviceLanguageModel()
        XCTAssertEqual(model.availability, .unavailable)
        do {
            _ = try await model.respond(to: OnDeviceModelRequest(instructions: "", prompt: "hello"))
            XCTFail("unavailable model answered")
        } catch let error as OnDeviceModelError {
            XCTAssertEqual(error, .unavailable(.unavailable))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAvailabilitySentencesNameTheReason() {
        XCTAssertEqual(
            OnDeviceModelAvailability.deviceNotEligible.userDescription,
            "This Mac doesn’t support Apple Intelligence."
        )
        XCTAssertEqual(
            OnDeviceModelAvailability.appleIntelligenceNotEnabled.userDescription,
            "Apple Intelligence is turned off in System Settings."
        )
        XCTAssertFalse(OnDeviceModelAvailability.modelNotReady.isAvailable)
        XCTAssertTrue(OnDeviceModelAvailability.available.isAvailable)
    }

    func testTheStubParksUntilTheTestAnswers() async throws {
        let model = StubOnDeviceLanguageModel()
        let task = Task { try await model.respond(to: OnDeviceModelRequest(instructions: "be brief", prompt: "hi")) }
        await waitUntil("request parked") { model.pendingCount == 1 }
        XCTAssertEqual(model.pendingPrompts, ["hi"])
        model.finish(with: "hello")
        let reply = try await task.value
        XCTAssertEqual(reply, "hello")
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(model.pendingCount, 0)
    }

    func testTheStubCanFailAMatchingPrompt() async throws {
        let model = StubOnDeviceLanguageModel()
        let first = Task { try await model.respond(to: OnDeviceModelRequest(instructions: "", prompt: "alpha")) }
        let second = Task { try await model.respond(to: OnDeviceModelRequest(instructions: "", prompt: "beta")) }
        await waitUntil("both parked") { model.pendingCount == 2 }
        model.finish(promptContaining: "beta", with: "B")
        model.finish(throwing: OnDeviceModelError.refused)
        let beta = try await second.value
        XCTAssertEqual(beta, "B")
        do {
            _ = try await first.value
            XCTFail("first request succeeded")
        } catch let error as OnDeviceModelError {
            XCTAssertEqual(error, .refused)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        model.drain()
    }

    private func waitUntil(_ label: String, _ predicate: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(label)")
    }
}
