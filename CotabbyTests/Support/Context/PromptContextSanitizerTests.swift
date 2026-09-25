import XCTest
@testable import Cotabby

final class PromptContextSanitizerTests: XCTestCase {

    // MARK: - sanitize

    func test_sanitize_stripsANSIEscapeSequences() {
        let input = "\u{001B}[31mERROR\u{001B}[0m something broke"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertFalse(result.contains("\u{001B}"))
        XCTAssertTrue(result.contains("ERROR"))
        XCTAssertTrue(result.contains("something broke"))
    }

    func test_sanitize_replacesDisallowedUnicodeWithSpacesPreservingWordBoundaries() {
        let result = PromptContextSanitizer.sanitize("raw-output")
        XCTAssertEqual(result, "raw output")
    }

    func test_sanitize_collapsesRepeatedWhitespaceIntoSingleSpaces() {
        let result = PromptContextSanitizer.sanitize("hello    world")
        XCTAssertEqual(result, "hello world")
    }

    func test_sanitize_filtersEmptyAndWhitespaceOnlyLines() {
        let input = "first\n   \n\nsecond"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertEqual(result, "first\nsecond")
    }

    func test_sanitize_respectsMaxCharactersLimit() {
        let input = "abcdefghij"
        let result = PromptContextSanitizer.sanitize(input, maxCharacters: 5)
        XCTAssertEqual(result, "abcde")
    }

    func test_sanitize_returnsFullInputWhenMaxCharactersEqualsLength() {
        let input = "hello"
        let result = PromptContextSanitizer.sanitize(input, maxCharacters: 5)
        XCTAssertEqual(result, "hello")
    }

    func test_sanitize_returnsEmptyStringForWhitespaceOnlyInput() {
        XCTAssertEqual(PromptContextSanitizer.sanitize("   \n  \n  "), "")
    }

    func test_sanitize_returnsEmptyStringForEmptyInput() {
        XCTAssertEqual(PromptContextSanitizer.sanitize(""), "")
    }

    func test_sanitize_preservesAllowedCharacters() {
        let input = "Hello world 123 user@host.com"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertEqual(result, input)
    }

    func test_sanitize_handlesANSIMixedWithRealText() {
        let input = "\u{001B}[32mHello\u{001B}[0m world"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertEqual(result, "Hello world")
    }

    // MARK: - sanitizeOCR

