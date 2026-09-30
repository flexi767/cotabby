import Foundation

/// Backend-independent generation output returned to the suggestion coordinator.

/// The engine's normalized response, including raw model text for debugging.
struct SuggestionResult: Equatable, Sendable {
    let generation: UInt64
    let rawText: String
    let text: String
    let latency: TimeInterval
    /// Raw value of the `CompletionSuppressionReason` that emptied `text`, when one applies.
    /// Carried as a string so the coordinator's quality accounting never needs the normalizer
    /// type, and so engine-specific reasons can ride along without enum churn. The explicit
    /// initializer default keeps existing call sites compiling unchanged.
    let suppressionReason: String?
    /// True when `text` is exact text following the request's preceding text, leading space
    /// included. A base completion model writes its own word boundary, so a completion that starts
    /// without a space continues the word before the caret ("1" + "50K" is 150K). Instruct and chat
    /// engines drop leading spaces, so their results leave this false and `GhostSpaceBoundary`
    /// decides from the characters on either side instead.
    let spacingIsExact: Bool
    /// The local engine's first sampled token, which a one-shot retry can ban (see
    /// `SuggestionRequest.retryBannedSeedToken`). `nil` for engines that do not expose tokens and
    /// for results rebuilt from partials or rebased onto newer text.
    let firstToken: Int32?
    /// True when this result came from a one-shot retry rather than the first attempt.
    let isRetry: Bool

    // This immutable Sendable value is also constructed by pure candidate-reconciliation rules.
    // Construction needs no UI actor; engine delivery and presentation remain main-actor owned.
    nonisolated init(
        generation: UInt64,
        rawText: String,
        text: String,
        latency: TimeInterval,
        suppressionReason: String? = nil,
        spacingIsExact: Bool = false,
        firstToken: Int32? = nil,
        isRetry: Bool = false
    ) {
        self.generation = generation
        self.rawText = rawText
        self.text = text
        self.latency = latency
        self.suppressionReason = suppressionReason
        self.spacingIsExact = spacingIsExact
        self.firstToken = firstToken
        self.isRetry = isRetry
    }
}
