@testable import Cotabby
import XCTest

final class PhoneNumberGuardTests: XCTestCase {
    private func known(_ texts: String...) -> KnownPhoneNumbers {
        var numbers = KnownPhoneNumbers()
        for text in texts { numbers.learn(committedText: text) }
        return numbers
    }

    private func vet(_ completion: String, after preceding: String, known: KnownPhoneNumbers = KnownPhoneNumbers()) -> String? {
        PhoneNumberGuard.vetted(completion: completion, precedingText: preceding, known: known)
    }

    func testRejectsAModelInventedNumber() {
        XCTAssertNil(vet("0888 123 456", after: "Call me at "), "digits only: nothing left to show")
        XCTAssertEqual(vet("on 0888 123 456 tomorrow", after: "Call me "), "on", "the words before the number survive")
        XCTAssertNil(vet("23 456", after: "Call me at 0888 1"), "continuing a typed partial with invented digits")
        XCTAssertNil(vet("+44 20 7946 0958", after: "Ring "))
    }

    func testAllowsOnlyTheWritersOwnNumbers() {
        let mine = known("Call me on 0888 123 456 anytime.")
        XCTAssertEqual(vet("0888 123 456", after: "Call me at ", known: mine), "0888 123 456")
        XCTAssertEqual(vet("23 456", after: "Call me at 0888 1", known: mine), "23 456")
        XCTAssertEqual(vet("0888-123-456 please", after: "at ", known: mine), "0888-123-456 please",
                       "formatting does not matter, the digits do")
        XCTAssertEqual(vet("0888 123", after: "at ", known: mine), "0888 123",
                       "a known number cut off by the word limit is still the writer's")
        XCTAssertNil(vet("0888 123 999", after: "at ", known: mine), "one digit off is an invented number")
    }

    func testLeavesOrdinaryNumbersAlone() {
        for (completion, preceding) in [
            ("in 2 weeks", "see you "), ("room 314", "meet in "), ("2026-10-02", "due "),
            ("02.10.2026", "am "), ("at 09:30", "standup "), ("3 or 4 people", "for "),
            ("1Z999AA10123456784", "tracking "), ("0x80070005 again", "error "),
        ] {
            XCTAssertEqual(vet(completion, after: preceding), completion, completion)
        }
    }

    func testFindsPhoneShapedRunsWithSeparators() {
        let runs = PhoneNumberGuard.phoneRuns(in: "Tel: +359 (88) 712-3456 or 0888.123.456")
        XCTAssertEqual(runs.map(\.digits), ["359887123456", "0888123456"])
    }
}
