import Foundation

/// File overview:
/// Turns one committed block of the writer's own text into the phrases worth remembering. Pure and
/// deterministic: no persistence, no dates, no settings, so every rule below is directly testable.
///
/// "Committed" means the writer finished with it — the field was cleared (a send) or focus left it.
/// See `TypedTextCommitDetector` for how that moment is spotted.
///
/// The filters are deliberately conservative in one direction only. Junk that slips through costs
/// little, because `PhraseMemoryRanker` refuses to inject anything seen just once and a one-off
/// draft never reaches a second sighting. What must NOT slip through is anything that looks like a
/// secret or an identifier: those would be persisted, and a leaked API key is not fixed by a low
/// rank. Hence the hard rejects on long mixed-case-and-digit runs, long digit runs, addresses, and
/// digit-heavy text.
enum PhraseHarvester {
    /// A single word is not a phrase worth a prompt slot; past ~16 words verbatim repetition is
    /// rare enough that the entry would only consume cap.
    static let minimumWords = 2
    static let maximumWords = 16
    static let minimumCharacters = 8
    static let maximumCharacters = 120
    /// Ceiling per commit, so one pasted wall of text cannot flood the table in a single event.
    /// Applied to the *start* of the block: the opening sentences of a message are the formulaic
    /// ones (greeting, framing), the tail is usually specific to that message.
    static let maximumPhrasesPerCommit = 8

    /// Sentence terminators. A terminator only ends a sentence when whitespace or end-of-text
    /// follows, so "mobile.bg", "17.30", and "Dr. " inside a word stay intact.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "\u{2026}", ";"]
    /// Leading decoration to shave off a line before it is judged: quote markers, list bullets, and
    /// Markdown headings all wrap phrases the writer really typed.
    private static let leadingDecoration = CharacterSet(charactersIn: ">-*•#·–—\u{00A0} \t\"'“”„«»()[]")
    private static let trailingDecoration = CharacterSet(charactersIn: ".,;:!?\u{2026} \t\"'“”„«»()[]")

    /// Every phrase worth remembering in `committedText`, in document order, deduplicated by key.
    static func phrases(in committedText: String) -> [String] {
        var seenKeys = Set<String>()
        var kept: [String] = []

        for candidate in candidates(in: committedText) {
            guard isWorthRemembering(candidate) else { continue }
            let key = normalizedKey(for: candidate)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
            kept.append(candidate)
            if kept.count == maximumPhrasesPerCommit { break }
        }

        return kept
    }

    /// Match key: lowercased, whitespace-collapsed, outer decoration stripped. The display form
    /// keeps the writer's own spelling; only the key is normalized.
    static func normalizedKey(for phrase: String) -> String {
        words(in: phrase)
            .map { $0.lowercased() }
            .joined(separator: " ")
    }

    /// Whitespace-separated words with outer decoration stripped. Shared with the ranker so both
    /// sides tokenize identically.
    static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { token in
                token.trimmingCharacters(in: trailingDecoration.union(leadingDecoration))
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - Candidate extraction

    /// Splits the block into line- and sentence-shaped candidates, each trimmed of decoration.
    private static func candidates(in text: String) -> [String] {
        var results: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            for sentence in sentences(in: String(line)) {
                let trimmed = trimmedCandidate(sentence)
                if !trimmed.isEmpty {
                    results.append(trimmed)
                }
            }
        }
        return results
    }

    private static func sentences(in line: String) -> [String] {
        let characters = Array(line)
        var sentences: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard sentenceTerminators.contains(character) else { continue }
            // A terminator closes the sentence only at end-of-line or before whitespace, so a run
            // ("?!", "...") cuts once at its last terminator and "mobile.bg" never cuts at all.
            let nextIsWhitespace = characters.indices.contains(index + 1)
                ? characters[index + 1].isWhitespace
                : true
            if nextIsWhitespace {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            sentences.append(current)
        }
        return sentences
    }

    private static func trimmedCandidate(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = trimmed.unicodeScalars.first, leadingDecoration.contains(first) {
            trimmed.removeFirst()
        }
        while let last = trimmed.unicodeScalars.last, trailingDecoration.contains(last) {
            trimmed.removeLast()
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Filters

    private static func isWorthRemembering(_ candidate: String) -> Bool {
        guard (minimumCharacters...maximumCharacters).contains(candidate.count) else { return false }

        let candidateWords = words(in: candidate)
        guard (minimumWords...maximumWords).contains(candidateWords.count) else { return false }
        // All-tiny words ("ok so ok") carry no reusable shape.
        guard candidateWords.contains(where: { $0.count >= 3 }) else { return false }
        guard candidate.contains(where: \.isLetter) else { return false }
        guard !isDigitHeavy(candidate) else { return false }

        return candidateWords.allSatisfy { !isSensitiveLookingToken($0) }
    }

    /// Numbers are welcome inside a sentence ("the invoice is 4412") but a candidate that is mostly
    /// digits is a code, a total, or a timestamp — specific to one message, never reused verbatim.
    private static func isDigitHeavy(_ candidate: String) -> Bool {
        let significant = candidate.filter { !$0.isWhitespace }
        guard !significant.isEmpty else { return true }
        let digits = significant.filter(\.isNumber).count
        return Double(digits) / Double(significant.count) > 0.3
    }

    /// Hard reject: anything shaped like a credential, token, or address. A phrase only earns a slot
    /// by repeating, but it is persisted on first sight, so this gate runs before storage.
    private static func isSensitiveLookingToken(_ token: String) -> Bool {
        if token.contains("://") || token.contains("@") { return true }
        // A long opaque run carrying both letters and digits is an API key, hash, or session id far
        // more often than it is a word the writer types twice.
        if token.count >= 20, token.contains(where: \.isNumber), token.contains(where: \.isLetter) {
            return true
        }
        return hasLongDigitRun(token)
    }

    /// Six or more consecutive digits: one-time codes, card fragments, order numbers, phone numbers.
    private static func hasLongDigitRun(_ token: String) -> Bool {
        var run = 0
        for character in token {
            if character.isNumber {
                run += 1
                if run >= 6 { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}
