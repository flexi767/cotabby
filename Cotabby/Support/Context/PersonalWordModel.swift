import Foundation

/// File overview:
/// A phone-keyboard-style memory of how this writer uses words: which words they use, and which word
/// they put after each one or two words. Phrase memory remembers whole sentences, so a habit that
/// lives inside different sentences ("see you tomorrow", "see you tomorrow then", "can't make it, see
/// you tomorrow") never added up to anything; here every one of those sightings counts toward
/// "see you" -> "tomorrow".
///
/// Pure value type with no I/O. `PersonalWordStore` owns one, persists it, and feeds it finished
/// text; the coordinator asks it for a prediction at the caret. It learns from text the writer
/// finished (the same commits phrase memory learns from) plus suggestions they accepted, which earn
/// extra weight: an accepted word is a word they chose twice.
///
/// Prediction is deliberately conservative: it speaks only when one continuation clearly dominates
/// this writer's own history (enough sightings, most of the weight, well ahead of the runner-up).
/// Anything less is left to the model, which sees far more context than two words.
struct PersonalWordModel: Codable, Equatable, Sendable {
    struct WordEntry: Codable, Equatable, Sendable {
        /// The spelling to show: the writer's own casing, taken from a non-sentence-initial use when
        /// there is one ("Sarah", "iPhone"), else the latest sighting.
        var spelling: String
        var weight: Double
        var lastUsedAt: Date
        var seenMidSentence: Bool
    }

    /// Lowercased word -> usage.
    private(set) var words: [String: WordEntry] = [:]
    /// Lowercased context ("w" or "w1 w2") -> lowercased next word -> weight.
    private(set) var followers: [String: [String: Double]] = [:]

    static let maximumWords = 8000
    static let maximumContexts = 16000
    static let maximumFollowersPerContext = 8
    static let maximumWordLength = 24

    /// Weight a continuation needs before it is ever offered.
    static let minimumContextWeight = 3.0
    /// A completion of the word being typed, with no context match, needs more evidence.
    static let minimumVocabularyWeight = 4.0
    /// Share of all matching weight the favourite must hold, and its lead over the runner-up.
    static let minimumShare = 0.6
    static let minimumLead = 2.0

    var wordCount: Int { words.count }
    var isEmpty: Bool { words.isEmpty }

    // MARK: - Learning

    /// Counts every word and every one- and two-word context in `text`. Sentences, line breaks, and
    /// anything that is not a plain word (numbers, addresses, codes) break the chain, so no context
    /// ever spans two sentences or a token the writer would never retype.
    mutating func learn(_ text: String, weight: Double = 1, now: Date = Date()) {
        for sentence in Self.sentences(in: text) {
            var previous: [String] = []
            for (index, token) in sentence.enumerated() {
                guard let key = Self.wordKey(token) else {
                    previous.removeAll()
                    continue
                }
                var entry = words[key] ?? WordEntry(spelling: token, weight: 0, lastUsedAt: now, seenMidSentence: false)
                entry.weight += weight
                entry.lastUsedAt = now
                let midSentence = index > 0
                if midSentence || !entry.seenMidSentence {
                    entry.spelling = token
                    entry.seenMidSentence = entry.seenMidSentence || midSentence
                }
                words[key] = entry
                if let last = previous.last {
                    followers[last, default: [:]][key, default: 0] += weight
                }
                if previous.count >= 2 {
                    followers[previous.suffix(2).joined(separator: " "), default: [:]][key, default: 0] += weight
                }
                previous.append(key)
            }
        }
        trimIfNeeded()
    }

    // MARK: - Prediction

    /// The continuation to show at the end of `precedingText`, or nil when this writer's history has
    /// no clear answer. Mid-word it finishes the word (and may continue); after a space it offers the
    /// next word(s). At most `maximumWords` words, each one as confident as the first.
    func prediction(precedingText: String, maximumWords: Int) -> String? {
        guard maximumWords > 0, !words.isEmpty else { return nil }
        let sentence = PhraseFastPath.currentSentence(in: precedingText)
        let tokens = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        // Only two caret shapes are predicted: inside a word, or right after whitespace. Right after
        // punctuation ("tomorrow.", "Hi,") the next character is the writer's call, not a word.
        guard let lastCharacter = precedingText.last else { return nil }
        let caretInWord = lastCharacter.isLetter || CaretWordContext.isConnector(lastCharacter)
        guard caretInWord || lastCharacter.isWhitespace else { return nil }
        let partial = caretInWord ? tokens.last ?? "" : ""
        if caretInWord, Self.wordKey(partial) == nil { return nil }
        // The context is the CONTIGUOUS run of plain words right before the caret word: a number or
        // code in between ends it, so "send 3 files" never reads as "send files".
        var context: [String] = []
        for token in (caretInWord ? Array(tokens.dropLast()) : tokens).suffix(2).reversed() {
            guard let key = Self.wordKey(token) else { break }
            context.insert(key, at: 0)
        }
        if !caretInWord, context.isEmpty { return nil }

        var output: [String] = []
        var prefix = partial.lowercased()
        for _ in 0..<maximumWords {
            guard let next = nextWord(context: context, prefix: prefix) else { break }
            output.append(next)
            context = Array((context + [next]).suffix(2))
            prefix = ""
        }
        guard let first = output.first else { return nil }

        let firstSpelling = words[first]?.spelling ?? first
        var pieces: [String] = []
        if caretInWord {
            let suffix = String(firstSpelling.dropFirst(partial.count))
            pieces.append(partial.allSatisfy(\.isUppercase) && partial.count > 1 ? suffix.uppercased() : suffix)
        } else {
            pieces.append(firstSpelling)
        }
        pieces += output.dropFirst().map { words[$0]?.spelling ?? $0 }
        let joined = pieces.joined(separator: " ")
        return joined.contains(where: \.isLetter) ? joined : nil
    }

