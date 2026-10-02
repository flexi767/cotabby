@testable import Cotabby
import XCTest

final class KnownPhoneNumbersTests: XCTestCase {
    func testCompletesAKnownNumberInTheWritersFormat() {
        var numbers = KnownPhoneNumbers()
        numbers.learn(committedText: "My mobile is +359 88 712 3456, call anytime.")
        XCTAssertEqual(numbers.completion(precedingText: "Reach me on +359 88 7"), "12 3456")
        XCTAssertEqual(numbers.completion(precedingText: "Reach me on +3598871"), "23456",
                       "typed as bare digits, finished as bare digits")
        XCTAssertNil(numbers.completion(precedingText: "Reach me on +35"), "two digits are not enough")
        XCTAssertNil(numbers.completion(precedingText: "Reach me on +359 99"), "no known number starts like that")
        XCTAssertNil(numbers.completion(precedingText: "+359 88 712 3456"), "already complete")
    }

    func testTwoEquallyCommonNumbersAreAmbiguous() {
        var numbers = KnownPhoneNumbers()
        numbers.learn(committedText: "Office 0888 123 456. Home 0888 999 000.")
        XCTAssertNil(numbers.completion(precedingText: "call 0888 "), "caret after a space is not inside a number")
        XCTAssertNil(numbers.completion(precedingText: "call 0888"), "both fit, neither is typed more")
        numbers.learn(committedText: "Again: 0888 999 000")
        XCTAssertEqual(numbers.completion(precedingText: "call 0888"), " 999 000", "the more frequent one wins")
        XCTAssertEqual(numbers.completion(precedingText: "call 08881"), "23456", "the next digit settles it")
    }

    func testNeverLearnsDigitsThatCameFromAnAcceptedSuggestion() {
        var numbers = KnownPhoneNumbers()
        numbers.learn(committedText: "Call 0888 123 456", excludingAcceptedDigits: ["123456"])
        numbers.learn(committedText: "Or 0877 555 444", excludingAcceptedDigits: ["555"])
        XCTAssertTrue(numbers.isEmpty, "a number partly or wholly accepted from the model is not the writer's")
        numbers.learn(committedText: "Or 0877 555 444", excludingAcceptedDigits: ["999"])
        XCTAssertTrue(numbers.contains(digits: "0877555444"))
    }

    func testIgnoresDatesAndShortNumbers() {
        var numbers = KnownPhoneNumbers()
        numbers.learn(committedText: "On 2026-10-02 at 09:30, room 314, invoice 4412.")
        XCTAssertTrue(numbers.isEmpty)
    }
}
