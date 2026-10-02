import Foundation

/// File overview:
/// Keeps invented phone numbers out of ghost text. A language model asked to continue
/// "call me at 0888 1" happily writes "23 456": plausible digits, almost certainly wrong, and
/// harmful precisely because they look right. Digits like that can only be trusted when they come
/// from a number the writer has actually typed before (`KnownPhoneNumbers`).
///
/// Deterministic and applied to every final suggestion (the coordinator runs it where suggestions
/// are presented, stored, and prefetched), so it holds no matter which engine, cache, or prompt
/// produced the text. A prompt instruction could only make invented numbers rarer; this makes them
/// impossible.
///
/// Rule: find each phone-shaped digit run (6+ digits, allowing the usual separators) that the
/// completion contributes digits to, joined with whatever number the writer has started typing at
/// the caret. A run that matches a known number exactly, or is a known number's prefix cut off at
/// the end of the suggestion, is kept. Anything else is cut from the completion at the point where
/// its invented digits start; if nothing with word content remains, the whole suggestion goes.
enum PhoneNumberGuard {
    /// Fewer digits than this is ordinary prose ("in 2 weeks", "room 314", "2026"), not a number
    /// someone would dial.
    static let minimumDigits = 6

    /// A digit run: an optional "+", then digits joined by at most two separator characters
    /// ("0888 123 456", "+359 (88) 712-3456", "0888.123.456").
    private static let runPattern = #"\+?\(?\d(?:[ \-./()]{0,2}\d)*"#
    /// Dates and decimals that would otherwise read as six-plus digit runs.
    private static let nonPhonePatterns = [
        #"^\d{4}[-./]\d{1,2}[-./]\d{1,2}$"#,      // 2026-10-02
        #"^\d{1,2}[-./]\d{1,2}[-./]\d{2,4}$"#,    // 02.10.2026, 10/02/26
    ]

    struct Run: Equatable {
        /// Character offsets in the searched text.
        let start: Int
        let end: Int
        let text: String
        /// Digits only (a leading "+" is dropped: matching is on digits).
        let digits: String
    }

    /// Every phone-shaped run in `text`, in order.
    static func phoneRuns(in text: String) -> [Run] {
        guard text.contains(where: \.isNumber),
              let regex = try? NSRegularExpression(pattern: runPattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            // A phone number stands on its own. Digits glued to letters are part of a code, an ID, or
            // a tracking number ("1Z999AA10123456784", "0x80070005"), which this guard leaves alone.
            if range.lowerBound > text.startIndex, text[text.index(before: range.lowerBound)].isLetter { return nil }
            if range.upperBound < text.endIndex, text[range.upperBound].isLetter { return nil }
            let runText = String(text[range])
            let digits = runText.filter(\.isNumber)
            guard digits.count >= minimumDigits, !looksLikeDateOrDecimal(runText) else { return nil }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            return Run(start: start, end: start + runText.count, text: runText, digits: String(digits))
        }
    }

    /// The completion with any invented phone number removed, or nil when nothing worth showing is
    /// left. `known` holds the writer's own numbers.
    static func vetted(completion: String, precedingText: String, known: KnownPhoneNumbers) -> String? {
        guard completion.contains(where: \.isNumber) else { return completion }
        // Enough of the text before the caret to hold a number the writer has started typing.
        let tail = String(precedingText.suffix(40))
        let boundary = tail.count
        let combined = tail + completion
        for run in phoneRuns(in: combined) where run.end > boundary {
            let reachesEnd = run.end == combined.count
            if known.contains(digits: run.digits) || (reachesEnd && known.hasNumber(startingWith: run.digits)) {
                continue
            }
            let cut = max(run.start, boundary) - boundary
            var kept = String(completion.prefix(cut))
            while let last = kept.last, last.isWhitespace || "+(-./".contains(last) { kept.removeLast() }
            return kept.contains(where: \.isLetter) ? kept : nil
        }
        return completion
    }

    private static func looksLikeDateOrDecimal(_ run: String) -> Bool {
        nonPhonePatterns.contains { run.range(of: $0, options: .regularExpression) != nil }
    }
}
