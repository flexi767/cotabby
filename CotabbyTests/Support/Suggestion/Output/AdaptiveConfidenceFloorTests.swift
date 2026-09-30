@testable import Cotabby
import XCTest

final class AdaptiveConfidenceFloorTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let mail = "com.apple.mail"

    func testRisesOnlyAfterTheConfiguredRunOfIgnoresInThatApp() {
        var floor = AdaptiveConfidenceFloor()
        floor.record(.ignored, bundleIdentifier: mail, now: start)
        floor.record(.ignored, bundleIdentifier: mail, now: start)
        XCTAssertNil(floor.floor(for: mail, now: start), "two ignores are not a pattern yet")
        floor.record(.ignored, bundleIdentifier: mail, now: start)
        XCTAssertEqual(floor.floor(for: mail, now: start), -1.5)
        XCTAssertNil(floor.floor(for: "com.tinyspeck.slackmacgap", now: start), "per app, not global")
    }

    func testAnAcceptanceOrHandTypedMatchResetsAtOnce() {
        for reset: SuggestionUsageRecord.Outcome in [.accepted, .acceptedPartially, .typedThrough] {
            var floor = AdaptiveConfidenceFloor()
            for _ in 0..<3 { floor.record(.ignored, bundleIdentifier: mail, now: start) }
            floor.record(reset, bundleIdentifier: mail, now: start)
            XCTAssertNil(floor.floor(for: mail, now: start), "\(reset)")
            floor.record(.ignored, bundleIdentifier: mail, now: start)
            XCTAssertNil(floor.floor(for: mail, now: start), "the ignore count restarted after \(reset)")
        }
    }

    func testTheRaiseExpires() {
        var floor = AdaptiveConfidenceFloor()
        for _ in 0..<3 { floor.record(.ignored, bundleIdentifier: mail, now: start) }
        XCTAssertNotNil(floor.floor(for: mail, now: start.addingTimeInterval(299)))
        XCTAssertNil(floor.floor(for: mail, now: start.addingTimeInterval(300)))
    }

    func testUnseenAndUntouchedSuggestionsCarryNoSignal() {
        var floor = AdaptiveConfidenceFloor()
        floor.record(.ignored, bundleIdentifier: mail, now: start)
        floor.record(.ignored, bundleIdentifier: mail, now: start)
        floor.record(.suppressed, bundleIdentifier: mail, now: start)
        floor.record(.abandoned, bundleIdentifier: mail, now: start)
        XCTAssertNil(floor.floor(for: mail, now: start))
        floor.record(.ignored, bundleIdentifier: mail, now: start)
        XCTAssertNotNil(floor.floor(for: mail, now: start), "suppressed/abandoned neither count nor reset")
    }
}
