import XCTest
@testable import Planner

final class MailThreadingTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_786_000_000)

    private func message(
        _ name: String,
        minutes: Int,
        subject: String,
        participants: [String] = ["ada@example.com", "you@example.com"],
        inReplyTo: String? = nil,
        references: String? = nil
    ) -> MailThreading.Message {
        MailThreading.Message(
            // Deterministic uuids so tie-breaks in the assertions are stable.
            id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", abs(name.hashValue % 999_999)))")
                ?? UUID(),
            messageID: "<\(name)@example.com>",
            subject: subject,
            participants: Set(participants),
            receivedAt: epoch.addingTimeInterval(TimeInterval(minutes * 60)),
            inReplyTo: inReplyTo,
            references: references
        )
    }

    private func subjects(_ threads: [MailThreading.Thread]) -> [String] {
        threads.map(\.subject)
    }

    private func ids(_ thread: MailThreading.Thread) -> [String] {
        thread.messages.map(\.messageID)
    }

    // MARK: - Reference chains

    func testAReplyChainBecomesOneThread() {
        let root = message("a", minutes: 0, subject: "Deposition prep")
        let reply = message(
            "b", minutes: 10, subject: "RE: Deposition prep",
            inReplyTo: root.messageID, references: root.messageID
        )
        let second = message(
            "c", minutes: 20, subject: "RE: Deposition prep",
            inReplyTo: reply.messageID,
            references: "\(root.messageID) \(reply.messageID)"
        )

        let threads = MailThreading.threads([root, reply, second])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].count, 3)
        XCTAssertEqual(ids(threads[0]), [second.messageID, reply.messageID, root.messageID])
    }

    /// Two replies to a message that was never saved still belong together:
    /// they share an ancestor that is not in the corpus.
    func testRepliesJoinThroughAnAbsentAncestor() {
        let absent = "<origin@example.com>"
        let one = message("b", minutes: 10, subject: "Filing",
                          participants: ["ada@example.com"], references: absent)
        let two = message("c", minutes: 20, subject: "Wholly different subject",
                          participants: ["grace@example.com"], references: absent)

        let threads = MailThreading.threads([one, two])
        XCTAssertEqual(threads.count, 1, "a shared ancestor did not join two replies")
    }

    /// A broken chain is the case the subject fallback exists for.
    func testABrokenChainStillThreadsBySubjectAndParticipants() {
        let root = message("a", minutes: 0, subject: "Expert report")
        let reply = message("b", minutes: 10, subject: "Re: Expert report")   // no headers

        let threads = MailThreading.threads([root, reply])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].subject, "Expert report")
    }

    /// The fallback must not collapse unrelated conversations that happen to
    /// share a generic subject.
    func testSameSubjectWithNoSharedParticipantsStaysApart() {
        let one = message("a", minutes: 0, subject: "Lunch?", participants: ["ada@example.com"])
        let two = message("b", minutes: 10, subject: "Lunch?", participants: ["grace@example.com"])

        let threads = MailThreading.threads([one, two])
        XCTAssertEqual(threads.count, 2, "the subject fallback ignored the participant check")
    }

    func testSingleMessagesAreSingleMessageThreads() {
        let one = message("a", minutes: 0, subject: "One", participants: ["ada@example.com"])
        let two = message("b", minutes: 10, subject: "Two", participants: ["grace@example.com"])

        let threads = MailThreading.threads([one, two])
        XCTAssertEqual(threads.count, 2)
        XCTAssertTrue(threads.allSatisfy { $0.count == 1 })
    }

    func testEmptyCorpusThreadsToNothing() {
        XCTAssertTrue(MailThreading.threads([]).isEmpty)
    }

    // MARK: - Ordering

    func testThreadsAreOrderedByTheirNewestMessage() {
        let oldRoot = message("a", minutes: 0, subject: "Old thread", participants: ["ada@example.com"])
        let oldReply = message("b", minutes: 5, subject: "Re: Old thread",
                               participants: ["ada@example.com"], references: oldRoot.messageID)
        let newer = message("c", minutes: 100, subject: "Newer", participants: ["grace@example.com"])

        let threads = MailThreading.threads([oldRoot, oldReply, newer])
        XCTAssertEqual(subjects(threads), ["Newer", "Old thread"])
        XCTAssertEqual(threads[1].latestDate, oldReply.receivedAt)
    }

    func testThreadIsLabelledFromItsNewestMessage() {
        let root = message("a", minutes: 0, subject: "Original name")
        let renamed = message("b", minutes: 10, subject: "Re: Carried on under this name",
                              references: root.messageID)
        let threads = MailThreading.threads([root, renamed])
        XCTAssertEqual(threads[0].subject, "Carried on under this name")
    }

    func testThreadParticipantsAreTheUnionOfItsMessages() {
        let root = message("a", minutes: 0, subject: "Case", participants: ["ada@example.com"])
        let reply = message("b", minutes: 5, subject: "Re: Case",
                            participants: ["grace@example.com"], references: root.messageID)
        let threads = MailThreading.threads([root, reply])
        XCTAssertEqual(threads[0].participants, ["ada@example.com", "grace@example.com"])
    }

    /// Threading runs on every draw, so the same corpus in a different order
    /// must produce the identical result.
    func testGroupingIsIndependentOfInputOrder() {
        let root = message("a", minutes: 0, subject: "Stable")
        let reply = message("b", minutes: 10, subject: "Re: Stable", references: root.messageID)
        let other = message("c", minutes: 20, subject: "Other", participants: ["grace@example.com"])

        let forward = MailThreading.threads([root, reply, other])
        let backward = MailThreading.threads([other, reply, root])
        XCTAssertEqual(subjects(forward), subjects(backward))
        XCTAssertEqual(forward.map(ids), backward.map(ids))
    }

    // MARK: - Subject normalization

    func testStripsReplyAndForwardPrefixes() {
        XCTAssertEqual(MailThreading.normalizedSubject("Re: Hello"), "Hello")
        XCTAssertEqual(MailThreading.normalizedSubject("RE: Hello"), "Hello")
        XCTAssertEqual(MailThreading.normalizedSubject("Fwd: Hello"), "Hello")
        XCTAssertEqual(MailThreading.normalizedSubject("FW: Hello"), "Hello")
        XCTAssertEqual(MailThreading.normalizedSubject("AW: Hello"), "Hello")
        XCTAssertEqual(MailThreading.normalizedSubject("WG: Hello"), "Hello")
    }

    func testStripsStackedPrefixes() {
        XCTAssertEqual(MailThreading.normalizedSubject("Re: Fwd: RE: Hello"), "Hello")
    }

    func testStripsCountedPrefixes() {
        XCTAssertEqual(MailThreading.normalizedSubject("Re[2]: Hello"), "Hello")
        XCTAssertEqual(MailThreading.normalizedSubject("Re(3): Hello"), "Hello")
    }

    /// The bug this guards: a subject that merely begins with the letters.
    func testLeavesWordsThatMerelyStartWithAPrefix() {
        XCTAssertEqual(MailThreading.normalizedSubject("Recipe ideas"), "Recipe ideas")
        XCTAssertEqual(MailThreading.normalizedSubject("Review of the draft"), "Review of the draft")
        XCTAssertEqual(MailThreading.normalizedSubject("Fwding is not a word"), "Fwding is not a word")
    }

    func testFoldsWhitespace() {
        XCTAssertEqual(MailThreading.normalizedSubject("  Re:   Hello   there \n"), "Hello there")
    }

    func testASubjectThatIsNothingButPrefixesNormalizesToEmpty() {
        XCTAssertEqual(MailThreading.normalizedSubject("Re:"), "")
        XCTAssertEqual(MailThreading.normalizedSubject(""), "")
    }

    /// An all-prefix subject must not become a join key, or every such message
    /// lands in one thread.
    func testEmptyNormalizedSubjectsDoNotJoin() {
        let one = message("a", minutes: 0, subject: "Re:")
        let two = message("b", minutes: 10, subject: "Fwd:")
        XCTAssertEqual(MailThreading.threads([one, two]).count, 2)
    }

    // MARK: - Reference header parsing

    func testParsesSpaceSeparatedReferences() {
        XCTAssertEqual(
            MailThreading.referenceIDs(from: "<a@x.com> <b@x.com>"),
            ["<a@x.com>", "<b@x.com>"]
        )
    }

    func testParsesFoldedAndCommaSeparatedReferences() {
        XCTAssertEqual(
            MailThreading.referenceIDs(from: "<a@x.com>,\r\n\t<b@x.com>"),
            ["<a@x.com>", "<b@x.com>"]
        )
    }

    func testParsesRunTogetherReferences() {
        XCTAssertEqual(
            MailThreading.referenceIDs(from: "<a@x.com><b@x.com>"),
            ["<a@x.com>", "<b@x.com>"]
        )
    }

    func testAcceptsABareUnbracketedID() {
        XCTAssertEqual(MailThreading.referenceIDs(from: "a@x.com"), ["a@x.com"])
    }

    func testIgnoresEmptyAndUnterminatedReferences() {
        XCTAssertEqual(MailThreading.referenceIDs(from: nil), [])
        XCTAssertEqual(MailThreading.referenceIDs(from: ""), [])
        XCTAssertEqual(MailThreading.referenceIDs(from: "<>"), [])
        XCTAssertEqual(MailThreading.referenceIDs(from: "<unterminated"), [])
    }
}
