import Foundation

/// The email address the writer just entered, so a form that asks for it again ("Confirm email")
/// can be filled with one key.
///
/// Remembered: a field whose whole text is exactly one email address, at the moment the writer
/// leaves it, never from a secure field. Kept in memory only, for `lifetime`, and offered only in
/// the same app (process) and in a different field: it is a convenience for the form in front of
/// the writer, not a history. Nothing here is persisted or logged.
///
/// Pure value type, owned by `SuggestionCoordinator`.
nonisolated struct RecentEmailMemory: Sendable {
    struct Entry: Equatable, Sendable {
        let email: String
        let processIdentifier: Int32
        let elementIdentifier: String
        let enteredAt: Date
    }

    private(set) var entry: Entry?
    /// The field being edited and its latest text; becomes `entry` when focus leaves it.
    private var current: (processIdentifier: Int32, elementIdentifier: String, text: String)?

    /// The field `observe` last saw, for telling a newly focused field from the same one.
    var currentElementIdentifier: String? { current?.elementIdentifier }

    static let lifetime: TimeInterval = 10 * 60
    /// Characters to type before the email is offered in a field whose label says nothing about
    /// email: enough that a name or a message starting with the same letter is not interrupted.
    static let minimumTypedInUnlabeledField = 3

    /// Follows the focused field. Call with every focus snapshot (nil when nothing editable has
    /// focus, or the field is secure: its text never becomes `current`).
    mutating func observe(processIdentifier: Int32?, elementIdentifier: String?, text: String?,
                          isSecure: Bool, now: Date = Date()) {
        if let current, current.elementIdentifier != elementIdentifier || current.processIdentifier != processIdentifier {
            if let email = Self.singleEmail(in: current.text) {
                entry = Entry(email: email, processIdentifier: current.processIdentifier,
                              elementIdentifier: current.elementIdentifier, enteredAt: now)
            }
            self.current = nil
        }
        guard let processIdentifier, let elementIdentifier, let text, !isSecure else {
            current = nil
            return
        }
        current = (processIdentifier, elementIdentifier, text)
    }

    /// The rest of the remembered email for this field, or nil. `typed` is the field's text before
    /// the caret; the field must hold nothing after it.
    func suggestion(typed: String, trailing: String, processIdentifier: Int32, elementIdentifier: String,
                    purpose: FormFieldPurpose, now: Date = Date()) -> String? {
        guard let entry, now.timeIntervalSince(entry.enteredAt) <= Self.lifetime,
              entry.processIdentifier == processIdentifier, entry.elementIdentifier != elementIdentifier,
              trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let minimumTyped: Int
        switch purpose {
        case .repeatEmail: minimumTyped = 0
        case .email: minimumTyped = 1
        case .other: minimumTyped = Self.minimumTypedInUnlabeledField
        case .verificationCode: return nil
        }
        guard typed.count >= minimumTyped, typed.count < entry.email.count,
              entry.email.lowercased().hasPrefix(typed.lowercased()) else { return nil }
        return String(entry.email.dropFirst(typed.count))
    }

    /// The text if it is exactly one email address (surrounding whitespace aside), else nil.
    static func singleEmail(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 254,
              trimmed.range(of: #"^[A-Za-z0-9._%+'-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$"#,
                            options: .regularExpression) != nil else { return nil }
        return trimmed
    }
}
