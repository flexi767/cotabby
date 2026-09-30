@testable import Cotabby
import XCTest

final class UnusableCompletionRetryPolicyTests: XCTestCase {
    private func result(generation: UInt64 = 1, firstToken: Int32? = 42, isRetry: Bool = false) -> SuggestionResult {
        SuggestionResult(generation: generation, rawText: "", text: "", latency: 0, firstToken: firstToken, isRetry: isRetry)
    }

    private func bannedToken(
        failure: UnusableCompletionRetryPolicy.Failure? = .seamMisspelling,
        result: SuggestionResult? = nil,
        request: SuggestionRequest? = CotabbyTestFixtures.suggestionRequest(generation: 1),
        liveGeneration: UInt64 = 1,
        isDisabled: Bool = false
    ) -> Int32? {
        UnusableCompletionRetryPolicy.bannedToken(
            for: failure,
            result: result ?? self.result(),
            request: request,
            liveGeneration: liveGeneration,
            isDisabled: isDisabled
        )
    }

    func testRetriesBothFailuresWithTheFirstTokenBanned() {
        XCTAssertEqual(bannedToken(failure: .seamMisspelling), 42)
        XCTAssertEqual(bannedToken(failure: .emptyGeneration), 42)
    }

    func testDoesNotRetryAUsableOrUnattributedCompletion() {
        XCTAssertNil(bannedToken(failure: nil))
        XCTAssertNil(bannedToken(result: result(firstToken: nil)), "no token to ban (non-local engine or partial)")
    }

    func testARetryNeverRetries() {
        XCTAssertNil(bannedToken(result: result(isRetry: true)))
        var retryRequest = CotabbyTestFixtures.suggestionRequest(generation: 1)
        retryRequest.retryBannedSeedToken = 7
        XCTAssertNil(bannedToken(request: retryRequest))
    }

    func testDoesNotRetryOnceTheFieldHasMovedOn() {
        XCTAssertNil(bannedToken(liveGeneration: 2), "the user typed since the request was built")
        XCTAssertNil(bannedToken(result: result(generation: 2), liveGeneration: 2), "result rebased onto newer text")
        XCTAssertNil(bannedToken(request: nil))
    }

    func testKillSwitchDisablesRetry() {
        XCTAssertNil(bannedToken(isDisabled: true))
    }

    func testOnlyAnEmptyGenerationIsARetryableEngineSuppression() {
        XCTAssertEqual(UnusableCompletionRetryPolicy.failure(forSuppressionReason: "emptyGeneration"), .emptyGeneration)
        XCTAssertNil(UnusableCompletionRetryPolicy.failure(forSuppressionReason: nil))
        // The model produced something a filter rejected on purpose; banning its first token would
        // just route around the filter.
        for reason in ["lowConfidence", "duplicatesTrailingText", "scaffolding", "noWordContent", "echoesPrecedingText"] {
            XCTAssertNil(UnusableCompletionRetryPolicy.failure(forSuppressionReason: reason), reason)
        }
    }
}
