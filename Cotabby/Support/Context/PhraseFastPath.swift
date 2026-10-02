import Foundation

/// File overview:
/// Shows a learned phrase the moment the writer starts typing it, with no model call and no debounce.
///
/// Phrase memory already hands the model a phrase that continues the caret text
/// (`PhraseMemoryRanker`), but that still costs a debounce pause plus a generation (~150 ms on this
/// Mac), and the model can still paraphrase it. When the sentence being typed is, character for
/// character, the start of a phrase this writer has finished at least twice, the rest of that phrase
/// is known, so there is nothing to generate: show it now.
///
/// Pure and cheap (one pass over at most a few hundred phrases, per keystroke), so the coordinator
/// can ask on every keystroke before debouncing. It is deliberately stricter than the ranker, since
/// here nothing checks the guess afterwards:
/// - matched from the CURRENT SENTENCE's first word (two words, eight characters), or from a later
///   word in it with a longer typed run (three words, twelve characters), because phrases are
///   harvested as whole sentences and a mid-sentence match is weaker evidence;
/// - the caret must be at the end of the text (nothing after it to duplicate or collide with);
/// - when two phrases match but disagree on what comes next, the more frequent one must have been
///   typed strictly more often, or the model decides instead.
enum PhraseFastPath {
    static let minimumTypedCharacters = 8
    static let minimumTypedWords = 2

    /// A phrase may also start inside the current sentence ("Sure, see you at the office tomorrow"
    /// reusing "see you at the office tomorrow"), but that is weaker evidence than a match from the
    /// sentence's first word, so it needs a longer typed run.
    static let minimumMidSentenceWords = 3
    static let minimumMidSentenceCharacters = 12

    /// The continuation to show, in the phrase's own spelling and casing, or nil.
    static func continuation(
        precedingText: String,
        trailingText: String,
        snapshot: PhraseMemorySnapshot
    ) -> String? {
        guard !snapshot.isEmpty,
              trailingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sentence = currentSentence(in: precedingText)
        let eligible = snapshot.phrases.filter { $0.count >= PhraseMemoryRanker.minimumCountToSuggest }
        guard !eligible.isEmpty else { return nil }

        // Longest fragment first: the whole sentence, then each run starting at a later word. The
        // first fragment any phrase starts with decides, so a long match is never overruled by a
        // shorter, vaguer one.
        for (offset, fragment) in fragments(of: sentence).enumerated() {
            let isWholeSentence = offset == 0
            let wordCount = fragment.split(whereSeparator: \.isWhitespace).count
            guard isWholeSentence
                ? fragment.count >= minimumTypedCharacters && wordCount >= minimumTypedWords
                : fragment.count >= minimumMidSentenceCharacters && wordCount >= minimumMidSentenceWords
            else { continue }
            let candidates = eligible
                .compactMap { phrase -> (phrase: LearnedPhrase, remainder: String)? in
                    guard let remainder = remainder(of: phrase.text, after: fragment),
                          remainder.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
                    return (phrase, remainder)
                }
                .sorted {
                    if $0.phrase.count != $1.phrase.count { return $0.phrase.count > $1.phrase.count }
                    return $0.phrase.lastUsedAt > $1.phrase.lastUsedAt
                }
            guard let best = candidates.first else { continue }
            let nextWord = firstWord(of: best.remainder)
            let contested = candidates.dropFirst().contains {
                firstWord(of: $0.remainder) != nextWord && $0.phrase.count >= best.phrase.count
            }
            return contested ? nil : best.remainder
        }
        return nil
    }

    /// The sentence itself, then the same text starting at each later word (leading whitespace
    /// dropped, trailing kept).
    static func fragments(of sentence: String) -> [String] {
        var result = [sentence]
        var index = sentence.startIndex
        while let space = sentence[index...].firstIndex(where: \.isWhitespace) {
            guard let next = sentence[space...].firstIndex(where: { !$0.isWhitespace }) else { break }
            result.append(String(sentence[next...]))
            index = next
        }
        return result
    }

    /// The sentence the caret is in, from its first character: everything after the last line
    /// break or sentence terminator followed by whitespace (the same boundary `PhraseHarvester`
    /// splits on), with leading whitespace dropped. Trailing whitespace is kept: "the " and "the"
    /// continue differently.
    static func currentSentence(in text: String) -> String {
        let characters = Array(text)
        var start = 0
        var index = characters.count - 1
        while index > 0 {
            let character = characters[index]
            if character.isNewline {
                start = index + 1
                break
            }
            if character.isWhitespace, ".!?…".contains(characters[index - 1]) {
                start = index + 1
                break
            }
            index -= 1
        }
        return String(characters[min(start, characters.count)...].drop(while: \.isWhitespace))
    }

    /// What follows `fragment` in `phrase`, when the phrase starts with it. Letters compare without
    /// case, and any run of whitespace matches any other run, so "i will  send" still matches
    /// "I will send". Nil when the phrase does not start with the fragment or nothing is left.
    static func remainder(of phrase: String, after fragment: String) -> String? {
        let phraseCharacters = Array(phrase)
        let fragmentCharacters = Array(fragment)
        var phraseIndex = 0
        var fragmentIndex = 0
        while fragmentIndex < fragmentCharacters.count {
            if fragmentCharacters[fragmentIndex].isWhitespace {
                guard phraseIndex < phraseCharacters.count, phraseCharacters[phraseIndex].isWhitespace else {
                    return nil
                }
                while fragmentIndex < fragmentCharacters.count, fragmentCharacters[fragmentIndex].isWhitespace {
                    fragmentIndex += 1
                }
                while phraseIndex < phraseCharacters.count, phraseCharacters[phraseIndex].isWhitespace {
                    phraseIndex += 1
                }
                continue
            }
            guard phraseIndex < phraseCharacters.count,
                  phraseCharacters[phraseIndex].lowercased() == fragmentCharacters[fragmentIndex].lowercased() else {
                return nil
            }
            phraseIndex += 1
            fragmentIndex += 1
        }
        guard phraseIndex < phraseCharacters.count else { return nil }
        return String(phraseCharacters[phraseIndex...])
    }

    private static func firstWord(of text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
    }
}
