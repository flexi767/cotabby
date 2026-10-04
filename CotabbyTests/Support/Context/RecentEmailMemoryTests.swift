import XCTest
@testable import Cotabby

final class RecentEmailMemoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// The writer types an email into field A, then moves to field B in the same app.
    private func memoryAfterEnteringEmail(_ text: String = "Jan.Peeters@example.be") -> RecentEmailMemory {
        var memory = RecentEmailMemory()
        memory.observe(processIdentifier: 42, elementIdentifier: "A", text: "Jan", isSecure: false, now: start)
        memory.observe(processIdentifier: 42, elementIdentifier: "A", text: text, isSecure: false, now: start)
        memory.observe(processIdentifier: 42, elementIdentifier: "B", text: "", isSecure: false, now: start)
        return memory
    }

    private func suggestion(_ memory: RecentEmailMemory, typed: String, purpose: FormFieldPurpose,
                            element: String = "B", pid: Int32 = 42, after seconds: TimeInterval = 5) -> String? {
        memory.suggestion(typed: typed, trailing: "", processIdentifier: pid, elementIdentifier: element,
                          purpose: purpose, now: start.addingTimeInterval(seconds))
    }

    func test_aRepeatField_getsTheWholeEmailBeforeAnythingIsTyped() {
        let memory = memoryAfterEnteringEmail()
        XCTAssertEqual(suggestion(memory, typed: "", purpose: .repeatEmail), "Jan.Peeters@example.be")
    }

    func test_typedPrefix_isCompletedKeepingTheEmailsOwnCase() {
        let memory = memoryAfterEnteringEmail()
        XCTAssertEqual(suggestion(memory, typed: "jan.p", purpose: .email), "eeters@example.be")
        XCTAssertNil(suggestion(memory, typed: "", purpose: .email))
        XCTAssertNil(suggestion(memory, typed: "piet", purpose: .email))
    }

    func test_anUnlabeledField_needsThreeMatchingCharacters() {
        let memory = memoryAfterEnteringEmail()
        XCTAssertNil(suggestion(memory, typed: "Ja", purpose: .other))
        XCTAssertEqual(suggestion(memory, typed: "Jan", purpose: .other), ".Peeters@example.be")
    }

    func test_neverInACodeFieldTheSameFieldAnotherAppOrAfterItExpires() {
        let memory = memoryAfterEnteringEmail()
        XCTAssertNil(suggestion(memory, typed: "", purpose: .verificationCode))
        XCTAssertNil(suggestion(memory, typed: "", purpose: .repeatEmail, element: "A"))
        XCTAssertNil(suggestion(memory, typed: "", purpose: .repeatEmail, pid: 7))
        XCTAssertNil(suggestion(memory, typed: "", purpose: .repeatEmail, after: RecentEmailMemory.lifetime + 1))
        XCTAssertNil(suggestion(memory, typed: "Jan.Peeters@example.be", purpose: .repeatEmail))
    }

    func test_onlyAFieldHoldingExactlyOneEmail_isRemembered() {
        XCTAssertNil(memoryAfterEnteringEmail("Mail me at jan@example.be").entry)
        XCTAssertNil(memoryAfterEnteringEmail("jan@example").entry)
        XCTAssertEqual(memoryAfterEnteringEmail("  jan@example.be ").entry?.email, "jan@example.be")
    }

    func test_aSecureField_isNeverRemembered() {
        var memory = RecentEmailMemory()
        memory.observe(processIdentifier: 42, elementIdentifier: "A", text: "jan@example.be", isSecure: true, now: start)
        memory.observe(processIdentifier: 42, elementIdentifier: "B", text: "", isSecure: false, now: start)
        XCTAssertNil(memory.entry)
    }
}
