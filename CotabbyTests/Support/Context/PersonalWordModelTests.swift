@testable import Cotabby
import XCTest

final class PersonalWordModelTests: XCTestCase {
    private func model(_ texts: [String], times: Int = 1) -> PersonalWordModel {
        var model = PersonalWordModel()
        for _ in 0..<times { for text in texts { model.learn(text) } }
        return model
    }

    func testAHabitAcrossDifferentSentencesBecomesANextWord() {
        // Never the same sentence twice, so phrase memory would learn nothing from these.
        let model = model([
            "Ok, see you tomorrow then.",
            "Can't make it today, see you tomorrow.",
            "Great talk, see you tomorrow at nine.",
        ])
        XCTAssertEqual(model.prediction(precedingText: "Thanks! See you ", maximumWords: 1), "tomorrow")
    }

    func testFinishesTheWordBeingTypedAndChainsConfidentWords() {
        let model = model(["I will send the revised deck tomorrow."], times: 3)
        XCTAssertEqual(model.prediction(precedingText: "Then send the rev", maximumWords: 3), "ised deck tomorrow")
        XCTAssertEqual(model.prediction(precedingText: "Then send the ", maximumWords: 2), "revised deck")
    }

    func testStaysQuietWithoutAClearFavourite() {
        let split = model(["see you tomorrow.", "see you later.", "see you soon."], times: 2)
        XCTAssertNil(split.prediction(precedingText: "ok see you ", maximumWords: 1), "three habits tie")
        let thin = model(["see you tomorrow."], times: 2)
        XCTAssertNil(thin.prediction(precedingText: "ok see you ", maximumWords: 1), "two sightings are not a habit yet")
    }

    func testTwoWordContextBeatsOneWord() {
        var model = PersonalWordModel()
        for _ in 0..<4 { model.learn("I will call you later.") }
        for _ in 0..<4 { model.learn("Thank you so much.") }
        XCTAssertEqual(model.prediction(precedingText: "Okay I will call you ", maximumWords: 1), "later")
        XCTAssertEqual(model.prediction(precedingText: "Thank you ", maximumWords: 1), "so")
    }

    func testUsesTheWritersOwnSpelling() {
        let model = model(["Meeting with Sarah tomorrow.", "I asked Sarah again.", "Lunch with Sarah today."], times: 2)
        XCTAssertEqual(model.prediction(precedingText: "Coffee with ", maximumWords: 1), "Sarah")
        XCTAssertEqual(model.completion(of: "sar"), "Sarah")
    }

    func testNeverLearnsNumbersCodesOrAcrossSentences() {
        let model = model(["Code 482913 is ready. Ping me.", "Mail me at a@b.co today."], times: 5)
        XCTAssertNil(PersonalWordModel.wordKey("482913"))
        XCTAssertNil(PersonalWordModel.wordKey("a@b.co"))
        XCTAssertNil(model.prediction(precedingText: "the ready ", maximumWords: 1), "'ready. Ping' spans two sentences")
        XCTAssertNil(model.prediction(precedingText: "Code ", maximumWords: 1), "a code breaks the chain")
    }

    func testOnlyPredictsInsideAWordOrAfterWhitespace() {
        let model = model(["see you tomorrow."], times: 5)
        XCTAssertNil(model.prediction(precedingText: "see you,", maximumWords: 1))
        XCTAssertNil(model.prediction(precedingText: "", maximumWords: 1))
        XCTAssertNotNil(model.prediction(precedingText: "see you ", maximumWords: 1))
    }

    func testVocabularyCompletionNeedsThreeLettersAndARepeatedWord() {
        let model = model(["The quarterly numbers.", "Quarterly review."], times: 2)
        XCTAssertEqual(model.prediction(precedingText: "Our qua", maximumWords: 1), "rterly")
        XCTAssertNil(model.prediction(precedingText: "Our qu", maximumWords: 1), "two letters")
    }

    func testRoundTripsThroughJSON() throws {
        let model = model(["see you tomorrow."], times: 3)
        let decoded = try JSONDecoder().decode(PersonalWordModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(decoded, model)
    }
}
