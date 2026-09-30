@testable import Cotabby
import XCTest

final class PhraseFastPathTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func phrase(_ text: String, count: Int = 2, age: TimeInterval = 0) -> LearnedPhrase {
        LearnedPhrase(key: PhraseHarvester.normalizedKey(for: text), text: text, count: count,
                      lastUsedAt: now.addingTimeInterval(-age))
    }

    private func continuation(_ preceding: String, trailing: String = "", _ phrases: [LearnedPhrase]) -> String? {
        PhraseFastPath.continuation(precedingText: preceding, trailingText: trailing,
                                    snapshot: PhraseMemorySnapshot(phrases: phrases))
    }

    private let deck = "I will send the revised deck tomorrow morning."

    func testContinuesThePhraseFromTheCaretInItsOwnSpelling() {
        XCTAssertEqual(continuation("I will send the ", [phrase(deck)]), "revised deck tomorrow morning.")
        XCTAssertEqual(continuation("I will send the", [phrase(deck)]), " revised deck tomorrow morning.",
                       "no space typed yet: the continuation carries it")
        XCTAssertEqual(continuation("I will send the rev", [phrase(deck)]), "ised deck tomorrow morning.",
                       "mid-word")
        XCTAssertEqual(continuation("i will  send THE ", [phrase(deck)]), "revised deck tomorrow morning.",
                       "case and spacing do not matter")
    }

    func testMatchesTheCurrentSentenceOnly() {
        XCTAssertEqual(continuation("Thanks for the notes. I will send the ", [phrase(deck)]),
                       "revised deck tomorrow morning.")
        XCTAssertEqual(continuation("Hi Sarah,\nI will send the ", [phrase(deck)]),
                       "revised deck tomorrow morning.")
        XCTAssertNil(continuation("Yes and I will send the ", [phrase(deck)]),
                     "the phrase starts a sentence; mid-sentence is weaker evidence")
    }

    func testNeedsEnoughTypedAndARepeatedPhrase() {
        XCTAssertNil(continuation("I will", [phrase(deck)]), "fewer than 8 characters")
        XCTAssertNil(continuation("Iwillsend", [phrase("Iwillsendit today please")]), "a single word")
        XCTAssertNil(continuation("I will send the ", [phrase(deck, count: 1)]), "typed only once")
    }

    func testRefusesWhenThereIsTextAfterTheCaretOrNothingLeft() {
        XCTAssertNil(continuation("I will send the ", trailing: "report", [phrase(deck)]))
        XCTAssertNil(continuation(deck, [phrase(deck)]))
        XCTAssertNil(continuation("I will send the revised deck tomorrow morning", [phrase(deck)]),
                     "only punctuation left")
        XCTAssertNil(continuation("I will send a ", [phrase(deck)]), "diverged")
    }

    func testDisagreeingPhrasesNeedAClearFavorite() {
        let notes = "I will send the notes after lunch."
        XCTAssertNil(continuation("I will send the ", [phrase(deck, count: 3), phrase(notes, count: 3)]))
        XCTAssertEqual(continuation("I will send the ", [phrase(deck, count: 4), phrase(notes, count: 3)]),
                       "revised deck tomorrow morning.")
        // Two phrases that agree on the next word are not a conflict.
        let deckFriday = "I will send the revised deck on Friday."
        XCTAssertEqual(continuation("I will send the ", [phrase(deck, count: 3), phrase(deckFriday, count: 3, age: 60)]),
                       "revised deck tomorrow morning.", "equal counts: the most recent one")
    }

    func testCurrentSentenceBoundaries() {
        XCTAssertEqual(PhraseFastPath.currentSentence(in: "One. Two three"), "Two three")
        XCTAssertEqual(PhraseFastPath.currentSentence(in: "v1.2 is out "), "v1.2 is out ", "a period inside a token is no boundary")
        XCTAssertEqual(PhraseFastPath.currentSentence(in: "Hi!\n  Next "), "Next ")
    }
}
