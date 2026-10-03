@testable import Cotabby
import XCTest

final class VATCounterpartRuleTests: XCTestCase {
    func testRecognisesTheTwoOfferFieldsAsMeasuredOnTheLiveForm() {
        XCTAssertEqual(VATCounterpartRule.role(title: "Mijn offerte (marge)", domIdentifier: "bidM"), .gross)
        XCTAssertEqual(VATCounterpartRule.role(title: "Mijn offerte Opmerking", domIdentifier: "bidI"), .net)
        XCTAssertEqual(VATCounterpartRule.role(title: nil, domIdentifier: "bidM"), .gross, "the DOM id alone suffices")
        XCTAssertEqual(VATCounterpartRule.role(title: "Mijn offerte (marge)", domIdentifier: nil), .gross)
        XCTAssertEqual(VATCounterpartRule.role(title: "Mijn offerte", domIdentifier: nil), .net)
        XCTAssertNil(VATCounterpartRule.role(title: "Opmerking", domIdentifier: "remark"))
    }

    func testOnlyOnThePortal() {
        XCTAssertTrue(VATCounterpartRule.applies(toURL: "https://my.informex-vehicle-online.be/offers/123"))
        XCTAssertTrue(VATCounterpartRule.applies(toURL: "https://informex-vehicle-online.be/"))
        XCTAssertFalse(VATCounterpartRule.applies(toURL: "https://example.com/informex-vehicle-online.be"))
        XCTAssertFalse(VATCounterpartRule.applies(toURL: "https://evil-informex-vehicle-online.be.example.com/"))
        XCTAssertFalse(VATCounterpartRule.applies(toURL: nil))
    }

    func testAddsAndRemovesVATInWholeEuros() {
        XCTAssertEqual(VATCounterpartRule.suggestion(for: .gross, counterpartValue: "12500", typed: ""), "15125")
        XCTAssertEqual(VATCounterpartRule.suggestion(for: .net, counterpartValue: "15125", typed: ""), "12500")
        XCTAssertEqual(VATCounterpartRule.suggestion(for: .net, counterpartValue: "15000", typed: ""), "12397",
                       "12396.69 rounds to whole euros")
        XCTAssertEqual(VATCounterpartRule.suggestion(for: .gross, counterpartValue: "10001", typed: ""), "12101")
        XCTAssertEqual(VATCounterpartRule.suggestion(for: .gross, counterpartValue: "10", typed: ""), "12",
                       "the live form's own test values: 10 net, 12 marge")
    }

    func testFinishesWhatTheWriterStartedAndNothingElse() {
        XCTAssertEqual(VATCounterpartRule.suggestion(for: .gross, counterpartValue: "12500", typed: "15"), "125")
        XCTAssertNil(VATCounterpartRule.suggestion(for: .gross, counterpartValue: "12500", typed: "16"),
                     "typed something else: no suggestion")
        XCTAssertNil(VATCounterpartRule.suggestion(for: .gross, counterpartValue: "12500", typed: "15125"), "complete")
        XCTAssertNil(VATCounterpartRule.suggestion(for: .gross, counterpartValue: "", typed: ""), "nothing entered")
        XCTAssertNil(VATCounterpartRule.suggestion(for: .gross, counterpartValue: "0", typed: ""))
    }

    func testReadsTheAmountFormatsThePortalOrWriterUse() {
        for (raw, expected) in [("12500", "12500"), ("12.500", "12500"), ("12 500", "12500"), ("€ 12.500,00", "12500"),
                                ("12500,50", "12500.5"), ("12500.50", "12500.5"), ("1.234.567", "1234567")] {
            XCTAssertEqual(VATCounterpartRule.amount(from: raw), Decimal(string: expected), raw)
        }
        XCTAssertNil(VATCounterpartRule.amount(from: "n.v.t."))
    }

    func testAComputedAmountIsTrustedByTheNumberGuardOnlyWhenTrusted() {
        let completion = "121000"
        XCTAssertNil(PhoneNumberGuard.vetted(completion: completion, precedingText: "", known: KnownPhoneNumbers()),
                     "six digits from nowhere look like an invented number")
        XCTAssertEqual(PhoneNumberGuard.vetted(completion: completion, precedingText: "",
                                               known: KnownPhoneNumbers().trusting(digits: "121000")), completion)
    }
}

final class VATCounterpartAutofillTests: XCTestCase {
    private func fill(_ role: VATCounterpartRule.Role, _ value: String, was before: String, other: String) -> String? {
        VATCounterpartRule.autofillValue(editedRole: role, editedValue: value, editedValueAtFocus: before,
                                         counterpartValueAtFocus: other)
    }

    func testFillsAnEmptyOtherFieldBothWays() {
        XCTAssertEqual(fill(.net, "12500", was: "", other: ""), "15125")
        XCTAssertEqual(fill(.gross, "15125", was: "", other: ""), "12500")
    }

    func testUpdatesALinkedPairButNeverOverwritesAManualAmount() {
        XCTAssertEqual(fill(.net, "13000", was: "12500", other: "15125"), "15730", "the pair matched before: keep it in step")
        XCTAssertNil(fill(.net, "13000", was: "12500", other: "15000"), "15000 was typed on purpose")
        XCTAssertEqual(fill(.net, "12500", was: "12500", other: ""), "15125",
                       "an amount entered earlier still fills an empty partner when the field is visited")
        XCTAssertNil(fill(.net, "12500", was: "12500", other: "16000"), "not edited: a filled partner is left alone")
        XCTAssertNil(fill(.net, "", was: "12500", other: "15125"), "clearing one never clears the other")
        XCTAssertNil(fill(.net, "abc", was: "", other: ""), "not an amount")
    }
}
