import XCTest
@testable import Cotabby

/// Covers the persistence half of phrase memory: counting repeats, tracking which apps a phrase
/// belongs to, surviving a relaunch, staying inside its cap, and forgetting everything on request.
@MainActor
final class PhraseMemoryStoreTests: XCTestCase {
    func test_recordsAndCountsRepeatedPhrases() {
        let defaults = InMemoryPhraseMemoryDefaults()
        let store = PhraseMemoryStore(defaults: defaults)

        store.record(committedText: "I will send the revised deck tomorrow.", bundleIdentifier: "com.example.Mail")
        store.record(committedText: "i will send the revised deck tomorrow", bundleIdentifier: "com.example.Mail")

        XCTAssertEqual(store.phraseCount, 1)
        XCTAssertEqual(store.eligiblePhraseCount, 1)
        XCTAssertEqual(store.snapshot().phrases.first?.count, 2)
        // The display form tracks the most recent spelling, so capitalization follows current habit.
        XCTAssertEqual(store.snapshot().phrases.first?.text, "i will send the revised deck tomorrow")
    }

    func test_countsAPhraseSeenOnceAsStoredButNotEligible() {
        let store = PhraseMemoryStore(defaults: InMemoryPhraseMemoryDefaults())

        store.record(committedText: "let me check with the supplier first", bundleIdentifier: nil)

        XCTAssertEqual(store.phraseCount, 1)
        XCTAssertEqual(store.eligiblePhraseCount, 0)
    }

    func test_tracksTheAppsAPhraseWasTypedInMostRecentFirst() {
        let store = PhraseMemoryStore(defaults: InMemoryPhraseMemoryDefaults())

        store.record(committedText: "talk tomorrow morning then", bundleIdentifier: "com.example.Mail")
        store.record(committedText: "talk tomorrow morning then", bundleIdentifier: "com.example.Chat")

        XCTAssertEqual(
            store.snapshot().phrases.first?.bundleIdentifiers,
            ["com.example.Chat", "com.example.Mail"]
        )
    }

    func test_survivesARelaunchThroughTheSameDefaults() {
        let defaults = InMemoryPhraseMemoryDefaults()
        let first = PhraseMemoryStore(defaults: defaults)
        first.record(committedText: "the revised timeline works for us", bundleIdentifier: nil)
        first.record(committedText: "the revised timeline works for us", bundleIdentifier: nil)

        let second = PhraseMemoryStore(defaults: defaults)

        XCTAssertEqual(second.phraseCount, 1)
        XCTAssertEqual(second.snapshot().phrases.first?.count, 2)
    }

    func test_trimsToTheTargetOnceTheCapIsExceededKeepingTheMostRepeated() {
        let store = PhraseMemoryStore(defaults: InMemoryPhraseMemoryDefaults())
        // One phrase that repeats, then enough one-off phrases to blow past the cap.
        store.record(committedText: "this one is typed all the time", bundleIdentifier: nil)
        store.record(committedText: "this one is typed all the time", bundleIdentifier: nil)
        for index in 0..<(PhraseMemoryStore.phraseCap + 10) {
            store.record(committedText: "filler phrase number \(index) here", bundleIdentifier: nil)
        }

        XCTAssertLessThanOrEqual(store.phraseCount, PhraseMemoryStore.phraseCap)
        XCTAssertTrue(
            store.snapshot().phrases.contains { $0.text == "this one is typed all the time" },
            "A repeated phrase must outlive one-off filler when the table is trimmed."
        )
    }

    func test_forgetAllClearsMemoryAndStorage() {
        let defaults = InMemoryPhraseMemoryDefaults()
        let store = PhraseMemoryStore(defaults: defaults)
        store.record(committedText: "let me know if that works for you", bundleIdentifier: nil)

        store.forgetAll()

        XCTAssertEqual(store.phraseCount, 0)
        XCTAssertTrue(store.snapshot().isEmpty)
        XCTAssertNil(defaults.storage["cotabbyLearnedPhrases"])
    }

    func test_recordsNothingForTextWithNoUsablePhrase() {
        let store = PhraseMemoryStore(defaults: InMemoryPhraseMemoryDefaults())

        XCTAssertTrue(store.record(committedText: "ok", bundleIdentifier: nil).isEmpty)
        XCTAssertEqual(store.phraseCount, 0)
    }
}

/// Keeps the suite off process-global `UserDefaults`, which is shared across tests and would mean a
/// test run could read or write the phrases of whoever is running it.
private final class InMemoryPhraseMemoryDefaults: PhraseMemoryDefaults {
    var storage: [String: Data] = [:]

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value as? Data
    }

    func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}
