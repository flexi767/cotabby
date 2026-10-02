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
        XCTAssertEqual(reloaded.model, store.model)
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
