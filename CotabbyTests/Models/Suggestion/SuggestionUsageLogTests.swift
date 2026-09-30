@testable import Cotabby
import XCTest

@MainActor
final class SuggestionUsageLogTests: XCTestCase {
    private var fileURL: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuggestionUsageLogTests-\(UUID().uuidString)")
            .appendingPathComponent("suggestion-usage.jsonl")
        defaults = UserDefaults(suiteName: "SuggestionUsageLogTests.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func makeLog(enabled: Bool = true) -> SuggestionUsageLog {
        let log = SuggestionUsageLog(userDefaults: defaults, fileURL: fileURL)
        log.setEnabled(enabled)
        return log
    }

    private func context(
        _ precedingText: String,
        element: String = "field",
        bundleIdentifier: String = "com.apple.mail",
        isSecure: Bool = false
    ) -> FocusedInputContext {
        CotabbyTestFixtures.focusedInputContext(
            applicationName: "Mail",
            bundleIdentifier: bundleIdentifier,
            elementIdentifier: element,
            precedingText: precedingText,
            trailingText: "",
            isSecure: isSecure
        )
    }

    private func show(_ log: SuggestionUsageLog, at text: String, _ shown: String?, reason: String? = nil,
                      isRetry: Bool = false, element: String = "field") {
        log.recordGeneration(context: context(text, element: element), shownText: shown, suppressionReason: reason,
                             rawText: shown ?? "", isRetry: isRetry, latency: 0.15)
    }