    /// The dominant next word for `context` starting with `prefix`, trying the two-word context
    /// before the one-word one, then (mid-word only) the plain vocabulary.
    private func nextWord(context: [String], prefix: String) -> String? {
        if context.count == 2, let found = dominant(in: followers[context.joined(separator: " ")], prefix: prefix,
                                                     minimumWeight: Self.minimumContextWeight) {
            return found
        }
        if let last = context.last, let found = dominant(in: followers[last], prefix: prefix,
                                                          minimumWeight: Self.minimumContextWeight) {
            return found
        }
        guard prefix.count >= 3 else { return nil }
        return dominant(in: words.mapValues(\.weight), prefix: prefix, minimumWeight: Self.minimumVocabularyWeight)
    }

    private func dominant(in candidates: [String: Double]?, prefix: String, minimumWeight: Double) -> String? {
        guard let candidates else { return nil }
        let matching = candidates.filter { $0.key.count > prefix.count && $0.key.hasPrefix(prefix) }
        guard !matching.isEmpty else { return nil }
        let ranked = matching.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let best = ranked[0]
        let total = matching.values.reduce(0, +)
        let runnerUp = ranked.count > 1 ? ranked[1].value : 0
        guard best.value >= minimumWeight,
              best.value / total >= Self.minimumShare,
              best.value >= runnerUp * Self.minimumLead else { return nil }
        return best.key
    }

    // MARK: - Completion candidates for the word-ending fallback

    /// This writer's spelling of the dominant word starting with `prefix`, for
    /// `WordCompletionFallback`. Same evidence bar as a vocabulary prediction.
    func completion(of prefix: String) -> String? {
        guard prefix.count >= 3 else { return nil }
        let key = prefix.lowercased()
        return dominant(in: words.mapValues(\.weight), prefix: key, minimumWeight: Self.minimumVocabularyWeight)
            .map { words[$0]?.spelling ?? $0 }
    }

    // MARK: - Tokenizing

    /// Lines, then sentences (a terminator followed by whitespace), as whitespace-separated tokens
    /// with outer punctuation stripped.
    static func sentences(in text: String) -> [[String]] {
        var result: [[String]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var current: [String] = []
            for raw in line.split(whereSeparator: \.isWhitespace) {
                let endsSentence = raw.last.map { ".!?…".contains($0) } ?? false
                let cleaned = PhraseHarvester.words(in: String(raw))
                current += cleaned
                if endsSentence {
                    if !current.isEmpty { result.append(current) }
                    current = []
                }
            }
            if !current.isEmpty { result.append(current) }
        }
        return result
    }

    /// The lowercased key for a plain word, or nil for anything else: digits, addresses, codes, and
    /// over-long runs never become vocabulary.
    static func wordKey(_ token: String) -> String? {
        let cleaned = PhraseHarvester.words(in: token).first ?? ""
        guard (1...maximumWordLength).contains(cleaned.count),
              cleaned.first?.isLetter == true, cleaned.last?.isLetter == true,
              cleaned.allSatisfy({ $0.isLetter || CaretWordContext.isConnector($0) }) else { return nil }
        return cleaned.lowercased()
    }

    // MARK: - Bounds

    private mutating func trimIfNeeded() {
        for (context, next) in followers where next.count > Self.maximumFollowersPerContext {
            followers[context] = Dictionary(uniqueKeysWithValues: next.sorted { $0.value > $1.value }
                .prefix(Self.maximumFollowersPerContext).map { ($0.key, $0.value) })
        }
        if words.count > Self.maximumWords {
            let keep = words.sorted {
                $0.value.weight != $1.value.weight ? $0.value.weight > $1.value.weight
                    : $0.value.lastUsedAt > $1.value.lastUsedAt
            }.prefix(Self.maximumWords * 4 / 5)
            words = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if followers.count > Self.maximumContexts {
            let keep = followers.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }
                .prefix(Self.maximumContexts * 4 / 5)
            followers = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}
