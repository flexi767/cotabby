import Foundation

/// File overview:
/// The phone numbers this writer has typed themselves, kept so a number they start typing again can
/// be finished instantly and exactly, and so `PhoneNumberGuard` can tell a real number from an
/// invented one.
///
/// Trust is the whole point, so what may enter is narrow:
/// - only numbers in text the writer FINISHED (the same commits phrase memory learns from, with
///   the same exclusions: never secure fields, terminals, or code editors);
/// - never digits that arrived by accepting a suggestion: the coordinator passes those runs as
///   `excludingAcceptedDigits`, and any number containing one is skipped, so model output can never
///   launder itself into history;
/// - never anything merely shown on screen or in a suggestion: nothing here reads either.
///
/// Pure value type, owned and persisted by `PersonalWordStore` under the same switch and the same
/// "forget" as the rest of the writer's learned text.
struct KnownPhoneNumbers: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// As the writer typed it, separators included ("+359 88 712 3456").
        var display: String
        /// Digits only, the matching key.
        var digits: String
        var count: Int
        var lastUsedAt: Date
    }

    private(set) var entries: [Entry] = []

    static let maximumEntries = 300
    /// Digits that must be typed before a number is completed: fewer is a coin toss between numbers.
    static let minimumTypedDigits = 3

    var isEmpty: Bool { entries.isEmpty }

    func contains(digits: String) -> Bool {
        entries.contains { $0.digits == digits }
    }

    func hasNumber(startingWith digits: String) -> Bool {
        entries.contains { $0.digits.count > digits.count && $0.digits.hasPrefix(digits) }
    }

    // MARK: - Learning

    /// Records every phone-shaped number in finished text, except any that contains digits the
    /// writer accepted from a suggestion rather than typed.
    mutating func learn(committedText: String, excludingAcceptedDigits accepted: [String] = [], now: Date = Date()) {
        for run in PhoneNumberGuard.phoneRuns(in: committedText) {
            guard !accepted.contains(where: { !$0.isEmpty && run.digits.contains($0) }) else { continue }
            let display = run.text.trimmingCharacters(in: CharacterSet(charactersIn: "(-./ "))
            if let index = entries.firstIndex(where: { $0.digits == run.digits }) {
                entries[index].count += 1
                entries[index].lastUsedAt = now
                entries[index].display = display
            } else {
                entries.append(Entry(display: display, digits: run.digits, count: 1, lastUsedAt: now))
            }
        }
        if entries.count > Self.maximumEntries {
            entries = Array(entries.sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.lastUsedAt > $1.lastUsedAt
            }.prefix(Self.maximumEntries))
        }
    }

    // MARK: - Completion

    /// The rest of the known number the writer has started typing at the end of `precedingText`,
    /// or nil. Formatting follows the writer: the stored number's own separators continue, unless the
    /// writer left out separators the stored number has, in which case the rest comes bare too.
    func completion(precedingText: String) -> String? {
        guard !entries.isEmpty, let last = precedingText.last, last.isNumber else { return nil }
        let typedRun = Self.trailingNumber(in: precedingText)
        let typedDigits = typedRun.filter(\.isNumber)
        guard typedDigits.count >= Self.minimumTypedDigits else { return nil }

        let candidates = entries
            .filter { $0.digits.count > typedDigits.count && $0.digits.hasPrefix(typedDigits) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastUsedAt > $1.lastUsedAt }
        guard let best = candidates.first else { return nil }
        // Two numbers that both fit, typed equally often: no way to know which one is meant.
        if candidates.count > 1, candidates[1].count >= best.count { return nil }

        let remainder = Self.remainder(of: best.display, afterDigits: typedDigits.count)
        // Follow the writer's formatting: if the stored number had separators where the writer has
        // now typed none, they are typing it bare this time, so the rest comes bare too.
        let typedWithSeparators = typedRun.contains { !$0.isNumber && $0 != "+" }
        let storedPrefix = best.display.dropLast(remainder.count)
        let storedWithSeparators = storedPrefix.contains { !$0.isNumber && $0 != "+" }
        let formatted = storedWithSeparators && !typedWithSeparators ? remainder.filter(\.isNumber) : remainder
        return formatted.contains(where: \.isNumber) ? formatted : nil
    }

    /// The number being typed at the very end of the text: digits and separators back to the first
    /// character that cannot belong to a number.
    static func trailingNumber(in text: String) -> String {
        var run = ""
        for character in text.reversed() {
            guard character.isNumber || " -./()+".contains(character) else { break }
            run.insert(character, at: run.startIndex)
        }
        // A space that separated the number from the words before it is not part of the number.
        return run.trimmingCharacters(in: .whitespaces)
    }

    /// `display` after its first `count` digits, with the separator that follows them kept.
    static func remainder(of display: String, afterDigits count: Int) -> String {
        var seen = 0
        var index = display.startIndex
        while index < display.endIndex, seen < count {
            if display[index].isNumber { seen += 1 }
            index = display.index(after: index)
        }
        return String(display[index...])
    }
}
