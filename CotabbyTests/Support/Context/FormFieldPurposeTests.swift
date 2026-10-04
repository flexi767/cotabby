import XCTest
@testable import Cotabby

final class FormFieldPurposeTests: XCTestCase {
    private func purpose(_ placeholder: String?, _ name: String? = nil) -> FormFieldPurpose {
        FormFieldPurpose.classify(placeholder: placeholder, name: name)
    }

    func test_repeatEmailWordingInSeveralLanguagesAndIds() {
        XCTAssertEqual(purpose("Confirm email"), .repeatEmail)
        XCTAssertEqual(purpose(nil, "Repeat e-mail address"), .repeatEmail)
        XCTAssertEqual(purpose(nil, "confirmEmail"), .repeatEmail)
        XCTAssertEqual(purpose(nil, "email_confirmation"), .repeatEmail)
        XCTAssertEqual(purpose(nil, "email2"), .repeatEmail)
        XCTAssertEqual(purpose("E-Mail-Adresse wiederholen"), .repeatEmail)
        XCTAssertEqual(purpose("Herhaal e-mailadres"), .repeatEmail)
        XCTAssertEqual(purpose("Please re-enter your email"), .repeatEmail)
    }

    func test_plainEmailFields() {
        XCTAssertEqual(purpose("Email"), .email)
        XCTAssertEqual(purpose(nil, "E-Mail-Adresse"), .email)
        XCTAssertEqual(purpose("you@example.com", "emailAddress"), .email)
    }

    func test_codeFieldsWinOverEmailWording() {
        XCTAssertEqual(purpose("Enter the characters shown"), .verificationCode)
        XCTAssertEqual(purpose(nil, "g-recaptcha-response"), .verificationCode)
        XCTAssertEqual(purpose(nil, "captcha_input"), .verificationCode)
        XCTAssertEqual(purpose("Verification code we emailed you"), .verificationCode)
        XCTAssertEqual(purpose(nil, "otp"), .verificationCode)
        XCTAssertEqual(purpose("Sicherheitscode"), .verificationCode)
    }

    func test_unrelatedFieldsAreOther() {
        XCTAssertEqual(purpose("Mailing address"), .other)
        XCTAssertEqual(purpose("First name", "footprintNote"), .other)
        XCTAssertEqual(purpose(nil, nil), .other)
        XCTAssertEqual(purpose("Confirm password"), .other)
    }
}
