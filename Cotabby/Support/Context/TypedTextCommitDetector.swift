import Foundation

/// File overview:
/// Spots the moment the writer *finishes* with a piece of their own text, which is the only moment
/// worth learning from. Pure state machine over the focused-field observations the coordinator
/// already receives, so no new polling, timers, or Accessibility reads are introduced.
///
/// Two signals count as finishing:
///
/// 1. **The field emptied.** A chat or comment box that held a real sentence and is now blank was
///    sent. This is the strongest signal available without app-specific integration, and it arrives
///    while focus stays put — exactly where a "you just sent this" hook would sit if apps offered one.
/// 2. **Focus left the field.** The text may be an unsent draft, which is why harvesting is only
///    half the system: `PhraseMemoryRanker` refuses to inject anything seen once, so a draft has to
///    recur under its own steam before it can ever reach a prompt.
///
/// Deliberately NOT treated as finishing: gradual deletion. Backspacing through a sentence shrinks
/// the tracked text one observation at a time, so by the time the field is empty there is nothing
/// long enough left to commit. Select-all-then-delete is indistinguishable from a send and is
/// treated as one — the writer did type it.
struct TypedTextCommitDetector: Equatable {
    /// One block of finished text, ready for `PhraseHarvester`.
    struct Commit: Equatable {
        let text: String
        let bundleIdentifier: String?
    }

    /// Below this, a field never held anything worth harvesting — "ok", "yes", a stray character.
    static let minimumCommitCharacters = 12
    /// What counts as "the field is now empty". Not exactly zero: some hosts leave a space or a
    /// stray character behind after a send.
    static let clearedTextCeiling = 2

    private var trackedIdentityKey: String?
    private var trackedText = ""
    private var trackedBundleIdentifier: String?
    /// The last text committed *because focus moved*. Chromium and Electron hosts lose and re-acquire
    /// the focused element while a draft sits untouched, which would otherwise commit that same draft
    /// once per flap and inflate its count until an unsent one-off looked like a habit. The cleared
    /// (send) path deliberately does not consult this: sending the same short message twice really is
    /// two sightings.
    private var lastFocusChangeCommitText: String?

    /// Folds one observation of the focused field's full text into the machine, returning a commit
    /// when this observation completed one.
    mutating func observe(
        identityKey: String,
        text: String,
        bundleIdentifier: String?
    ) -> Commit? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard identityKey == trackedIdentityKey else {
            let commit = focusChangeCommit()
            trackedIdentityKey = identityKey
            trackedText = normalized
            trackedBundleIdentifier = bundleIdentifier
            return commit
        }

        // The send signal: substantial text, then nothing.
        if normalized.count <= Self.clearedTextCeiling,
           trackedText.count >= Self.minimumCommitCharacters {
            let commit = Commit(text: trackedText, bundleIdentifier: trackedBundleIdentifier)
            trackedText = normalized
            trackedBundleIdentifier = bundleIdentifier
            return commit
        }

        trackedText = normalized
        trackedBundleIdentifier = bundleIdentifier
        return nil
    }

    /// Commits whatever the tracked field still holds and forgets it. Called when the pipeline tears
    /// down (app quit, suggestions disabled, permissions lost) so a finished message is not lost
    /// just because no further observation arrives.
    mutating func flush() -> Commit? {
        let commit = focusChangeCommit()
        trackedIdentityKey = nil
        trackedText = ""
        trackedBundleIdentifier = nil
        return commit
    }

    /// The draft-shaped commit: emitted when the tracked field is abandoned, and suppressed when it
    /// would repeat the previous one (see `lastFocusChangeCommitText`).
    private mutating func focusChangeCommit() -> Commit? {
        guard trackedText.count >= Self.minimumCommitCharacters,
              trackedText != lastFocusChangeCommitText else { return nil }
        lastFocusChangeCommitText = trackedText
        return Commit(text: trackedText, bundleIdentifier: trackedBundleIdentifier)
    }
}
