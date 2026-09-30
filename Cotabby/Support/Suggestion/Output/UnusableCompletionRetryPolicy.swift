import Foundation

/// Decides whether a completion the pipeline could not show earns one retry with its opening token
/// banned.
///
/// Two outcomes throw away the whole request even though the model had more to offer: the first
/// token was an immediate end of generation (`emptyGeneration`), or the first word, joined to the
/// word at the caret, is misspelled (`seamMisspelling`). In both the opening token is the problem,
/// and with the shipped greedy sampler the same prompt always reproduces it. Masking just that
/// token from the first sample lets the retry take the model's next-best opening while reusing the
/// whole prompt KV, so it costs about one more generation, not another prompt decode.
///
/// Guards: one retry per request (a retry never retries), only for a result the local engine
/// attributed a first token to, and only while the field still holds exactly the text the request
/// was built from. A result rebased onto newer typing, or a speculative one, is never retried.
enum UnusableCompletionRetryPolicy {
    enum Failure: Equatable {
        case emptyGeneration
        case seamMisspelling
    }

    /// The token to ban on the retry, or nil when no retry should run.
    static func bannedToken(
        for failure: Failure?,
        result: SuggestionResult,
        request: SuggestionRequest?,
        liveGeneration: UInt64,
        isDisabled: Bool
    ) -> Int32? {
        guard !isDisabled, failure != nil, !result.isRetry,
              let token = result.firstToken,
              let request, request.retryBannedSeedToken == nil,
              request.generation == result.generation,
              liveGeneration == result.generation else {
            return nil
        }
        return token
    }

    /// Maps an engine-attributed suppression reason to a retryable failure.
    static func failure(forSuppressionReason reason: String?) -> Failure? {
        reason == CompletionSuppressionReason.emptyGeneration.rawValue ? .emptyGeneration : nil
    }
}
