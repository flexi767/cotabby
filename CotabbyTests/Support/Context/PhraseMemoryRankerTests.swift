import XCTest
@testable import Cotabby

/// Covers which learned phrases are allowed to spend prompt budget. The load-bearing rules are the
/// two-sighting floor (nothing typed once may ever be injected) and the continuation match (a phrase
/// that starts with the words already typed outranks everything else).
final class PhraseMemoryRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let bundleIdentifier = "com.example.Chat"

    func test_neverSuggestsAPhraseSeenOnlyOnce() {
        let snapshot = makeSnapshot([
            phrase("I will send the revised deck tomorrow", count: 1)
        ])

        let selected = PhraseMemoryRanker.selected(
            from: snapshot,
            prefixText: "I will send the",
            bundleIdentifier: bundleIdentifier,
            now: now
        )

        XCTAssertTrue(selected.isEmpty)
    }

    func test_suggestsAPhraseThatContinuesWhatIsBeingTyped() {
        let snapshot = makeSnapshot([
            phrase("I will send the revised deck tomorrow", count: 2)
        ])

        let selected = PhraseMemoryRanker.selected(
            from: snapshot,
            prefixText: "Thanks for the ping. I will send the",
            bundleIdentifier: bundleIdentifier,
            now: now
        )

        XCTAssertEqual(selected, ["I will send the revised deck tomorrow"])
    }

    /// A longer matched run is stronger evidence, so it must outrank a phrase that merely shares a
    /// single word — even when that other phrase has been typed far more often.
    func test_longerContinuationMatchOutranksAMoreFrequentShorterMatch() {
        let snapshot = makeSnapshot([
            phrase("please confirm the delivery window", count: 40),
            phrase("please confirm the revised timeline with Maria", count: 2)
        ])

        let selected = PhraseMemoryRanker.selected(
            from: snapshot,
            prefixText: "Hi Maria, please confirm the revised",
            bundleIdentifier: bundleIdentifier,
            now: now,
            limit: 1
        )

        XCTAssertEqual(selected, ["please confirm the revised timeline with Maria"])
    }

    /// Matching on a short function word would promote an unrelated phrase in nearly every sentence.
    func test_ignoresASingleShortWordMatch() {
        XCTAssertEqual(
            PhraseMemoryRanker.continuationMatchLength(
                phraseWords: ["the", "revised", "deck", "is", "attached"],
                prefixWords: ["i", "think", "the"]
            ),
            0
        )
        XCTAssertEqual(
            PhraseMemoryRanker.continuationMatchLength(
                phraseWords: ["thanks", "for", "the", "update"],
                prefixWords: ["hello", "thanks"]
            ),
            1
        )
    }

    func test_neverRepeatsAPhraseTheWriterHasAlreadyFinished() {
        let snapshot = makeSnapshot([phrase("thanks for the update", count: 9)])

        let selected = PhraseMemoryRanker.selected(
            from: snapshot,
            prefixText: "Thanks for the update, I will",
            bundleIdentifier: bundleIdentifier,
            now: now
        )

        XCTAssertTrue(selected.isEmpty)
    }

    // MARK: - Ambient favorites

    func test_offersAFrequentSameAppPhraseWithNoMatchAtAll() {
        let snapshot = makeSnapshot([phrase("let me know if that works for you", count: 12)])

        let selected = PhraseMemoryRanker.selected(
            from: snapshot,
            prefixText: "Booked the room for Thursday, ",
            bundleIdentifier: bundleIdentifier,
            now: now
        )

        XCTAssertEqual(selected, ["let me know if that works for you"])
    }

    func test_withholdsAnUnmatchedPhraseFromAnotherApp() {
        let snapshot = makeSnapshot([
            phrase("let me know if that works for you", count: 12, bundleIdentifier: "com.example.Mail")
        ])

        let selected = PhraseMemoryRanker.selected(
            from: snapshot,
            prefixText: "Booked the room for Thursday, ",
            bundleIdentifier: bundleIdentifier,
            now: now
        )

        XCTAssertTrue(selected.isEmpty)
    }

    /// Twice is enough to be quoted back when it continues the caret text, but an unmatched hunch
    /// needs more evidence than that.
    func test_withholdsAnUnmatchedPhraseSeenOnlyTwice() {
        let snapshot = makeSnapshot([phrase("let me know if that works for you", count: 2)])

        let selected = PhraseMemoryRanker.selected(
            from: snapshot,
            prefixText: "Booked the room for Thursday, ",
            bundleIdentifier: bundleIdentifier,
            now: now
        )

        XCTAssertTrue(selected.isEmpty)
    }

    // MARK: - Bounds

    /// Once the sentence being typed is identified, the other phrases are competing noise — and a
    /// preface that lists several of them taught the model the list: in the eval it carried the "; "
    /// separator into the ghost text and ran on into the second phrase.
    func test_aContinuationMatchCrowdsOutTheOtherPhrases() {
        let snapshot = makeSnapshot([
            phrase("please confirm the delivery window today", count: 8),
            phrase("please confirm the invoice reference", count: 7),
            phrase("please confirm the shipping address", count: 6)
        ])

        let selected = PhraseMemoryRanker.selected(
            from: snapshot,
            prefixText: "Hi, please confirm the delivery",
            bundleIdentifier: bundleIdentifier,
            now: now
        )

        XCTAssertEqual(selected, ["please confirm the delivery window today"])
    }

    func test_respectsTheSelectionLimitAndCharacterBudgetForAmbientFavorites() {
        let snapshot = makeSnapshot([
            phrase("let me know if that works for you", count: 8),
            phrase("happy to jump on a quick call", count: 7),
            phrase("thanks again for the quick turnaround", count: 6),
            phrase("I will keep you posted either way", count: 5)
        ])
        let prefixText = "Booked the big room for Thursday at ten. "

        let limited = PhraseMemoryRanker.selected(
            from: snapshot,
            prefixText: prefixText,
            bundleIdentifier: bundleIdentifier,
            now: now
        )
        XCTAssertEqual(limited.count, PhraseMemoryRanker.maximumSelected)

        let budgeted = PhraseMemoryRanker.selected(
            from: snapshot,
            prefixText: prefixText,
            bundleIdentifier: bundleIdentifier,
            now: now,
            maxCharacters: 40
        )
        XCTAssertEqual(budgeted.count, 1)
    }

    func test_returnsNothingForAnEmptyMemoryOrEmptyPrefix() {
        XCTAssertTrue(
            PhraseMemoryRanker.selected(
                from: .empty,
                prefixText: "anything at all",
                bundleIdentifier: bundleIdentifier,
                now: now
            ).isEmpty
        )
        XCTAssertTrue(
            PhraseMemoryRanker.selected(
                from: makeSnapshot([phrase("thanks for the update", count: 9)]),
                prefixText: "   ",
                bundleIdentifier: bundleIdentifier,
                now: now
            ).isEmpty
        )
    }

    // MARK: - Helpers

    private func makeSnapshot(_ phrases: [LearnedPhrase]) -> PhraseMemorySnapshot {
        PhraseMemorySnapshot(phrases: phrases)
    }

    private func phrase(
        _ text: String,
        count: Int,
        bundleIdentifier: String? = nil,
        lastUsedAt: Date? = nil
    ) -> LearnedPhrase {
        LearnedPhrase(
            key: PhraseHarvester.normalizedKey(for: text),
            text: text,
            count: count,
            lastUsedAt: lastUsedAt ?? now,
            bundleIdentifiers: [bundleIdentifier ?? self.bundleIdentifier]
        )
    }
}
