import Foundation

/// File overview:
/// The value types behind Cotabby's learned-phrase memory: one remembered phrase and the immutable
/// snapshot the pure ranker consumes. Kept separate from `PhraseMemoryStore` so harvesting,
/// ranking, and scoring can be unit-tested without touching persistence.
///
/// Why this exists at all: every other prompt input is ephemeral (caret prefix, clipboard, screen
/// OCR) or hand-authored (Extended Context). Nothing told the model what this particular writer
/// types over and over, so the hundredth send of a standard reply looked exactly like the first.
/// This is the one durable, self-populating context source.

/// A phrase the writer has finished typing at least once, with the counters that decide whether it
/// is worth spending prompt budget on.
struct LearnedPhrase: Codable, Equatable, Sendable {
    /// Match key: lowercased, whitespace-collapsed, outer punctuation stripped. Two spellings of
    /// the same sentence ("Ich melde mich morgen." / "ich melde mich morgen") share one entry.
    let key: String
    /// Display form handed to the prompt — the most recent spelling seen, so capitalization tracks
    /// how the writer actually writes it today.
    var text: String
    /// How many separate commits contained this phrase. The ranker requires more than one before a
    /// phrase may enter a prompt, which is what keeps one-off drafts out of the model's view.
    var count: Int
    var lastUsedAt: Date
    /// Bundle identifiers this phrase was typed in, most recent first and capped: a sign-off learned
    /// in Mail should outrank it when the writer is back in Mail. Not a filter — phrases still carry
    /// across apps, they just rank lower there.
    var bundleIdentifiers: [String]

    static let maximumTrackedBundleIdentifiers = 4

    init(
        key: String,
        text: String,
        count: Int = 1,
        lastUsedAt: Date,
        bundleIdentifiers: [String] = []
    ) {
        self.key = key
        self.text = text
        self.count = count
        self.lastUsedAt = lastUsedAt
        self.bundleIdentifiers = bundleIdentifiers
    }

    /// Folds one new sighting into this phrase: bumps the count, refreshes the display spelling and
    /// timestamp, and moves the app to the front of the bounded app list.
    mutating func merge(text newText: String, bundleIdentifier: String?, at date: Date) {
        count += 1
        text = newText
        lastUsedAt = date
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        bundleIdentifiers.removeAll { $0 == bundleIdentifier }
        bundleIdentifiers.insert(bundleIdentifier, at: 0)
        if bundleIdentifiers.count > Self.maximumTrackedBundleIdentifiers {
            bundleIdentifiers.removeLast(bundleIdentifiers.count - Self.maximumTrackedBundleIdentifiers)
        }
    }
}

/// Immutable view of the memory for the pure ranker.
struct PhraseMemorySnapshot: Equatable, Sendable {
    var phrases: [LearnedPhrase]

    static let empty = PhraseMemorySnapshot(phrases: [])

    var isEmpty: Bool { phrases.isEmpty }
}
