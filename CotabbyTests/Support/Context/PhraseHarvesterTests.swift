import XCTest
@testable import Cotabby

/// Covers what may be learned from the writer's own finished text and — more importantly — what may
/// never be, since everything that passes these filters is persisted on first sight.
final class PhraseHarvesterTests: XCTestCase {
    func test_keepsSentencesFromAMultiSentenceMessage() {
        let phrases = PhraseHarvester.phrases(
            in: "Thanks for the update. I will send the revised deck tomorrow morning."
        )

        XCTAssertEqual(
            phrases,
            ["Thanks for the update", "I will send the revised deck tomorrow morning"]
        )
    }

    func test_keepsEachLineOfAMultiLineMessage() {
        let phrases = PhraseHarvester.phrases(in: "Hallo Maria\nich melde mich morgen bei dir\nViele Grüße")

        XCTAssertEqual(phrases, ["Hallo Maria", "ich melde mich morgen bei dir", "Viele Grüße"])
    }

    func test_stripsQuoteAndBulletDecorationBeforeJudging() {
        let phrases = PhraseHarvester.phrases(in: "> - please confirm the delivery window")

        XCTAssertEqual(phrases, ["please confirm the delivery window"])
    }

    /// A period inside a word or a number must not split the sentence, or the phrase stored would be
    /// a fragment that never matches what the writer types next time.
    func test_doesNotSplitOnInWordPeriods() {
        let phrases = PhraseHarvester.phrases(in: "the importer drops mobile.bg listings again")

        XCTAssertEqual(phrases, ["the importer drops mobile.bg listings again"])
    }

    func test_dropsSingleWordAndVeryShortCandidates() {
        XCTAssertTrue(PhraseHarvester.phrases(in: "Thanks").isEmpty)
        XCTAssertTrue(PhraseHarvester.phrases(in: "ok so ok").isEmpty)
        XCTAssertTrue(PhraseHarvester.phrases(in: "yes. no. ok.").isEmpty)
    }

    func test_dropsOverlongCandidates() {
        let longSentence = Array(repeating: "reallylongword", count: 12).joined(separator: " ")

        XCTAssertTrue(PhraseHarvester.phrases(in: longSentence).isEmpty)
    }

    // MARK: - Secrets and identifiers

    func test_dropsCandidatesCarryingAnApiKeyShapedToken() {
        let phrases = PhraseHarvester.phrases(
            in: "the staging key is sk_live_9f3kQ2mZp0aTvXb7Lc for now"
        )

        XCTAssertTrue(phrases.isEmpty)
    }

    func test_dropsCandidatesCarryingAnAddress() {
        XCTAssertTrue(PhraseHarvester.phrases(in: "write to maria at maria@example.com please").isEmpty)
        XCTAssertTrue(PhraseHarvester.phrases(in: "the deck is at https://example.com/deck today").isEmpty)
    }

    func test_dropsCandidatesCarryingALongDigitRun() {
        XCTAssertTrue(PhraseHarvester.phrases(in: "the code is 481920 for this login").isEmpty)
        XCTAssertTrue(PhraseHarvester.phrases(in: "call me on 0888123456 later today").isEmpty)
    }

    func test_dropsDigitHeavyCandidates() {
        XCTAssertTrue(PhraseHarvester.phrases(in: "24 900 EUR 178 000 km 2019").isEmpty)
    }

    /// A number inside an otherwise normal sentence is exactly the kind of detail worth reusing, so
    /// the digit filters must not be so eager that they take the sentence with them.
    func test_keepsASentenceThatMerelyMentionsANumber() {
        let phrases = PhraseHarvester.phrases(in: "invoice 4412 is still unpaid")

        XCTAssertEqual(phrases, ["invoice 4412 is still unpaid"])
    }

    // MARK: - Keys and bounds

    func test_normalizedKeyIgnoresCaseSpacingAndOuterPunctuation() {
        XCTAssertEqual(
            PhraseHarvester.normalizedKey(for: "  Ich melde   mich morgen!  "),
            PhraseHarvester.normalizedKey(for: "ich melde mich morgen")
        )
    }

    func test_deduplicatesRepeatedPhrasesWithinOneCommit() {
        let phrases = PhraseHarvester.phrases(in: "Sounds good to me. sounds good to me!")

        XCTAssertEqual(phrases, ["Sounds good to me"])
    }

    func test_capsPhrasesPerCommitSoOnePasteCannotFloodTheTable() {
        let block = (1...20)
            .map { "this is candidate sentence number \($0)" }
            .joined(separator: "\n")

        XCTAssertEqual(
            PhraseHarvester.phrases(in: block).count,
            PhraseHarvester.maximumPhrasesPerCommit
        )
    }
}