    func test_sanitizeOCR_keepsNumbersInALineThatCarriesWords() {
        // Numbers are the most quotable thing on a screen — a price, a time, an invoice number,
        // a quarter — and a reply is usually built around them. They used to be deleted as
        // "numeric UI chrome", which left the model with a sentence full of holes.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("hello 50 world 424"), "hello 50 world 424")
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR("Invoice 4412 is overdue"),
            "Invoice 4412 is overdue"
        )
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR("Can you send the Q3 budget review"),
            "Can you send the Q3 budget review"
        )
    }

    func test_sanitizeOCR_keepsShortTokensInsideAQualifyingLine() {
        // Short tokens ride along with the line that earned its place. Removing the ones that are
        // not on the preserved list punched holes in ordinary sentences for no gain.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("I like if x"), "I like if x")
    }

    func test_sanitizeOCR_keepsANumericLineThatCarriesOneRealWord() {
        // "50 x 99 hello" is a dimension next to a word, not chrome: one signal token is enough to
        // keep the line, and what it keeps includes the measurements.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("50 x 99 hello"), "50 x 99 hello")
    }

    func test_sanitizeOCR_keepsPricesAndAcronymsThatCarryNoVowel() {
        // "BMW", "EUR" and "320d" have no vowel and no known word, so each alone looked like OCR
        // junk; together they are a car listing, which is exactly what a reply would quote.
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR("BMW 320d Touring 2019"),
            "BMW 320d Touring 2019"
        )
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("24 900 EUR"), "24 900 EUR")
    }

    func test_sanitizeOCR_keepsLineWhenHalfOrMoreTokensSurvive() {
        // 2 of 4 tokens survive (exactly 50%): kept.count * 2 >= tokens.count
        let input = "hello world 50 99"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertTrue(result.contains("hello"))
        XCTAssertTrue(result.contains("world"))
    }

    func test_sanitizeOCR_respectsMaxCharacters() {
        let input = "alpha beta gamma delta epsilon"
        let result = PromptContextSanitizer.sanitizeOCR(input, maxCharacters: 10)
        XCTAssertLessThanOrEqual(result.count, 10)
    }

    func test_sanitizeOCR_returnsEmptyForAllNoiseInput() {
        let input = "50 424 102 99"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertEqual(result, "")
    }

    func test_sanitizeOCR_dropsRandomMixedCaseAndAlphanumericGarbage() {
        let input = """
        gLVWrt bDokE 54tbdbDX
        Visible task update Screen Recording copy for Cotabby
        """

        let result = PromptContextSanitizer.sanitizeOCR(input)

        XCTAssertFalse(result.contains("gLVWrt"))
        XCTAssertFalse(result.contains("bDokE"))
        XCTAssertFalse(result.contains("54tbdbDX"))
        XCTAssertTrue(result.contains("Visible task update Screen Recording copy for Cotabby"))
    }

    func test_sanitizeOCR_preservesUsefulTechnicalAndUserContext() {
        let input = """
        Cotabby PR API context needs GeneralPaneView.swift normalizedBundleIdentifier jane@example.com
        """

        let result = PromptContextSanitizer.sanitizeOCR(input)

        XCTAssertTrue(result.contains("Cotabby"))
        XCTAssertTrue(result.contains("PR"))
        XCTAssertTrue(result.contains("API"))
        XCTAssertTrue(result.contains("GeneralPaneView.swift"))
        XCTAssertTrue(result.contains("normalizedBundleIdentifier"))
        XCTAssertTrue(result.contains("jane@example.com"))
    }

    func test_sanitizeOCR_dropsLineWhereMostTokensAreOCRNoise() {
        let input = "gLVWrt 54tbdbDX bDokE User"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertEqual(result, "")
    }

    func test_sanitizeOCR_preservesNonLatinScripts() {
        // CJK, Cyrillic, and accented Latin carry real context but have no ASCII vowel and never
        // match the English word lists. They must survive OCR filtering so non-English users are
        // not left with empty visual context.
        let input = """
        会議の議題を確認してください
        Привет команда смотрите задачу
        Préparez la réunion à Zürich
        """

        let result = PromptContextSanitizer.sanitizeOCR(input)

        XCTAssertTrue(result.contains("会議の議題を確認してください"))
        XCTAssertTrue(result.contains("Привет"))
        XCTAssertTrue(result.contains("задачу"))
        XCTAssertTrue(result.contains("réunion"))
        XCTAssertTrue(result.contains("Zürich"))
    }

    func test_sanitizeOCR_keepsNonLatinButStillDropsAsciiNoiseOnSameLine() {
        // The non-Latin allowance must not become a backdoor for ASCII OCR garbage on the same line.
        let input = "東京 gLVWrt オフィス 54tbdbDX"
        let result = PromptContextSanitizer.sanitizeOCR(input)

        XCTAssertTrue(result.contains("東京"))
        XCTAssertTrue(result.contains("オフィス"))
        XCTAssertFalse(result.contains("gLVWrt"))
        XCTAssertFalse(result.contains("54tbdbDX"))
    }

    func test_sanitizeOCR_dropsLineOfOnlyWeakShortWords() {
        // One and two letter tokens never count as evidence that a line is real, so a line made
        // entirely of them is UI chrome ("we", "go", "to") and is dropped whole.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("we go to it"), "")
    }

    func test_sanitizeOCR_dropsRepeatedGlyphRuns() {
        // "aaaa" is the repeated-glyph hallucination shape; the real words around it must survive.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("meeting notes aaaa"), "meeting notes")
    }

    func test_sanitizeOCR_returnsEmptyWhenBaseSanitizationLeavesNothing() {
        // Symbols-only input sanitizes to an empty base string, which becomes one empty line; the
        // OCR line filter must treat that as no tokens, not crash or emit whitespace.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("*** ---"), "")
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR(""), "")
    }

    func test_sanitizeOCR_keepsLetterlessDottedToken() {
        // "12.34" carries no letters and no word signal, but in a line of real words it is a price
        // or a version, and the line is what decides.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("meeting notes 12.34"), "meeting notes 12.34")
    }

    func test_sanitizeOCR_dropsLowercaseLedTokenWithInteriorCapital() {
        // "abeW" has vowels, so only the mixed-case rule can reject it: a non-leading capital in a
        // short token without a known technical word is OCR garbage, unlike "Safari"-style prose.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("meeting notes abeW"), "meeting notes")
    }

    // MARK: - containsAlphanumericSignal

    func test_containsAlphanumericSignal_returnsTrueForMixedInput() {
        XCTAssertTrue(PromptContextSanitizer.containsAlphanumericSignal("---a---"))
    }

    func test_containsAlphanumericSignal_returnsFalseForPureSymbols() {
        XCTAssertFalse(PromptContextSanitizer.containsAlphanumericSignal("--- ---"))
    }

    func test_containsAlphanumericSignal_returnsFalseForEmptyString() {
        XCTAssertFalse(PromptContextSanitizer.containsAlphanumericSignal(""))
    }
}