    private func records(_ log: SuggestionUsageLog) throws -> [SuggestionUsageRecord] {
        log.waitForPendingWrites()
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 0x0A).map { try decoder.decode(SuggestionUsageRecord.self, from: Data($0)) }
    }

    // MARK: - Opt-in

    func testOffByDefaultAndWritesNothing() throws {
        let log = SuggestionUsageLog(userDefaults: defaults, fileURL: fileURL)
        XCTAssertFalse(log.isEnabled, "absent key must mean off")
        show(log, at: "See you ", "tomorrow")
        log.observe(elementIdentifier: "field", precedingText: "See you tomorrow")
        log.finishPending()
        XCTAssertEqual(try records(log), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSwitchingOffDropsTheUnfinishedRecordAndPersists() throws {
        let log = makeLog()
        show(log, at: "See you ", "tomorrow")
        log.setEnabled(false)
        log.finishPending()
        XCTAssertEqual(try records(log), [])
        XCTAssertFalse(SuggestionUsageLog(userDefaults: defaults, fileURL: fileURL).isEnabled)
    }

    func testSecureFieldsTerminalsAndCodeEditorsAreNeverRecorded() throws {
        let log = makeLog()
        log.recordGeneration(context: context("pass", isSecure: true), shownText: "word", suppressionReason: nil,
                             rawText: "", isRetry: false, latency: 0)
        log.finishPending()
        log.recordGeneration(context: context("git push ", bundleIdentifier: "com.apple.Terminal"), shownText: "origin",
                             suppressionReason: nil, rawText: "", isRetry: false, latency: 0)
        log.finishPending()
        log.recordGeneration(context: context("let x = ", bundleIdentifier: "com.microsoft.VSCode"), shownText: "1",
                             suppressionReason: nil, rawText: "", isRetry: false, latency: 0)
        log.finishPending()
        XCTAssertEqual(try records(log), [])
    }

    // MARK: - Outcomes

    func testTypingTheSuggestionByHandIsTypedThrough() throws {
        let log = makeLog()
        show(log, at: "See you ", "tomorrow morning")
        log.observe(elementIdentifier: "field", precedingText: "See you tom")
        log.observe(elementIdentifier: "field", precedingText: "See you tomorrow morning.")
        log.observe(elementIdentifier: "field", precedingText: "") // sent: the field emptied
        let record = try XCTUnwrap(try records(log).first)
        XCTAssertEqual(record.outcome, .typedThrough)
        XCTAssertEqual(record.typedAfter, "tomorrow morning.")
        XCTAssertEqual(record.matchedCharacters, 16)
        XCTAssertEqual(record.precedingText, "See you ")
        XCTAssertEqual(record.latencyMilliseconds, 150)
    }

    func testTypingSomethingElseIsIgnoredWithWhatWasTyped() throws {
        let log = makeLog()
        show(log, at: "See you ", "tomorrow")
        log.observe(elementIdentifier: "field", precedingText: "See you on Friday")
        log.observe(elementIdentifier: "other", precedingText: "")
        let record = try XCTUnwrap(try records(log).first)
        XCTAssertEqual(record.outcome, .ignored)
        XCTAssertEqual(record.typedAfter, "on Friday")
        XCTAssertEqual(record.matchedCharacters, 0)
    }

    func testAcceptanceIsCreditedFullOrPartial() throws {
        let log = makeLog()
        show(log, at: "See you ", "tomorrow morning")
        log.recordAccepted(characters: 16)
        show(log, at: "See you tomorrow morning", " then")
        log.recordAccepted(characters: 2)
        log.finishPending()
        let outcomes = try records(log).map(\.outcome)
        XCTAssertEqual(outcomes, [.accepted, .acceptedPartially])
    }

    func testNothingTypedIsAbandoned() throws {
        let log = makeLog()
        show(log, at: "See you ", "tomorrow")
        log.observe(elementIdentifier: "field", precedingText: "See yo") // backspaced into the anchor
        XCTAssertEqual(try records(log).map(\.outcome), [.abandoned])
    }

    func testSuppressedGenerationsKeepTheReasonAndWhatWasTyped() throws {
        let log = makeLog()
        show(log, at: "Kurzes Update: ", nil, reason: "seamMisspelling")
        log.observe(elementIdentifier: "field", precedingText: "Kurzes Update: der Build")
        log.finishPending()
        let record = try XCTUnwrap(try records(log).first)
        XCTAssertEqual(record.outcome, .suppressed)
        XCTAssertEqual(record.suppressionReason, "seamMisspelling")
        XCTAssertNil(record.shownText)
        XCTAssertEqual(record.typedAfter, "der Build")
    }

    func testARetryAtTheSameCaretReplacesItsUnusableFirstAttempt() throws {
        let log = makeLog()
        show(log, at: "report by ", nil, reason: "emptyGeneration")
        show(log, at: "report by ", "Friday", isRetry: true)
        log.observe(elementIdentifier: "field", precedingText: "report by Friday")
        log.finishPending()
        let written = try records(log)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?.isRetry, true)
        XCTAssertEqual(written.first?.retriedAfter, "emptyGeneration")
        XCTAssertEqual(written.first?.outcome, .typedThrough)
    }

    func testTextIsBoundedPerRecord() throws {
        let log = makeLog()
        let long = String(repeating: "a", count: 1000) + " "
        show(log, at: long, "word")
        log.observe(elementIdentifier: "field", precedingText: long + String(repeating: "b", count: 500))
        log.finishPending()
        let record = try XCTUnwrap(try records(log).first)
        XCTAssertEqual(record.precedingText.count, SuggestionUsageRecord.precedingLimit)
        XCTAssertEqual(record.typedAfter.count, SuggestionUsageRecord.typedAfterLimit)
    }

    func testConfidenceIsRecordedWithTheOutcome() throws {
        let log = makeLog()
        log.recordGeneration(context: context("See you "), shownText: "soon", suppressionReason: nil,
                             rawText: "soon", isRetry: false, latency: 0.1, averageLogprob: -0.42)
        log.finishPending()
        XCTAssertEqual(try records(log).first?.averageLogprob, -0.42)
    }

    func testTrackingWhileOffReportsOutcomesButWritesNothing() throws {
        let log = makeLog(enabled: false)
        log.tracksOutcomesWhileOff = true
        var outcomes: [SuggestionUsageRecord.Outcome] = []
        log.onOutcome = { outcomes.append($0.outcome) }
        show(log, at: "See you ", "tomorrow")
        log.observe(elementIdentifier: "field", precedingText: "See you later")
        log.finishPending()
        XCTAssertEqual(outcomes, [.ignored])
        XCTAssertEqual(try records(log), [])
        XCTAssertEqual(log.recordCount, 0)
    }

    // MARK: - Storage

    func testCountSurvivesRelaunchAndDeleteRemovesEverything() throws {
        let log = makeLog()
        show(log, at: "a ", "b")
        show(log, at: "c ", "d")
        log.finishPending()
        log.waitForPendingWrites()
        XCTAssertEqual(log.recordCount, 2)
        XCTAssertEqual(SuggestionUsageLog(userDefaults: defaults, fileURL: fileURL).recordCount, 2)
        log.deleteAll()
        XCTAssertEqual(log.recordCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFileIsPrivateToTheUser() throws {
        let log = makeLog()
        show(log, at: "a ", "b")
        log.finishPending()
        log.waitForPendingWrites()
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    // MARK: - Pure classification

    func testOutcomeClassification() {
        typealias R = SuggestionUsageRecord
        XCTAssertEqual(R.outcome(shownText: nil, typedAfter: "x", acceptedCharacters: 0), .suppressed)
        XCTAssertEqual(R.outcome(shownText: " soon", typedAfter: "soon!", acceptedCharacters: 0), .typedThrough,
                       "a leading space on either side does not count as a mismatch")
        XCTAssertEqual(R.outcome(shownText: "soon", typedAfter: "so", acceptedCharacters: 0), .ignored,
                       "stopping part way is not typing it through")
        XCTAssertEqual(R.outcome(shownText: "soon", typedAfter: "", acceptedCharacters: 0), .abandoned)
        XCTAssertEqual(R.outcome(shownText: "soon", typedAfter: "", acceptedCharacters: 4), .accepted)
    }
}
