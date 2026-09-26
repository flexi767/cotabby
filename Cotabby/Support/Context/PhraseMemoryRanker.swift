import Foundation

/// File overview:
/// Chooses which learned phrases are worth prompt budget for the text being typed right now. Pure:
/// the store hands it a snapshot, the coordinator hands it the caret prefix, and it returns display
/// strings in the order the prompt should state them.
///
/// Two kinds of candidate earn a slot, and they are not equal:
///
/// 1. **Continuation matches** — the phrase starts with the words the writer has just typed. This is
///    the whole point of the feature: the model is handed the exact sentence this writer finishes
///    this way, so it can complete it instead of inventing a plausible alternative. Scored far above
///    everything else, and the longer the matched run, the stronger.
/// 2. **Ambient favorites** — no match against the caret, but this writer types it often *in this
///    app* (a sign-off, a standard opener). Useful conditioning, but speculative, so it needs a
///    higher sighting count and the app has to agree before it may spend budget.
///
/// Nothing seen only once is ever eligible. That single rule is what lets harvesting stay liberal:
/// a one-off draft is stored, never injected, and eventually trimmed.
enum PhraseMemoryRanker {
    /// A phrase must have been typed at least twice before it may enter a prompt — the literal
    /// reading of "I type the same thing over and over".
    static let minimumCountToSuggest = 2
    /// Ambient (non-matching) favorites need more evidence than a continuation match does.
    static let minimumCountForAmbient = 3
    static let maximumSelected = 3
    /// Character budget across all selected phrases, before the section label. Sized to stay well
    /// inside the prompt's context budget: three typical sentences.
    static let maximumCharacters = 220
    /// How many words back from the caret a continuation match may start.
    static let maximumMatchWords = 6

    /// The phrases to state in the prompt, strongest first.
    static func selected(
        from snapshot: PhraseMemorySnapshot,
        prefixText: String,
        bundleIdentifier: String?,
        now: Date = Date(),
        limit: Int = maximumSelected,
        maxCharacters: Int = maximumCharacters
    ) -> [String] {
        guard !snapshot.isEmpty, limit > 0 else { return [] }

        let prefixWords = PhraseHarvester.words(in: prefixText).map { $0.lowercased() }
        guard !prefixWords.isEmpty else { return [] }
        let prefixKey = prefixWords.joined(separator: " ")

        var scored: [(phrase: LearnedPhrase, score: Double)] = []
        for phrase in snapshot.phrases {
            guard phrase.count >= minimumCountToSuggest else { continue }
            // Already written in full: repeating it invites the model to duplicate text the writer
            // can see on screen.
            guard !prefixKey.contains(phrase.key) else { continue }

            let phraseWords = phrase.key.split(separator: " ").map(String.init)
            let matchedWords = continuationMatchLength(phraseWords: phraseWords, prefixWords: prefixWords)
            let isSameApp = bundleIdentifier.map { phrase.bundleIdentifiers.contains($0) } ?? false

            if matchedWords == 0 {
                // Ambient favorite: needs both a higher count and this app's endorsement.
                guard isSameApp, phrase.count >= minimumCountForAmbient else { continue }
            }

            var score = 0.0
            if matchedWords > 0 {
                score += 6.0 + Double(matchedWords)
            }
            score += overlapBonus(phraseWords: phraseWords, prefixWords: prefixWords)
            score += log2(Double(phrase.count))
            score += recencyBonus(lastUsedAt: phrase.lastUsedAt, now: now)
            if isSameApp {
                score += 0.8
            }
            scored.append((phrase, score))
        }

        let ordered = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.phrase.count != rhs.phrase.count { return lhs.phrase.count > rhs.phrase.count }
            return lhs.phrase.lastUsedAt > rhs.phrase.lastUsedAt
        }

        // A phrase that continues the caret text crowds out the rest. Two reasons, one measured:
        // the others are competing noise once the actual sentence is identified, and a preface that
        // lists several phrases teaches the model the list itself — in the eval it sometimes carried
        // the "; " separator into the ghost text and ran straight on into the second phrase.
        let hasContinuationMatch = ordered.first.map {
            continuationMatchLength(
                phraseWords: $0.phrase.key.split(separator: " ").map(String.init),
                prefixWords: prefixWords
            ) > 0
        } ?? false
        let effectiveLimit = hasContinuationMatch ? 1 : limit

        var selected: [String] = []
        var usedCharacters = 0
        for candidate in ordered {
            let cost = candidate.phrase.text.count + (selected.isEmpty ? 0 : 2)
            guard usedCharacters + cost <= maxCharacters else { continue }
            selected.append(candidate.phrase.text)
            usedCharacters += cost
            if selected.count == effectiveLimit { break }
        }
        return selected
    }

    /// Length, in words, of the longest run at the END of the caret text that the phrase STARTS
    /// with. Zero when the phrase does not continue what is being typed.
    ///
    /// A single-word match is only trusted for a word of four characters or more: matching on "the"
    /// or "and" would promote an unrelated phrase in almost every sentence.
    static func continuationMatchLength(phraseWords: [String], prefixWords: [String]) -> Int {
        let maximum = min(maximumMatchWords, min(phraseWords.count, prefixWords.count))
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            let tail = prefixWords.suffix(length)
            guard Array(tail) == Array(phraseWords.prefix(length)) else { continue }
            if length == 1, (tail.first?.count ?? 0) < 4 { return 0 }
            return length
        }
        return 0
    }

    /// Small credit for sharing distinctive vocabulary with the text being typed (a client name, a
    /// project word). Capped so it can never outweigh a real continuation match.
    private static func overlapBonus(phraseWords: [String], prefixWords: [String]) -> Double {
        let distinctivePrefixWords = Set(prefixWords.filter { $0.count >= 5 })
        guard !distinctivePrefixWords.isEmpty else { return 0 }
        let shared = Set(phraseWords.filter { $0.count >= 5 }).intersection(distinctivePrefixWords)
        return min(Double(shared.count) * 0.4, 1.2)
    }

    /// Recent habits beat retired ones: a sign-off the writer used yesterday is likelier than one
    /// from a project that ended months ago.
    private static func recencyBonus(lastUsedAt: Date, now: Date) -> Double {
        let age = now.timeIntervalSince(lastUsedAt)
        if age <= 86_400 { return 0.6 }
        if age <= 604_800 { return 0.3 }
        return 0
    }
}
