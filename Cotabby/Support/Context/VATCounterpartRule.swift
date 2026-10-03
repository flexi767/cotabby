import Foundation

/// File overview:
/// On the Informex vehicle portal's offer form, the two offer fields are the same amount with and
/// without 21% Belgian VAT: "Mijn offerte" (net) and "Mijn offerte (marge)" (incl. VAT). When the
/// writer has entered one, the other is arithmetic, not a guess: net x 1.21 for the marge field,
/// marge / 1.21 for the net field, rounded to whole euros (the writer's choice).
///
/// This is deliberately not a model feature. A language model asked to fill a price field invents a
/// plausible number, which is worse than nothing; this rule either computes the exact counterpart
/// from what the writer typed in the other field or offers nothing at all.
///
/// Pure. The focus resolver reads the two fields through Accessibility (each field's title and DOM
/// id identify it; see `FormCounterpartReading`) and the coordinator asks this rule for the text to
/// show. Scoped to the portal's host so the same field names elsewhere never trigger it.
nonisolated enum VATCounterpartRule {
    enum Role: Equatable, Sendable {
        /// "Mijn offerte": the net amount.
        case net
        /// "Mijn offerte (marge)": the amount including VAT.
        case gross
    }

    static let vatMultiplier: Decimal = 1.21
    static let hostSuffix = "informex-vehicle-online.be"

    static func applies(toURL urlString: String?) -> Bool {
        guard let urlString, let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == hostSuffix || host.hasSuffix("." + hostSuffix)
    }

    /// Which offer field this is, from its accessible title or DOM id (measured on the live form:
    /// `bidI` titled "Mijn offerte …", `bidM` titled "Mijn offerte (marge)"). Nil for any other field.
    static func role(title: String?, domIdentifier: String?) -> Role? {
        switch domIdentifier {
        case "bidM": return .gross
        case "bidI": return .net
        default: break
        }
        let lowered = title?.lowercased() ?? ""
        guard lowered.hasPrefix("mijn offerte") else { return nil }
        return lowered.contains("(marge)") ? .gross : .net
    }

    /// The text to show in the field with `role`, given the other field's value and what the writer
    /// has typed here so far: the whole computed amount in an empty field, the rest of it when the
    /// writer has started typing it, nil when the other field holds no amount or the typed text
    /// is not the start of the computed one.
    static func suggestion(for role: Role, counterpartValue: String, typed: String) -> String? {
        guard let text = counterpartAmount(forEditedRole: role == .gross ? .net : .gross, value: counterpartValue)
        else { return nil }
        let typedText = typed.trimmingCharacters(in: .whitespaces)
        guard typedText.count < text.count, text.hasPrefix(typedText) else { return nil }
        return String(text.dropFirst(typedText.count))
    }

    /// The amount for the OTHER field when the field with `role` holds `value`: net -> x 1.21,
    /// marge -> / 1.21, whole euros. Nil when `value` is not a positive amount.
    static func counterpartAmount(forEditedRole role: Role, value: String) -> String? {
        guard let source = amount(from: value), source > 0 else { return nil }
        return wholeEuros(role == .net ? source * vatMultiplier : source / vatMultiplier)
    }

    /// What to write into the other field when the writer leaves the field with `editedRole`, or nil
    /// to leave it alone. An empty other field is filled whenever this one holds an amount (also one
    /// entered earlier, so just visiting the field completes the pair). A filled other field is only
    /// updated after an edit here, and only if it still held the matching amount for the old value
    /// (the pair was linked); an amount that did not match was entered on purpose and is never
    /// overwritten. Clearing a field never clears the other.
    static func autofillValue(
        editedRole: Role, editedValue: String, editedValueAtFocus: String, counterpartValueAtFocus: String
    ) -> String? {
        let edited = editedValue.trimmingCharacters(in: .whitespaces)
        let before = editedValueAtFocus.trimmingCharacters(in: .whitespaces)
        guard let newAmount = counterpartAmount(forEditedRole: editedRole, value: edited) else { return nil }
        let current = counterpartValueAtFocus.trimmingCharacters(in: .whitespaces)
        if current.isEmpty { return newAmount }
        guard edited != before,
              let linkedBefore = counterpartAmount(forEditedRole: editedRole, value: before),
              amount(from: current) == amount(from: linkedBefore),
              amount(from: current) != amount(from: newAmount) else { return nil }
        return newAmount
    }

    /// Parses an amount as the portal or the writer formats it: "12500", "12.500", "12 500",
    /// "€ 12.500,00", "12500,50", "12500.50".
    static func amount(from raw: String) -> Decimal? {
        var text = raw.filter { $0.isNumber || $0 == "," || $0 == "." }
        guard text.contains(where: \.isNumber) else { return nil }
        if text.contains(",") {
            // Decimal comma: dots are thousands separators.
            text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if text.range(of: #"^\d{1,3}(\.\d{3})+$"#, options: .regularExpression) != nil {
            // Dots only, in thousands groups ("12.500"): Dutch thousands separators.
            text = text.replacingOccurrences(of: ".", with: "")
        }
        guard text.filter({ $0 == "." }).count <= 1 else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Rounded half away from zero to whole euros, as plain digits.
    static func wholeEuros(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}
