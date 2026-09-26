import Combine
import Foundation

/// Narrow persistence surface for `PhraseMemoryStore`, so it can be unit-tested against an
/// in-memory store instead of process-global `UserDefaults` (which is shared across tests and
/// unreliable to mutate from a sandboxed unit-test host). Mirrors `EmojiUsageDefaults`.
protocol PhraseMemoryDefaults: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: PhraseMemoryDefaults {}

/// File overview:
/// Persists the phrases this writer finishes typing, so a sentence they have written before can be
/// offered back instead of being re-derived from scratch every time. Harvesting decides *what* is a
/// phrase (`PhraseHarvester`), ranking decides *which* ones reach a prompt (`PhraseMemoryRanker`);
/// this type only owns storage, counters, and the cap.
///
/// Stored as a single JSON blob in `UserDefaults` for the same reasons as `EmojiUsageStore`: the
/// read/write is atomic and it avoids per-key dictionary bridging quirks. The data never leaves the
/// Mac — there is no network path out of this type — and "Forget learned phrases" in Settings
/// removes the key outright.
///
/// `@MainActor` because the only writer is the main-actor `SuggestionCoordinator` at commit
/// detection time, and reads are cheap snapshots taken between keystrokes. The `deinit` is
/// `nonisolated` to dodge the same macOS 14 isolated-deinit back-deploy crash documented on
/// `EmojiUsageStore`.
@MainActor
final class PhraseMemoryStore: ObservableObject {
    /// Published so the Settings pane can show the memory filling up — and show it go to zero the
    /// instant the user forgets it — without polling. Counts only; the phrases never reach the UI.
    @Published private(set) var phraseCount: Int = 0
    /// How many phrases have been seen often enough to be eligible for a prompt. Shown separately
    /// because "247 remembered" without "12 in use" hides the fact that most are one-offs.
    @Published private(set) var eligiblePhraseCount: Int = 0

    private let defaults: PhraseMemoryDefaults
    private var phrasesByKey: [String: LearnedPhrase]

    /// Cap on distinct remembered phrases, and the level a trim cuts back to. Sized so a heavy
    /// writer's recurring sentences all survive while the persisted blob stays small (a phrase is
    /// at most `PhraseHarvester.maximumCharacters`, so the worst case is a few tens of kilobytes).
    /// Trimming triggers above `phraseCap` and cuts to `phraseTrimTarget` so steady use does not
    /// re-sort the table on every commit.
    static let phraseCap = 400
    static let phraseTrimTarget = 300
    private static let storageKey = "cotabbyLearnedPhrases"

    private struct Persisted: Codable {
        var phrases: [LearnedPhrase]
    }

    init(defaults: PhraseMemoryDefaults = UserDefaults.standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            phrasesByKey = Dictionary(
                decoded.phrases.map { ($0.key, $0) },
                uniquingKeysWith: { lhs, rhs in lhs.count >= rhs.count ? lhs : rhs }
            )
        } else {
            phrasesByKey = [:]
        }
        refreshCounts()
    }

    // See the type doc comment: avoids the macOS 14 isolated-deinit back-deploy crash.
    nonisolated deinit {}

    /// Records one committed block of text: harvests its phrases and folds each into the table.
    /// Returns the phrases that were recorded, which the caller logs at trace level.
    @discardableResult
    func record(
        committedText: String,
        bundleIdentifier: String?,
        now: Date = Date()
    ) -> [String] {
        let harvested = PhraseHarvester.phrases(in: committedText)
        guard !harvested.isEmpty else { return [] }

        for phrase in harvested {
            let key = PhraseHarvester.normalizedKey(for: phrase)
            guard !key.isEmpty else { continue }
            if var existing = phrasesByKey[key] {
                existing.merge(text: phrase, bundleIdentifier: bundleIdentifier, at: now)
                phrasesByKey[key] = existing
            } else {
                phrasesByKey[key] = LearnedPhrase(
                    key: key,
                    text: phrase,
                    lastUsedAt: now,
                    bundleIdentifiers: bundleIdentifier.map { [$0] } ?? []
                )
            }
        }

        trimIfNeeded()
        refreshCounts()
        persist()
        return harvested
    }

    /// Immutable snapshot for the pure ranker, ordered most-repeated first so a truncated debug
    /// dump shows the phrases that actually matter.
    func snapshot() -> PhraseMemorySnapshot {
        PhraseMemorySnapshot(
            phrases: phrasesByKey.values.sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
        )
    }

    /// Forgets every phrase. Backs the "Forget learned phrases" settings control.
    func forgetAll() {
        phrasesByKey = [:]
        refreshCounts()
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func refreshCounts() {
        phraseCount = phrasesByKey.count
        eligiblePhraseCount = phrasesByKey.values
            .filter { $0.count >= PhraseMemoryRanker.minimumCountToSuggest }
            .count
    }

    /// Drops the weakest phrases once the table outgrows its cap: fewest sightings first, oldest
    /// breaking ties. A phrase seen many times is exactly what this feature exists to keep, so
    /// count dominates recency here (the reverse of a plain LRU).
    private func trimIfNeeded() {
        guard phrasesByKey.count > Self.phraseCap else { return }

        let removable = phrasesByKey.values.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs.lastUsedAt < rhs.lastUsedAt
        }
        let overflow = phrasesByKey.count - Self.phraseTrimTarget
        for phrase in removable.prefix(overflow) {
            phrasesByKey.removeValue(forKey: phrase.key)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Persisted(phrases: Array(phrasesByKey.values))) else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
