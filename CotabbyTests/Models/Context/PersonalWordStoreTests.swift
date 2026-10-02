@testable import Cotabby
import XCTest

@MainActor
final class PersonalWordStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalWordStoreTests-\(UUID().uuidString)")
            .appendingPathComponent("personal-words.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func phrases(_ items: [(String, Int)]) -> PhraseMemorySnapshot {
        PhraseMemorySnapshot(phrases: items.map {
            LearnedPhrase(key: PhraseHarvester.normalizedKey(for: $0.0), text: $0.0, count: $0.1, lastUsedAt: Date())
        })
    }

    func testSeedsOnceFromLearnedPhrasesWeightedByCount() {
        let store = PersonalWordStore(fileURL: fileURL)
        store.seedIfEmpty(from: phrases([("see you tomorrow then", 3)]))
        XCTAssertEqual(store.model.prediction(precedingText: "ok see you ", maximumWords: 1), "tomorrow")
        let before = store.model
        store.seedIfEmpty(from: phrases([("see you later", 9)]))
        XCTAssertEqual(store.model, before, "seeding happens once")
    }

    func testPersistsAcrossLaunchesPrivately() throws {
        let store = PersonalWordStore(fileURL: fileURL)
        store.record(committedText: "see you tomorrow.")
        store.waitForPendingWrites()
        let reloaded = PersonalWordStore(fileURL: fileURL)
        // Compared by content: timestamps lose sub-second precision in the file, which is harmless.
        XCTAssertEqual(Set(reloaded.model.words.keys), Set(store.model.words.keys))
        XCTAssertEqual(reloaded.model.followers, store.model.followers)
        XCTAssertEqual(reloaded.wordCount, 3)
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testAcceptedWordsEarnExtraWeightInTheirContext() {
        let store = PersonalWordStore(fileURL: fileURL)
        store.record(committedText: "see you tomorrow.")
        store.record(committedText: "see you tomorrow.")
        XCTAssertNil(store.model.prediction(precedingText: "ok see you ", maximumWords: 1))
        store.recordAccepted(precedingText: "Thanks, see you ", acceptedText: "tomorrow")
        XCTAssertEqual(store.model.prediction(precedingText: "ok see you ", maximumWords: 1), "tomorrow")
    }

    func testMidWordAcceptGluesOntoThePartialWord() {
        let store = PersonalWordStore(fileURL: fileURL)
        store.recordAccepted(precedingText: "see you tomo", acceptedText: "rrow")
        XCTAssertNotNil(store.model.words["tomorrow"], "learned as one word")
        XCTAssertNil(store.model.words["rrow"])
    }

    func testKnownNumbersPersistAndAreForgotten() {
        let store = PersonalWordStore(fileURL: fileURL)
        store.record(committedText: "Call 0888 123 456.", excludingAcceptedDigits: [])
        store.record(committedText: "Or 0877 555 444.", excludingAcceptedDigits: ["555444"])
        store.waitForPendingWrites()
        let reloaded = PersonalWordStore(fileURL: fileURL)
        XCTAssertTrue(reloaded.knownNumbers.contains(digits: "0888123456"))
        XCTAssertFalse(reloaded.knownNumbers.contains(digits: "0877555444"), "accepted digits never become history")
        reloaded.forgetAll()
        XCTAssertTrue(PersonalWordStore(fileURL: fileURL).knownNumbers.isEmpty)
    }

    func testForgetRemovesEverything() {
        let store = PersonalWordStore(fileURL: fileURL)
        store.record(committedText: "see you tomorrow.")
        store.waitForPendingWrites()
        store.forgetAll()
        XCTAssertEqual(store.wordCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(PersonalWordStore(fileURL: fileURL).model.isEmpty)
    }
}
